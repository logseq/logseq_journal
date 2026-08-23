import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bonsai_flutter_logseq_journal_host/application_host_adapter.dart';
import 'package:bonsai_flutter_logseq_journal_host/main.dart';
import 'package:bonsai_flutter/bonsai_flutter.dart';
import 'package:amplify_authenticator/amplify_authenticator.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const sampleCalendar = JournalCalendarSnapshot(
  instantUnixMilliseconds: 1786055400000,
  localDay: 20260807,
  locale: 'en_US',
  timeZoneId: 'Europe/Paris',
  utcOffsetSeconds: 7200,
  generation: 7,
);

final class _Auth implements JournalAuthCapability {
  final String? userId = 'cognito-user-1';
  final String token = 'fresh-id-token';
  int tokenRequests = 0;
  int signOutRequests = 0;

  @override
  Future<String?> currentUserId() async => userId;

  @override
  Future<String> freshIdToken() async {
    tokenRequests += 1;
    return token;
  }

  @override
  Future<void> signOut() async {
    signOutRequests += 1;
  }
}

final class _PendingHostAdapter implements BonsaiFlutterHostAdapter {
  final Completer<Uint8List> payload = Completer<Uint8List>();
  int payloadRequests = 0;

  @override
  Future<Uint8List> createApplicationPayload() {
    payloadRequests += 1;
    return payload.future;
  }

  @override
  BonsaiFlutterApplicationPlatform? createApplicationPlatform() => null;

  @override
  Widget buildHost({required BuildContext context, required Widget child}) =>
      child;
}

Uint8List request(JournalPlatformTag tag, [Object? payload]) =>
    JournalPlatformEnvelopeCodec.encode(
      JournalPlatformEnvelope(
        tag: tag,
        payload: Uint8List.fromList(
          payload == null ? const [] : utf8.encode(jsonEncode(payload)),
        ),
      ),
    );

Map<String, dynamic> responseJson(Uint8List response) =>
    jsonDecode(
          utf8.decode(JournalPlatformEnvelopeCodec.decode(response).payload),
        )
        as Map<String, dynamic>;

Uint8List rawRequest(int tag) {
  final value = Uint8List(32);
  value.setRange(0, 4, ascii.encode('LJP2'));
  final data = ByteData.sublistView(value);
  data.setUint16(4, 2, Endian.little);
  data.setUint16(6, tag, Endian.little);
  return value;
}

int rawEventTag(Uint8List event) =>
    ByteData.sublistView(event).getUint16(6, Endian.little);

int rawLifecycleKind(Uint8List event) =>
    ByteData.sublistView(event).getUint16(38, Endian.little);

int rawLifecycleGeneration(Uint8List event) =>
    ByteData.sublistView(event).getInt64(40, Endian.little);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'startup contains only the managed origin and mechanical host facts',
    () async {
      final root = await Directory.systemTemp.createTemp('managed-host-');
      addTearDown(() => root.delete(recursive: true));
      final adapter = ApplicationHostAdapter(
        applicationSupportDirectory: () async => root,
        baseUrl: Uri.parse('https://api.example.test'),
        initialCalendarSnapshot: () async => sampleCalendar,
        liveCalendarSnapshot: () async => sampleCalendar,
        formatJournalDays: ({required snapshot, required days}) async => {},
        auth: _Auth(),
      );
      final payload = await adapter.createApplicationPayload();
      final decoded =
          jsonDecode(utf8.decode(payload.sublist(8))) as Map<String, dynamic>;

      expect(
        decoded['applicationSupportDirectory'],
        await root.resolveSymbolicLinks(),
      );
      expect(decoded['target'], {
        'kind': 'managedSync',
        'baseUrl': 'https://api.example.test',
      });
      expect(utf8.decode(payload), isNot(contains('idToken')));
      expect(utf8.decode(payload), isNot(contains('graphId')));
    },
  );

  testWidgets(
    'Authenticator is not constructed while configuration is pending',
    (tester) async {
      final configuration = Completer<void>();
      final adapter = ApplicationHostAdapter(
        applicationSupportDirectory: () async => Directory.systemTemp,
        baseUrl: Uri.parse('https://api.example.test'),
        initialCalendarSnapshot: () async => sampleCalendar,
        liveCalendarSnapshot: () async => sampleCalendar,
        formatJournalDays: ({required snapshot, required days}) async => {},
        auth: _Auth(),
        amplifyReady: configuration.future,
      );

      await tester.pumpWidget(
        Builder(
          builder: (context) => adapter.buildHost(
            context: context,
            child: const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.byType(Authenticator), findsNothing);
    },
  );

  test(
    'application platform signs out through the authenticated host',
    () async {
      final auth = _Auth();
      final platform = JournalApplicationPlatform(
        calendarSnapshot: () async => sampleCalendar,
        formatJournalDays: ({required snapshot, required days}) async => {},
        auth: auth,
      );
      addTearDown(platform.dispose);

      final response = await platform.handleRequest(rawRequest(10));

      expect(responseJson(response), {'signedOut': true});
      expect(auth.signOutRequests, 1);
    },
  );

  test(
    'termination waits for native graph cleanup before runtime shutdown',
    () async {
      var runtimeShutdowns = 0;
      final platform = JournalApplicationPlatform(
        calendarSnapshot: () async => sampleCalendar,
        formatJournalDays: ({required snapshot, required days}) async => {},
        auth: _Auth(),
        prepareToTerminate: () async {
          runtimeShutdowns += 1;
        },
      );
      addTearDown(platform.dispose);
      final event = platform.events.first;

      final termination = platform.prepareForTermination();
      final envelope = JournalPlatformEnvelopeCodec.decode(await event);
      expect(envelope.tag, JournalPlatformTag.prepareToTerminateEvent);
      expect(runtimeShutdowns, 0);

      final response = await platform.handleRequest(rawRequest(13));
      expect(
        JournalPlatformEnvelopeCodec.decode(response).tag,
        JournalPlatformTag.terminationReadyResponse,
      );
      expect(responseJson(response), {'ready': true});
      await termination;
      expect(runtimeShutdowns, 1);
    },
  );

  test('production origin is fixed while tests can inject another origin', () {
    final source = File('lib/application_host_adapter.dart').readAsStringSync();
    expect(source, contains("Uri.parse('https://api.logseq.io')"));
    expect(source, isNot(contains('LOGSEQ_SYNC_BASE_URL')));

    final injected = createBonsaiFlutterHostAdapter(
      baseUrl: Uri.parse('https://api.example.test'),
    );
    expect(injected.baseUrl.toString(), 'https://api.example.test');
  });

  test('production entrypoint owns ordered Amplify startup and retry UI', () {
    final entrypoint = File('lib/application.dart');
    expect(entrypoint.existsSync(), isTrue);
    if (!entrypoint.existsSync()) return;
    final source = entrypoint.readAsStringSync();
    expect(
      source.indexOf('await JournalAmplify.configure()'),
      lessThan(source.indexOf('runApp')),
    );
    expect(source, contains('Unable to configure authentication'));
    expect(source, contains('Retry'));
  });

  test(
    'inactive resume refreshes calendar without a network lifecycle event',
    () async {
      var generation = sampleCalendar.generation;
      final platform = JournalApplicationPlatform(
        calendarSnapshot: () async => JournalCalendarSnapshot(
          instantUnixMilliseconds: sampleCalendar.instantUnixMilliseconds,
          localDay: sampleCalendar.localDay,
          locale: sampleCalendar.locale,
          timeZoneId: sampleCalendar.timeZoneId,
          utcOffsetSeconds: sampleCalendar.utcOffsetSeconds,
          generation: ++generation,
        ),
        formatJournalDays: ({required snapshot, required days}) async => {},
        auth: _Auth(),
      );
      addTearDown(platform.dispose);
      final events = <Uint8List>[];
      final subscription = platform.events.listen(events.add);
      addTearDown(subscription.cancel);

      platform.didChangeAppLifecycleState(AppLifecycleState.inactive);
      platform.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      final envelope = JournalPlatformEnvelopeCodec.decode(events.single);
      expect(envelope.tag, JournalPlatformTag.calendarEvent);
      final data = ByteData.sublistView(envelope.payload);
      expect(
        data.getUint16(8, Endian.little),
        CalendarChangeReason.resumed.wireId,
      );
      expect(data.getInt64(40, Endian.little), sampleCalendar.generation + 1);
      expect(data.getInt64(48, Endian.little), 0);
    },
  );

  test('hidden paused resume emits one coalesced background epoch', () async {
    var generation = sampleCalendar.generation;
    final platform = JournalApplicationPlatform(
      calendarSnapshot: () async => JournalCalendarSnapshot(
        instantUnixMilliseconds: sampleCalendar.instantUnixMilliseconds,
        localDay: sampleCalendar.localDay,
        locale: sampleCalendar.locale,
        timeZoneId: sampleCalendar.timeZoneId,
        utcOffsetSeconds: sampleCalendar.utcOffsetSeconds,
        generation: ++generation,
      ),
      formatJournalDays: ({required snapshot, required days}) async => {},
      auth: _Auth(),
    );
    addTearDown(platform.dispose);
    final events = <Uint8List>[];
    final subscription = platform.events.listen(events.add);
    addTearDown(subscription.cancel);

    platform.didChangeAppLifecycleState(AppLifecycleState.hidden);
    platform.didChangeAppLifecycleState(AppLifecycleState.paused);
    platform.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    expect(events.map(rawEventTag), containsAllInOrder(<int>[15, 15, 3]));
    final lifecycleEvents = events
        .where((event) => rawEventTag(event) == 15)
        .toList();
    expect(lifecycleEvents, hasLength(2));
    expect(lifecycleEvents.map(rawLifecycleKind), <int>[1, 2]);
    expect(lifecycleEvents.map(rawLifecycleGeneration), <int>[1, 1]);
    final calendar = events.singleWhere((event) => rawEventTag(event) == 3);
    expect(
      ByteData.sublistView(
        JournalPlatformEnvelopeCodec.decode(calendar).payload,
      ).getInt64(48, Endian.little),
      1,
    );

    platform.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(events.where((event) => rawEventTag(event) == 15), hasLength(2));
  });

  testWidgets('background resume does not recreate the root runtime', (
    tester,
  ) async {
    final adapter = _PendingHostAdapter();
    await tester.pumpWidget(BonsaiFlutterHost(adapter: adapter));
    expect(adapter.payloadRequests, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(adapter.payloadRequests, 1);
  });

  test(
    'platform exposes only current user and one fresh token per challenge',
    () async {
      final auth = _Auth();
      final platform = JournalApplicationPlatform(
        calendarSnapshot: () async => sampleCalendar,
        formatJournalDays: ({required snapshot, required days}) async => {},
        auth: auth,
      );
      addTearDown(platform.dispose);

      final user = await platform.handleRequest(
        request(JournalPlatformTag.authenticatedUserRequest),
      );
      expect(responseJson(user), {'userId': 'cognito-user-1'});

      final token = await platform.handleRequest(
        request(JournalPlatformTag.idTokenRequest, {
          'challengeId': 'challenge-1',
          'purpose': 'snapshotBootstrap',
        }),
      );
      expect(responseJson(token), {
        'challengeId': 'challenge-1',
        'token': 'fresh-id-token',
      });
      expect(auth.tokenRequests, 1);
    },
  );

  test(
    'production token acquisition delegates expiration refresh to Amplify',
    () {
      final source = File(
        'lib/application_host_adapter.dart',
      ).readAsStringSync();
      expect(
        source,
        isNot(contains('FetchAuthSessionOptions(forceRefresh: true)')),
      );
    },
  );

  test('production Dart contains no db-sync transport implementation', () {
    final source = File('lib/application_host_adapter.dart').readAsStringSync();
    for (final forbidden in <String>[
      'WebSocket',
      'snapshot/download',
      '/graphs',
      '/e2ee/',
      'tx/batch',
      'JournalSyncTransport',
      'Sync_receive',
      'runtimeRestarts',
    ]) {
      expect(source, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}
