import 'dart:io';
import 'dart:typed_data';

import 'package:bonsai_flutter/bonsai_flutter.dart';
// ignore: implementation_imports
import 'package:bonsai_flutter/src/runtime/foreground_frame_loop.dart';
import 'package:bonsai_flutter_logseq_journal_host/application_host_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'runtime_flow_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets(
    'mutation persists across orderly shutdown and cold relaunch',
    (tester) async {
      final fixture = await RuntimeFlowFixture.create(tester);
      const marker = 'Orderly cold relaunch marker';
      try {
        final first = await _RuntimeHarness.start(tester, fixture);
        await first.show(tester);
        await _pumpUntil(
          tester,
          () => find.text('No journal entries yet').evaluate().isNotEmpty,
        );
        await _captureAndSave(tester, marker);
        await _pumpUntil(
          tester,
          () =>
              find.text('New block').evaluate().isEmpty &&
              find.text(marker).evaluate().isNotEmpty,
        );
        await first.dispose(tester);

        final second = await _RuntimeHarness.start(tester, fixture);
        await second.show(tester);
        await _pumpUntil(tester, () => find.text(marker).evaluate().isNotEmpty);
        expect(find.text(marker), findsOneWidget);
        await second.dispose(tester);
      } finally {
        await fixture.dispose(tester);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'mutation persistence failure renders terminal fatal state',
    (tester) async {
      final fixture = await RuntimeFlowFixture.create(
        tester,
        mode: RuntimeFlowFixtureMode.persistenceFailure,
      );
      final harness = await _RuntimeHarness.start(tester, fixture);
      try {
        await harness.show(tester);
        await _pumpUntil(
          tester,
          () => find.text('No journal entries yet').evaluate().isNotEmpty,
        );
        await _captureAndSave(tester, 'Persistence failure marker');
        await _pumpUntil(
          tester,
          () => find
              .textContaining('Unable to open Logseq graph:')
              .evaluate()
              .isNotEmpty,
        );
        expect(
          find.textContaining('Unable to open Logseq graph:'),
          findsOneWidget,
        );
        await _pumpUntil(
          tester,
          () => find.text('New block').evaluate().isEmpty,
        );
        expect(_hasAttachedSemanticsTap(tester, 'Capture'), isFalse);
        expect(find.text('New block'), findsNothing);
      } finally {
        await harness.dispose(tester);
        await fixture.dispose(tester);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'uncertain cancellation reconciles durable basis after relaunch',
    (tester) async {
      final fixture = await RuntimeFlowFixture.create(tester);
      const marker = 'Durable uncertain outcome marker';
      try {
        final first = await _RuntimeHarness.start(tester, fixture);
        await first.show(tester);
        await _pumpUntil(
          tester,
          () => find.text('No journal entries yet').evaluate().isNotEmpty,
        );
        await _openCaptureAndEnter(tester, marker);
        await _tapSemantics(tester, 'Save journal block');
        await _pumpRuntime(tester);
        await _waitForCompletedSnapshotMutations(
          tester,
          fixture.graphDirectory,
          count: 2,
        );
        expect(
          find.text('New block'),
          findsOneWidget,
          reason:
              'the UI must not have observed the mutation response before cancellation',
        );
        await first.dispose(tester);

        final second = await _RuntimeHarness.start(tester, fixture);
        await second.show(tester);
        await _pumpUntil(tester, () => find.text(marker).evaluate().isNotEmpty);
        expect(find.text(marker), findsOneWidget);
        await second.dispose(tester);
      } finally {
        await fixture.dispose(tester);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
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
  final _ControllableFrameEligibilitySource frameEligibility;

  static Future<_RuntimeHarness> start(
    WidgetTester tester,
    RuntimeFlowFixture fixture,
  ) async {
    var generation = 1;
    Future<JournalCalendarSnapshot> calendar() async => JournalCalendarSnapshot(
      instantUnixMilliseconds: 1786055400000,
      localDay: 20260807,
      locale: 'en_US',
      timeZoneId: 'Europe/Paris',
      utcOffsetSeconds: 7200,
      generation: generation++,
    );
    final adapter = ApplicationHostAdapter(
      applicationSupportDirectory: () async => fixture.supportRoot,
      graphTarget: () async => LogseqDbTarget.snapshot(fixture.snapshotToken),
      initialCalendarSnapshot: calendar,
      liveCalendarSnapshot: calendar,
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
      ).timeout(const Duration(seconds: 15)),
    );
    expect(runtime, isNotNull);
    return _RuntimeHarness(
      runtime: runtime!,
      config: config,
      adapter: adapter,
      frameEligibility: _ControllableFrameEligibilitySource(),
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
      () => runtime.dispose().timeout(const Duration(seconds: 15)),
    );
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

final class _ControllableFrameEligibilitySource
    implements FrameEligibilitySource {
  bool _eligible = true;
  void Function(bool)? _onChanged;

  @override
  bool get isEligible => _eligible;

  @override
  void start(void Function(bool isEligible) onChanged) {
    _onChanged = onChanged;
  }

  void setEligible(bool eligible) {
    if (_eligible == eligible) return;
    _eligible = eligible;
    _onChanged?.call(eligible);
  }

  @override
  void dispose() {
    _onChanged = null;
  }
}

Future<void> _openCaptureAndEnter(WidgetTester tester, String source) async {
  await _tapSemantics(tester, 'Capture');
  await _pumpUntil(tester, () => find.text('New block').evaluate().isNotEmpty);
  await tester.enterText(find.byType(TextField), source);
  await _pumpRuntime(tester);
  await _pumpUntil(
    tester,
    () => _hasAttachedSemanticsTap(tester, 'Save journal block'),
  );
}

Future<void> _captureAndSave(WidgetTester tester, String source) async {
  await _openCaptureAndEnter(tester, source);
  await _tapSemantics(tester, 'Save journal block');
}

Future<void> _waitForCompletedSnapshotMutations(
  WidgetTester tester,
  Directory graphDirectory, {
  required int count,
}) async {
  final writeSession = File('${graphDirectory.path}/write-session.json');
  final digestPattern = RegExp(r'"committedDigest"\s*:\s*"([0-9a-f]+)"');
  final digests = <String>{};
  final stopwatch = Stopwatch()..start();
  while (digests.length < count &&
      stopwatch.elapsed < const Duration(seconds: 15)) {
    await _pumpRuntime(tester);
    if (writeSession.existsSync()) {
      final match = digestPattern.firstMatch(writeSession.readAsStringSync());
      if (match != null) {
        digests.add(match.group(1)!);
      }
    }
  }
  expect(
    digests.length,
    count,
    reason:
        'timed out waiting for $count authenticated snapshot mutations; '
        'observed ${digests.length}',
  );
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
  Duration timeout = const Duration(seconds: 15),
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
    final data = semantics.getSemanticsData();
    if (!data.hasAction(SemanticsAction.tap)) continue;
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
