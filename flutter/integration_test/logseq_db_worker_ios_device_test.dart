import 'dart:convert';
import 'dart:io';

import 'package:bonsai_flutter/bonsai_flutter.dart';
// ignore: implementation_imports
import 'package:bonsai_flutter/src/runtime/foreground_frame_loop.dart';
import 'package:bonsai_flutter_logseq_journal_host/application_host_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _phase = String.fromEnvironment('LOGSEQ_IOS_DEVICE_PHASE');
const _inboxEntry = String.fromEnvironment('LOGSEQ_IOS_DEVICE_INBOX_ENTRY');
const _marker = String.fromEnvironment('LOGSEQ_IOS_DEVICE_MARKER');
const _platform = MethodChannel('logseq_journal/platform');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets(
    'signed physical-device persistence phase',
    (tester) async {
      expect(
        Platform.isIOS,
        isTrue,
        reason: 'the signed lane requires iPhoneOS',
      );
      expect(const {'first', 'second'}, contains(_phase));
      expect(_inboxEntry, isNotEmpty);
      expect(_marker, isNotEmpty);

      final environment = await tester.runAsync(_startupEnvironment);
      expect(environment, isNotNull);
      final support = Directory(
        environment!['applicationSupportPath']! as String,
      );
      final stateFile = File(
        '${support.path}/logseq-db-worker/ios-device-test-state.json',
      );

      if (_phase == 'first') {
        await _runFirstPhase(tester, support, stateFile);
      } else {
        await _runSecondPhase(tester, support, stateFile);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _runFirstPhase(
  WidgetTester tester,
  Directory support,
  File stateFile,
) async {
  final inbox = Directory(
    '${support.path}/logseq-db-worker/inbox/$_inboxEntry',
  );
  expect(
    inbox.existsSync(),
    isTrue,
    reason: 'the confined inbox bundle is absent',
  );
  expect(File('${inbox.path}/db.sqlite').existsSync(), isTrue);
  expect(
    stateFile.existsSync(),
    isFalse,
    reason: 'the device lane was not clean',
  );

  final harness = await _RuntimeHarness.start(
    tester,
    support,
    LogseqDbTarget.importSnapshot(_inboxEntry),
  );
  await harness.show(tester);
  await _pumpUntil(tester, () => _hasAttachedSemanticsTap(tester, 'Capture'));

  final token = _onlyImportedSnapshotToken(support);
  expect(
    inbox.existsSync(),
    isFalse,
    reason: 'the inbox snapshot was not consumed',
  );
  debugPrint('LOGSEQ_IOS_DEVICE_IMPORT_RESPONSE token=$token');

  expect(find.text(_marker), findsNothing);
  await _captureAndSave(tester, _marker);
  await _pumpUntil(
    tester,
    () =>
        find.text('New block').evaluate().isEmpty &&
        find.text(_marker).evaluate().isNotEmpty,
  );
  debugPrint('LOGSEQ_IOS_DEVICE_MUTATION_RESPONSE marker=$_marker');

  stateFile.writeAsStringSync(
    '${jsonEncode(<String, Object>{'formatVersion': 1, 'token': token, 'marker': _marker})}\n',
    flush: true,
  );
  await harness.dispose(tester);
  debugPrint('LOGSEQ_IOS_DEVICE_ORDERLY_SHUTDOWN');
}

Future<void> _runSecondPhase(
  WidgetTester tester,
  Directory support,
  File stateFile,
) async {
  expect(
    stateFile.existsSync(),
    isTrue,
    reason: 'first-launch state is absent',
  );
  final state =
      jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>;
  expect(state['formatVersion'], 1);
  expect(
    state['marker'],
    _marker,
    reason: 'cold launch used a different marker',
  );
  final token = state['token']! as String;

  final harness = await _RuntimeHarness.start(
    tester,
    support,
    LogseqDbTarget.snapshot(token),
  );
  await harness.show(tester);
  await _pumpUntil(tester, () => find.text(_marker).evaluate().isNotEmpty);
  expect(_hasAttachedSemanticsTap(tester, 'Capture'), isTrue);
  debugPrint('LOGSEQ_IOS_DEVICE_COLD_RELAUNCH_RESPONSE token=$token');
  debugPrint('LOGSEQ_IOS_DEVICE_PERSISTED_MARKER marker=$_marker');
  await harness.dispose(tester);
}

String _onlyImportedSnapshotToken(Directory support) {
  final snapshots = Directory('${support.path}/logseq-db-worker/snapshots');
  final candidates = snapshots
      .listSync()
      .whereType<Directory>()
      .where((directory) {
        final token = directory.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last;
        return RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(token);
      })
      .toList(growable: false);
  expect(
    candidates,
    hasLength(1),
    reason: 'import did not publish exactly one snapshot',
  );
  return candidates.single.uri.pathSegments
      .where((part) => part.isNotEmpty)
      .last;
}

Future<Map<Object?, Object?>> _startupEnvironment() async {
  final value = await _platform.invokeMapMethod<Object?, Object?>(
    'getStartupEnvironment',
  );
  if (value == null) {
    throw const FormatException('startup environment is absent');
  }
  return value;
}

Future<JournalCalendarSnapshot> _calendar() async {
  final value = await _startupEnvironment();
  int integer(String name) => value[name]! as int;
  String string(String name) => value[name]! as String;
  return JournalCalendarSnapshot(
    instantUnixMilliseconds: integer('instantUnixMilliseconds'),
    localDay: integer('localDay'),
    locale: string('locale'),
    timeZoneId: string('timeZoneId'),
    utcOffsetSeconds: integer('utcOffsetSeconds'),
    generation: integer('generation'),
  );
}

final class _RuntimeHarness {
  _RuntimeHarness({
    required this.runtime,
    required this.config,
    required this.adapter,
    required this.frameEligibility,
  });

  final RuntimeClient runtime;
  final Uint8List config;
  final ApplicationHostAdapter adapter;
  final _FrameEligibility frameEligibility;

  static Future<_RuntimeHarness> start(
    WidgetTester tester,
    Directory support,
    LogseqDbTarget target,
  ) async {
    final adapter = ApplicationHostAdapter(
      applicationSupportDirectory: () async => support,
      graphTarget: () async => target,
      initialCalendarSnapshot: _calendar,
      liveCalendarSnapshot: _calendar,
    );
    final payload = await tester.runAsync(adapter.createApplicationPayload);
    expect(payload, isNotNull);
    final config = RuntimeBootstrapConfig(
      entrypoint: 'logseq_journal',
      launchPolicy: RuntimeLaunchPolicy.replaceExisting,
      applicationPayload: payload!,
    ).encode();
    final runtime = await tester.runAsync(
      () => RuntimeClient.start(
        config: config,
      ).timeout(const Duration(seconds: 30)),
    );
    expect(runtime, isNotNull);
    return _RuntimeHarness(
      runtime: runtime!,
      config: config,
      adapter: adapter,
      frameEligibility: _FrameEligibility(),
    );
  }

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: BonsaiFlutterRoot(
          config: config,
          runtimeStarter: (_) async => runtime,
          applicationPlatform: adapter.createApplicationPlatform(),
          frameEligibilitySource: frameEligibility,
        ),
      ),
    );
  }

  Future<void> dispose(WidgetTester tester) async {
    var snapshot = await tester.runAsync(runtime.debugSnapshot);
    if (snapshot?.state == RuntimeWorkerState.awaitingPresentation) {
      runtime.presentationSucceeded(
        generation: snapshot!.liveGeneration,
        presentationId: snapshot.unresolvedPresentationId!,
        revision: snapshot.unresolvedRevision!,
        eventBatch: Uint8List(0),
      );
      snapshot = await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return runtime.debugSnapshot();
      });
    }
    expect(snapshot?.state, RuntimeWorkerState.ready);
    frameEligibility.setEligible(false);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => runtime.dispose().timeout(const Duration(seconds: 30)),
    );
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

final class _FrameEligibility implements FrameEligibilitySource {
  bool _eligible = true;
  void Function(bool)? _onChanged;

  @override
  bool get isEligible => _eligible;

  @override
  void start(void Function(bool isEligible) onChanged) =>
      _onChanged = onChanged;

  void setEligible(bool eligible) {
    if (_eligible == eligible) return;
    _eligible = eligible;
    _onChanged?.call(eligible);
  }

  @override
  void dispose() => _onChanged = null;
}

Future<void> _captureAndSave(WidgetTester tester, String source) async {
  await _tapSemantics(tester, 'Capture');
  await _pumpUntil(tester, () => find.text('New block').evaluate().isNotEmpty);
  await tester.enterText(find.byType(TextField), source);
  await _pumpRuntime(tester);
  await _pumpUntil(
    tester,
    () => _hasAttachedSemanticsTap(tester, 'Save journal block'),
  );
  await _tapSemantics(tester, 'Save journal block');
}

Future<void> _pumpRuntime(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  await tester.pump();
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!predicate() && stopwatch.elapsed < timeout) {
    await _pumpRuntime(tester);
  }
  expect(
    predicate(),
    isTrue,
    reason: tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .whereType<String>()
        .join(' | '),
  );
}

Future<void> _tapSemantics(WidgetTester tester, String label) async {
  final candidates = find.bySemanticsLabel(label);
  for (var index = candidates.evaluate().length - 1; index >= 0; index -= 1) {
    final semantics = tester.getSemantics(candidates.at(index));
    final owner = semantics.owner;
    if (owner == null) continue;
    if (!semantics.getSemanticsData().hasAction(SemanticsAction.tap)) continue;
    owner.performAction(semantics.id, SemanticsAction.tap);
    await tester.pump(const Duration(milliseconds: 80));
    return;
  }
  fail('No attached tappable semantics node was found for $label');
}

bool _hasAttachedSemanticsTap(WidgetTester tester, String label) {
  final candidates = find.bySemanticsLabel(label);
  for (var index = candidates.evaluate().length - 1; index >= 0; index -= 1) {
    final semantics = tester.getSemantics(candidates.at(index));
    if (semantics.owner != null &&
        semantics.getSemanticsData().hasAction(SemanticsAction.tap)) {
      return true;
    }
  }
  return false;
}
