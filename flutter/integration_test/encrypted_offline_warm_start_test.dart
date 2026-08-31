import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsai_flutter/bonsai_flutter.dart';
// ignore: implementation_imports
import 'package:bonsai_flutter/src/runtime/foreground_frame_loop.dart';
import 'package:bonsai_flutter_logseq_journal_host/application_host_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _cryptoChannel = MethodChannel('logseq_journal/platform');
const _fixtureEnvironment = 'LOGSEQ_JOURNAL_ENCRYPTED_WARM_FIXTURES_JSON';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets(
    'compiled encrypted warm start presents locally before network recovery',
    (tester) async {
      expect(
        Platform.isMacOS,
        isTrue,
        reason: 'this lane requires a macOS host',
      );
      final fixtures = _FixtureSet.fromEnvironment();

      await _deleteAccountSecrets(fixtures.valid);
      await _deleteAccountSecrets(fixtures.missingWrappedKey);
      final obsoletePending = File(
        '${fixtures.valid.graphDirectory.path}/pending-intents-v1.json',
      );
      await obsoletePending.writeAsString(
        '{"version":1,"entries":[{"secret":"obsolete"}]}',
        flush: true,
      );
      addTearDown(() async {
        await _deleteAccountSecrets(fixtures.valid);
        await _deleteAccountSecrets(fixtures.missingWrappedKey);
      });

      final installed = await _crypto(<String, Object>{
        'operation': 'installTestWrappedGraphKeyFixture',
        ...fixtures.valid.identity,
      });
      expect(installed['ok'], isTrue);

      final validAuth = _BlockingAuth(fixtures.valid.userId);
      final valid = await _RuntimeHarness.start(
        tester,
        fixture: fixtures.valid,
        auth: validAuth,
      );
      try {
        await valid.show(tester);
        await valid.pumpUntil(
          tester,
          () =>
              find
                  .text(fixtures.valid.expectedTimelineText)
                  .evaluate()
                  .isNotEmpty &&
              JournalStartupTimeline.snapshot().containsKey(
                JournalStartupMilestone.timelineFramePresented,
              ),
          reason: 'the encrypted local mirror did not present Timeline',
        );
        expect(find.text(fixtures.valid.expectedTimelineText), findsOneWidget);
        expect(
          JournalStartupTimeline.snapshot(),
          contains(JournalStartupMilestone.timelineFramePresented),
        );
        expect(
          validAuth.requestedBeforeTimeline,
          isFalse,
          reason: 'network authentication started before Timeline presentation',
        );
        expect(
          await obsoletePending.exists(),
          isFalse,
          reason: 'compiled startup retained obsolete pending data',
        );
      } finally {
        await valid.dispose(tester);
        await _deleteAccountSecrets(fixtures.valid);
      }

      final missingInstalled = await _crypto(<String, Object>{
        'operation': 'installTestWrappedGraphKeyFixture',
        ...fixtures.missingWrappedKey.identity,
      });
      expect(missingInstalled['ok'], isTrue);
      final deletedWrappedKey = await _crypto(<String, Object>{
        'operation': 'deleteWrappedGraphKey',
        ...fixtures.missingWrappedKey.identity,
      });
      expect(deletedWrappedKey['ok'], isTrue);

      final missingAuth = _BlockingAuth(fixtures.missingWrappedKey.userId);
      final missing = await _RuntimeHarness.start(
        tester,
        fixture: fixtures.missingWrappedKey,
        auth: missingAuth,
      );
      try {
        await missing.show(tester);
        await missing.pumpUntil(
          tester,
          () => find.text('Online recovery is required').evaluate().isNotEmpty,
          reason: 'a missing wrapped key did not reach explicit recovery',
        );
        expect(find.text('Continue online'), findsOneWidget);
        expect(
          missingAuth.tokenRequests,
          0,
          reason: 'cache failure entered the network lane without user intent',
        );
      } finally {
        await missing.dispose(tester);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

final class _FixtureSet {
  const _FixtureSet({required this.valid, required this.missingWrappedKey});

  final _Fixture valid;
  final _Fixture missingWrappedKey;

  factory _FixtureSet.fromEnvironment() {
    final source = Platform.environment[_fixtureEnvironment];
    if (source == null) {
      throw StateError('$_fixtureEnvironment is required');
    }
    final document = jsonDecode(source) as Map<String, dynamic>;
    return _FixtureSet(
      valid: _Fixture.fromJson(document['valid']),
      missingWrappedKey: _Fixture.fromJson(document['missingWrappedKey']),
    );
  }
}

final class _Fixture {
  const _Fixture({
    required this.supportRoot,
    required this.baseUrl,
    required this.userId,
    required this.graphId,
    required this.graphDirectory,
    required this.expectedTimelineText,
  });

  final Directory supportRoot;
  final Uri baseUrl;
  final String userId;
  final String graphId;
  final Directory graphDirectory;
  final String expectedTimelineText;

  Map<String, Object> get identity => <String, Object>{
    'origin': baseUrl.toString(),
    'userId': userId,
    'graphId': graphId,
  };

  factory _Fixture.fromJson(Object? value) {
    if (value is! Map<String, dynamic> || value['formatVersion'] != 1) {
      throw const FormatException('encrypted warm-start fixture is invalid');
    }
    return _Fixture(
      supportRoot: Directory(value['supportRoot']! as String),
      baseUrl: Uri.parse(value['baseUrl']! as String),
      userId: value['userId']! as String,
      graphId: value['graphId']! as String,
      graphDirectory: Directory(value['graphDir']! as String),
      expectedTimelineText: value['expectedTimelineText']! as String,
    );
  }
}

final class _BlockingAuth implements JournalAuthCapability {
  _BlockingAuth(this.userId);

  final String userId;
  final Completer<String> _neverToken = Completer<String>();
  int tokenRequests = 0;
  bool requestedBeforeTimeline = false;

  @override
  Future<String?> currentUserId() async => userId;

  @override
  Future<String> freshIdToken() {
    tokenRequests += 1;
    if (!JournalStartupTimeline.snapshot().containsKey(
      JournalStartupMilestone.timelineFramePresented,
    )) {
      requestedBeforeTimeline = true;
    }
    return _neverToken.future;
  }

  @override
  Future<void> signOut() async =>
      throw StateError('the offline integration lane must not sign out');
}

final class _RuntimeHarness {
  _RuntimeHarness({
    required this.runtime,
    required this.config,
    required this.adapter,
    required this.platform,
    required this.frameEligibility,
  });

  final RuntimeClient runtime;
  final Uint8List config;
  final ApplicationHostAdapter adapter;
  final JournalApplicationPlatform platform;
  final _FrameEligibility frameEligibility;

  static Future<_RuntimeHarness> start(
    WidgetTester tester, {
    required _Fixture fixture,
    required JournalAuthCapability auth,
  }) async {
    var generation = 1;
    Future<JournalCalendarSnapshot> calendar() async => JournalCalendarSnapshot(
      instantUnixMilliseconds: 1786055400000,
      localDay: 20260807,
      locale: 'en_US',
      timeZoneId: 'Europe/Paris',
      utcOffsetSeconds: 7200,
      generation: generation++,
    );
    final initialCalendar = await calendar();
    final adapter = ApplicationHostAdapter(
      applicationSupportDirectory: () async => fixture.supportRoot,
      baseUrl: fixture.baseUrl,
      initialCalendarSnapshot: () async => initialCalendar,
      liveCalendarSnapshot: calendar,
      formatJournalDays: ({required snapshot, required days}) async => {
        for (final day in days) day: day == 20260807 ? 'Fri, Aug 7' : '$day',
      },
      auth: auth,
      readPreference: (_) async => 'balanced',
      writePreference: (_, _) async {},
      readLocalAccountBinding: () async => (
        userId: fixture.userId,
        managedSyncOrigin: fixture.baseUrl.toString(),
      ),
      persistLocalAccountBinding: (_) async {},
      clearLocalAccountBinding: () async {},
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
      ).timeout(const Duration(seconds: 20)),
    );
    expect(runtime, isNotNull);
    final platform =
        adapter.createApplicationPlatform() as JournalApplicationPlatform;
    return _RuntimeHarness(
      runtime: runtime!,
      config: config,
      adapter: adapter,
      platform: platform,
      frameEligibility: _FrameEligibility(),
    );
  }

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 632);
    tester.view.devicePixelRatio = 1;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final root = BonsaiFlutterRoot(
      config: config,
      runtimeStarter: (_) async => runtime,
      applicationPlatform: platform,
      frameEligibilitySource: frameEligibility,
    );
    await tester.pumpWidget(
      Builder(
        builder: (context) => adapter.buildHost(context: context, child: root),
      ),
    );
  }

  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() predicate, {
    required String reason,
  }) async {
    final stopwatch = Stopwatch()..start();
    while (!predicate() && stopwatch.elapsed < const Duration(seconds: 20)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 10));
      final exception = tester.takeException();
      if (exception != null) fail('$reason; renderer exception: $exception');
    }
    if (!predicate()) {
      final text = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data)
          .whereType<String>()
          .toList(growable: false);
      final snapshot = await tester.runAsync(runtime.debugSnapshot);
      fail(
        '$reason; mounted text: $text; '
        'runtime: state=${snapshot?.state} '
        'generation=${snapshot?.liveGeneration} '
        'eligible=${snapshot?.eligible} '
        'pumpCount=${snapshot?.pumpCount} '
        'coalesced=${snapshot?.hasCoalescedGrant} '
        'presentation=${snapshot?.unresolvedPresentationId} '
        'revision=${snapshot?.unresolvedRevision}',
      );
    }
  }

  Future<void> dispose(WidgetTester tester) async {
    var snapshot = await tester.runAsync(runtime.debugSnapshot);
    for (
      var attempt = 0;
      attempt < 8 && snapshot?.state == RuntimeWorkerState.awaitingPresentation;
      attempt += 1
    ) {
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
    frameEligibility.setEligible(false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => runtime.dispose().timeout(const Duration(seconds: 20)),
    );
    platform.dispose();
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

Future<Map<Object?, Object?>> _crypto(Map<String, Object> request) async {
  final result = await _cryptoChannel.invokeMapMethod<Object?, Object?>(
    'e2eeCrypto',
    request,
  );
  if (result == null) throw StateError('native crypto response is missing');
  return result;
}

Future<void> _deleteAccountSecrets(_Fixture fixture) async {
  await _crypto(<String, Object>{
    'operation': 'deleteAccountSecrets',
    'origin': fixture.baseUrl.toString(),
    'userId': fixture.userId,
  });
}
