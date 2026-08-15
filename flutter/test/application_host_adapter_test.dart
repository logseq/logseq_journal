import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bonsai_flutter_logseq_journal_host/application_host_adapter.dart';
import 'package:flutter/services.dart';
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

Uint8List startupPacket({
  String root = '/tmp/support',
  Map<String, Object> target = const {
    'kind': 'snapshot',
    'token': '10000000-0000-4000-8000-000000000001',
  },
}) {
  final json = utf8.encode(
    jsonEncode(<String, Object>{
      'applicationSupportDirectory': root,
      'target': target,
      'compatibilityProfile': 'logseq-65.33-or-newer',
      'responseBudgetBytes': 262144,
      'defaultPageSize': 50,
    }),
  );
  final value = Uint8List(8 + json.length);
  final data = ByteData.sublistView(value);
  value.setRange(0, 4, ascii.encode('LDB1'));
  data.setUint32(4, json.length, Endian.little);
  value.setRange(8, value.length, json);
  return value;
}

ByteData packetData(Uint8List value) => ByteData.sublistView(value);

void expectCalendarPacket(
  Uint8List value, {
  required int reason,
  required int localMinuteOfDay,
  required int calendarGeneration,
  required int lifecycleGeneration,
}) {
  final data = packetData(value);
  expect(value.sublist(0, 4), ascii.encode('LJP1'));
  expect(data.getUint16(4, Endian.little), 1);
  expect(data.getUint16(8, Endian.little), reason);
  expect(data.getUint16(28, Endian.little), localMinuteOfDay);
  expect(data.getInt64(40, Endian.little), calendarGeneration);
  expect(data.getInt64(48, Endian.little), lifecycleGeneration);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup codec carries only bounded mechanical host facts', () {
    final expected = startupPacket();
    final decoded = LogseqDbWorkerStartupEnvelope.decode(expected);

    expect(decoded.applicationSupportDirectory, '/tmp/support');
    expect(decoded.target.kind, LogseqDbTargetKind.snapshot);
    expect(
      decoded.target.snapshotToken,
      '10000000-0000-4000-8000-000000000001',
    );
    expect(
      packetData(expected).getUint32(4, Endian.little),
      expected.length - 8,
    );

    for (final bytes in <Uint8List>[
      Uint8List(0),
      Uint8List((1024 * 1024) + 1),
      Uint8List.fromList([...expected, 0]),
      startupPacket(root: 'tmp/support'),
      startupPacket(root: '/tmp/../tmp/support'),
      startupPacket(root: '/'),
      startupPacket(target: const {'kind': 'snapshot', 'token': 'invalid'}),
      startupPacket(
        target: const {'kind': 'importSnapshot', 'inboxEntry': '..'},
      ),
      startupPacket(root: '/${List.filled(4097, 'x').join()}'),
    ]) {
      expect(
        () => LogseqDbWorkerStartupEnvelope.decode(bytes),
        throwsFormatException,
      );
    }
  });

  test('Dart adapter source contains no product or persistence policy', () {
    final source = File('lib/application_host_adapter.dart').readAsStringSync();
    for (final forbidden in <String>[
      'databaseRelativePath',
      'expectedSchemaVersion',
      '_schemaVersion',
      'JournalAccessMode',
      'JournalDiagnosticMode',
      'migration',
      'JournalMutation',
      'attachment',
      'token_parser',
      'JournalRoute',
    ]) {
      expect(source, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('iOS always requests the light native appearance', () {
    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(
      infoPlist,
      contains('<key>UIUserInterfaceStyle</key>\n\t<string>Light</string>'),
    );
  });

  test(
    'adapter canonicalizes the root without creating a product directory',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'journal-adapter-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final alias = Link('${temporary.path}-alias');
      await alias.create(temporary.path);
      addTearDown(() async {
        if (await alias.exists()) await alias.delete();
      });

      final adapter = ApplicationHostAdapter(
        applicationSupportDirectory: () async => Directory(alias.path),
        graphTarget: () async =>
            LogseqDbTarget.snapshot('10000000-0000-4000-8000-000000000001'),
        initialCalendarSnapshot: () async => sampleCalendar,
      );
      final payload = await adapter.createApplicationPayload();
      final canonicalRoot = await temporary.resolveSymbolicLinks();

      expect(payload, startupPacket(root: canonicalRoot));
      expect(
        LogseqDbWorkerStartupEnvelope.decode(
          payload,
        ).applicationSupportDirectory,
        canonicalRoot,
      );
      expect(
        await Directory('${temporary.path}/logseq_journal').exists(),
        isFalse,
      );
    },
  );

  testWidgets('adapter preserves the generated host child', (tester) async {
    final adapter = ApplicationHostAdapter(
      applicationSupportDirectory: () async => Directory('/tmp/unused'),
      graphTarget: () async =>
          LogseqDbTarget.snapshot('10000000-0000-4000-8000-000000000001'),
      initialCalendarSnapshot: () async => sampleCalendar,
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) =>
              adapter.buildHost(context: context, child: const Text('child')),
        ),
      ),
    );
    expect(find.text('child'), findsOneWidget);
  });

  test(
    'application bridge publishes time-zone and lifecycle generations',
    () async {
      var generation = 7;
      var snapshot = sampleCalendar;
      final platform = JournalApplicationPlatform(
        calendarSnapshot: () async =>
            snapshot.copyWith(generation: generation++),
        formatJournalDays: ({required snapshot, required days}) async => {
          for (final day in days) day: '$day',
        },
      );
      addTearDown(platform.dispose);

      final response = await platform.handleRequest(
        JournalPlatformCodec.getCalendarRequest,
      );
      expectCalendarPacket(
        response,
        reason: CalendarChangeReason.requested.wireId,
        localMinuteOfDay: 30,
        calendarGeneration: 7,
        lifecycleGeneration: 0,
      );

      final events = <Uint8List>[];
      final subscription = platform.events.listen(events.add);
      addTearDown(subscription.cancel);
      platform.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);

      platform.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expectCalendarPacket(
        events.single,
        reason: CalendarChangeReason.resumed.wireId,
        localMinuteOfDay: 30,
        calendarGeneration: 8,
        lifecycleGeneration: 1,
      );

      snapshot = const JournalCalendarSnapshot(
        instantUnixMilliseconds: 1786055400000,
        localDay: 20260807,
        locale: 'zh_CN',
        timeZoneId: 'Asia/Shanghai',
        utcOffsetSeconds: 28800,
        generation: 0,
      );
      await platform.refresh(CalendarChangeReason.timeZoneChanged);
      expect(events, hasLength(2));
      expectCalendarPacket(
        events.last,
        reason: CalendarChangeReason.timeZoneChanged.wireId,
        localMinuteOfDay: 390,
        calendarGeneration: 9,
        lifecycleGeneration: 1,
      );
    },
  );

  test('application bridge rejects stale calendar generations', () async {
    final platform = JournalApplicationPlatform(
      calendarSnapshot: () async => sampleCalendar,
      formatJournalDays: ({required snapshot, required days}) async => {
        for (final day in days) day: '$day',
      },
    );
    addTearDown(platform.dispose);

    await platform.handleRequest(JournalPlatformCodec.getCalendarRequest);
    await expectLater(
      platform.handleRequest(JournalPlatformCodec.getCalendarRequest),
      throwsStateError,
    );
  });

  test('calendar codec preserves both sides of a DST fold', () {
    const early = JournalCalendarSnapshot(
      instantUnixMilliseconds: 1762061400000,
      localDay: 20251102,
      locale: 'en_US',
      timeZoneId: 'America/New_York',
      utcOffsetSeconds: -14400,
      generation: 10,
    );
    const late = JournalCalendarSnapshot(
      instantUnixMilliseconds: 1762065000000,
      localDay: 20251102,
      locale: 'en_US',
      timeZoneId: 'America/New_York',
      utcOffsetSeconds: -18000,
      generation: 11,
    );
    final earlyPacket = JournalPlatformCodec.encodeCalendar(
      early,
      reason: CalendarChangeReason.timeZoneChanged,
      event: true,
    );
    final latePacket = JournalPlatformCodec.encodeCalendar(
      late,
      reason: CalendarChangeReason.timeZoneChanged,
      event: true,
    );
    expect(packetData(earlyPacket).getUint16(28, Endian.little), 90);
    expect(packetData(latePacket).getUint16(28, Endian.little), 90);
    expect(packetData(earlyPacket).getInt32(32, Endian.little), -14400);
    expect(packetData(latePacket).getInt32(32, Endian.little), -18000);
  });

  test('calendar codec rejects malformed mechanical time facts', () {
    expect(
      () => JournalPlatformCodec.encodeCalendar(
        sampleCalendar.copyWith(utcOffsetSeconds: 64801),
        reason: CalendarChangeReason.requested,
        event: false,
      ),
      throwsArgumentError,
    );
    expect(
      () => JournalPlatformCodec.encodeCalendar(
        sampleCalendar.copyWith(localDay: 20260808),
        reason: CalendarChangeReason.requested,
        event: false,
      ),
      throwsArgumentError,
    );
  });

  test('journal day formatter is bounded and generation-fenced', () async {
    var formatCalls = 0;
    final platform = JournalApplicationPlatform(
      calendarSnapshot: () async => sampleCalendar,
      formatJournalDays: ({required snapshot, required days}) async {
        formatCalls += 1;
        return {
          for (final day in days)
            day: day == 20260807 ? 'Friday, August 7' : 'Saturday, August 8',
        };
      },
    );
    addTearDown(platform.dispose);

    await platform.handleRequest(JournalPlatformCodec.getCalendarRequest);
    final request = JournalPlatformCodec.formatJournalDaysRequest(
      generation: 7,
      days: const [20260807, 20260808],
    );
    final response = await platform.handleRequest(request);
    expect(
      JournalPlatformCodec.decodeFormattedJournalDays(response).headings,
      const {20260807: 'Friday, August 7', 20260808: 'Saturday, August 8'},
    );
    expect(formatCalls, 1);
    await expectLater(
      platform.handleRequest(
        JournalPlatformCodec.formatJournalDaysRequest(
          generation: 6,
          days: const [20260807],
        ),
      ),
      throwsStateError,
    );
    expect(
      () => JournalPlatformCodec.formatJournalDaysRequest(
        generation: 7,
        days: List.filled(65, 20260807),
      ),
      throwsArgumentError,
    );
  });

  test(
    'runtime replacement does not retain disposed platform events',
    () async {
      final firstEvents = <Uint8List>[];
      final first = JournalApplicationPlatform(
        calendarSnapshot: () async => sampleCalendar,
        formatJournalDays: ({required snapshot, required days}) async => {},
      );
      final firstSubscription = first.events.listen(firstEvents.add);
      first.dispose();
      await first.refresh(CalendarChangeReason.resumed);
      expect(firstEvents, isEmpty);
      await firstSubscription.cancel();

      final second = JournalApplicationPlatform(
        calendarSnapshot: () async => sampleCalendar.copyWith(generation: 8),
        formatJournalDays: ({required snapshot, required days}) async => {},
      );
      addTearDown(second.dispose);
      final response = await second.handleRequest(
        JournalPlatformCodec.getCalendarRequest,
      );
      expectCalendarPacket(
        response,
        reason: CalendarChangeReason.requested.wireId,
        localMinuteOfDay: 30,
        calendarGeneration: 8,
        lifecycleGeneration: 0,
      );
    },
  );

  test('production factory exposes the managed adapter contract', () {
    expect(createBonsaiFlutterHostAdapter(), isA<ApplicationHostAdapter>());
  });

  test('production adapter rejects every missing native fact', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'journal-platform-missing-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    await Directory(
      '${temporary.path}/logseq/logseq_journal',
    ).create(recursive: true);
    const channel = MethodChannel('logseq_journal/platform');
    final complete = <String, Object>{
      'applicationSupportPath': temporary.path,
      'platform': 'desktop',
      'homeDirectoryPath': temporary.path,
      'graphName': 'logseq_journal',
      'instantUnixMilliseconds': sampleCalendar.instantUnixMilliseconds,
      'localDay': sampleCalendar.localDay,
      'locale': sampleCalendar.locale,
      'timeZoneId': sampleCalendar.timeZoneId,
      'utcOffsetSeconds': sampleCalendar.utcOffsetSeconds,
      'generation': sampleCalendar.generation,
    };
    for (final missing in <String>[
      'applicationSupportPath',
      'platform',
      'homeDirectoryPath',
      'graphName',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final value = Map<String, Object>.of(complete)..remove(missing);
            return value;
          });
      await expectLater(
        createBonsaiFlutterHostAdapter().createApplicationPayload(),
        throwsFormatException,
        reason: missing,
      );
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('production adapter reads one native environment snapshot', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'journal-platform-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final graph = Directory('${temporary.path}/logseq/logseq_journal');
    await graph.create(recursive: true);
    const channel = MethodChannel('logseq_journal/platform');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return <String, Object>{
            'applicationSupportPath': temporary.path,
            'platform': 'desktop',
            'homeDirectoryPath': temporary.path,
            'graphName': 'logseq_journal',
            'instantUnixMilliseconds': sampleCalendar.instantUnixMilliseconds,
            'localDay': sampleCalendar.localDay,
            'locale': sampleCalendar.locale,
            'timeZoneId': sampleCalendar.timeZoneId,
            'utcOffsetSeconds': sampleCalendar.utcOffsetSeconds,
            'generation': sampleCalendar.generation,
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final payload = await createBonsaiFlutterHostAdapter()
        .createApplicationPayload();
    expect(calls, hasLength(1));
    expect(calls.single.method, 'getStartupEnvironment');
    expect(
      payload,
      startupPacket(
        root: await temporary.resolveSymbolicLinks(),
        target: <String, Object>{
          'kind': 'nativeLocalGraph',
          'graphName': 'logseq_journal',
          'graphDir': await graph.resolveSymbolicLinks(),
        },
      ),
    );
  });
}
