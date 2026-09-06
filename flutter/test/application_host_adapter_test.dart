import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bonsai_flutter_logseq_journal_host/application_host_adapter.dart';
import 'package:bonsai_flutter_logseq_journal_host/main.dart';
import 'package:bonsai_flutter/bonsai_flutter.dart';
import 'package:amplify_authenticator/amplify_authenticator.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_slidable/flutter_slidable.dart' as fs;
import 'package:flutter_test/flutter_test.dart';

final class _Auth implements JournalAuthCapability {
  final String? userId = 'cognito-user-1';
  final String token = 'fresh-id-token';
  int currentUserRequests = 0;
  int tokenRequests = 0;
  int signOutRequests = 0;

  @override
  Future<String?> currentUserId() async {
    currentUserRequests += 1;
    return userId;
  }

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

final class _TokenFailureAuth implements JournalAuthCapability {
  _TokenFailureAuth(this.error);

  final Object error;

  @override
  Future<String?> currentUserId() async => 'cognito-user-1';

  @override
  Future<String> freshIdToken() async => throw error;

  @override
  Future<void> signOut() async {}
}

Future<String?> _readBalancedPreference(String key) async {
  expect(key, 'typographyPreset');
  return 'balanced';
}

Future<void> _writePreference(String key, String value) async {
  expect(key, 'typographyPreset');
  expect(value, anyOf('dense', 'balanced', 'comfortable'));
}

ApplicationHostAdapter _localBindingAdapter({
  required JournalAuthCapability auth,
  required Future<void> amplifyReady,
  required Future<void> Function() clearLocalAccountBinding,
}) => ApplicationHostAdapter(
  applicationSupportDirectory: () async => Directory.systemTemp,
  baseUrl: Uri.parse('https://api.example.test'),
  auth: auth,
  readPreference: _readBalancedPreference,
  writePreference: _writePreference,
  readLocalAccountBinding: () async =>
      (userId: 'local-user-1', managedSyncOrigin: 'https://api.example.test'),
  clearLocalAccountBinding: clearLocalAccountBinding,
  amplifyReady: amplifyReady,
);

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

Uint8List rawJsonRequest(int tag, Map<String, Object?> payload) {
  final json = utf8.encode(jsonEncode(payload));
  final value = Uint8List(32 + json.length);
  value.setRange(0, 4, ascii.encode('LJP2'));
  final data = ByteData.sublistView(value);
  data.setUint16(4, 2, Endian.little);
  data.setUint16(6, tag, Endian.little);
  data.setUint32(24, json.length, Endian.little);
  value.setRange(32, value.length, json);
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
        auth: _Auth(),
        readPreference: _readBalancedPreference,
        writePreference: _writePreference,
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
        auth: _Auth(),
        readPreference: _readBalancedPreference,
        writePreference: _writePreference,
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
      final autoClose = tester.widget<fs.SlidableAutoCloseBehavior>(
        find.byType(fs.SlidableAutoCloseBehavior),
      );
      expect(autoClose.closeWhenOpened, isTrue);
      expect(autoClose.closeWhenTapped, isTrue);
    },
  );

  testWidgets(
    'local binding presents the application while Amplify configuration is pending',
    (tester) async {
      final configuration = Completer<void>();
      final adapter = ApplicationHostAdapter(
        applicationSupportDirectory: () async => Directory.systemTemp,
        baseUrl: Uri.parse('https://api.example.test'),
        auth: _Auth(),
        readPreference: _readBalancedPreference,
        writePreference: _writePreference,
        readLocalAccountBinding: () async => (
          userId: 'local-user-1',
          managedSyncOrigin: 'https://api.example.test',
        ),
        amplifyReady: configuration.future,
      );

      await tester.pumpWidget(
        Builder(
          builder: (context) => adapter.buildHost(
            context: context,
            child: const Text('Local Timeline'),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Local Timeline'), findsOneWidget);
      expect(find.byType(Authenticator), findsNothing);
      expect(configuration.isCompleted, isFalse);
    },
  );

  testWidgets(
    'signed-out token request clears stale binding and restores the authentication gate',
    (tester) async {
      final configuration = Completer<void>();
      var clears = 0;
      final adapter = _localBindingAdapter(
        auth: _TokenFailureAuth(
          const SignedOutException('Authentication is required'),
        ),
        amplifyReady: configuration.future,
        clearLocalAccountBinding: () async {
          clears += 1;
        },
      );
      final platform =
          adapter.createApplicationPlatform() as JournalApplicationPlatform;
      addTearDown(platform.dispose);

      await tester.pumpWidget(
        Builder(
          builder: (context) => adapter.buildHost(
            context: context,
            child: const Text('Local Timeline'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Local Timeline'), findsOneWidget);

      await expectLater(
        platform.handleRequest(
          request(JournalPlatformTag.idTokenRequest, {
            'challengeId': 'challenge-1',
          }),
        ),
        throwsA(isA<SignedOutException>()),
      );
      await tester.pump();

      expect(clears, 1);
      expect(find.text('Local Timeline'), findsNothing);
      expect(find.byType(Authenticator), findsNothing);
      expect(configuration.isCompleted, isFalse);
    },
  );

  testWidgets(
    'non-auth token failure preserves the offline binding and local application',
    (tester) async {
      final configuration = Completer<void>();
      var clears = 0;
      final adapter = _localBindingAdapter(
        auth: _TokenFailureAuth(StateError('temporary token failure')),
        amplifyReady: configuration.future,
        clearLocalAccountBinding: () async {
          clears += 1;
        },
      );
      final platform =
          adapter.createApplicationPlatform() as JournalApplicationPlatform;
      addTearDown(platform.dispose);

      await tester.pumpWidget(
        Builder(
          builder: (context) => adapter.buildHost(
            context: context,
            child: const Text('Local Timeline'),
          ),
        ),
      );
      await tester.pump();

      await expectLater(
        platform.handleRequest(
          request(JournalPlatformTag.idTokenRequest, {
            'challengeId': 'challenge-1',
          }),
        ),
        throwsA(isA<StateError>()),
      );
      await tester.pump();

      expect(clears, 0);
      expect(find.text('Local Timeline'), findsOneWidget);
      expect(find.byType(Authenticator), findsNothing);
      expect(configuration.isCompleted, isFalse);
    },
  );

  test(
    'application platform signs out through the authenticated host',
    () async {
      final auth = _Auth();
      final platform = JournalApplicationPlatform(
        auth: auth,
        readPreference: _readBalancedPreference,
        writePreference: _writePreference,
      );
      addTearDown(platform.dispose);

      final response = await platform.handleRequest(rawRequest(10));

      expect(responseJson(response), {'signedOut': true});
      expect(auth.signOutRequests, 1);
    },
  );

  test(
    'typography reads the retained startup preference and writes through native storage',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('logseq_journal/platform'),
            (call) async {
              calls.add(call);
              switch (call.method) {
                case 'getStartupEnvironment':
                  return <String, Object?>{
                    'applicationSupportPath': Directory.systemTemp.path,
                    'typographyPreset': 'dense',
                    'localAccountBinding': null,
                  };
                case 'setPreference':
                  expect(call.arguments, {
                    'key': 'typographyPreset',
                    'value': 'comfortable',
                  });
                  return null;
              }
              throw StateError('unexpected native call ${call.method}');
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('logseq_journal/platform'),
              null,
            ),
      );

      final adapter = createBonsaiFlutterHostAdapter(
        baseUrl: Uri.parse('https://api.example.test'),
      );
      final platform = adapter.createApplicationPlatform();
      addTearDown((platform as JournalApplicationPlatform).dispose);

      final loaded = await platform.handleRequest(
        rawJsonRequest(16, {'key': 'typographyPreset'}),
      );
      expect(ByteData.sublistView(loaded).getUint16(6, Endian.little), 17);
      expect(responseJson(loaded), {
        'key': 'typographyPreset',
        'value': 'dense',
      });

      final stored = await platform.handleRequest(
        rawJsonRequest(18, {'key': 'typographyPreset', 'value': 'comfortable'}),
      );
      expect(ByteData.sublistView(stored).getUint16(6, Endian.little), 19);
      expect(responseJson(stored), {'key': 'typographyPreset', 'stored': true});
      expect(calls.map((call) => call.method), [
        'getStartupEnvironment',
        'setPreference',
      ]);
    },
  );

  test(
    'termination waits for native graph cleanup before runtime shutdown',
    () async {
      var runtimeShutdowns = 0;
      final platform = JournalApplicationPlatform(
        auth: _Auth(),
        readPreference: _readBalancedPreference,
        writePreference: _writePreference,
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
    final entrypoint = File('lib/main.dart');
    expect(entrypoint.existsSync(), isTrue);
    if (!entrypoint.existsSync()) return;
    final source = entrypoint.readAsStringSync();
    expect(source, isNot(contains('await JournalAmplify.configure()')));
    expect(source, contains('amplifyReady: amplifyReady'));
    expect(source, contains('Unable to configure authentication'));
    expect(source, contains('Retry'));
    expect(RegExp(r'MaterialApp\(').allMatches(source), hasLength(1));
    expect(
      source,
      isNot(contains("child: MaterialApp(title: 'Logseq Journal'")),
    );
    final project = File('../bonsai-flutter.sexp').readAsStringSync();
    expect(project, contains('(mode custom)'));
    expect(project, contains('(main lib/main.dart)'));
    expect(File('lib/application.dart').existsSync(), isFalse);
  });

  test('hidden paused resume emits one coalesced background epoch', () async {
    final platform = JournalApplicationPlatform(
      auth: _Auth(),
      readPreference: _readBalancedPreference,
      writePreference: _writePreference,
    );
    addTearDown(platform.dispose);
    final events = <Uint8List>[];
    final subscription = platform.events.listen(events.add);
    addTearDown(subscription.cancel);

    platform.didChangeAppLifecycleState(AppLifecycleState.hidden);
    platform.didChangeAppLifecycleState(AppLifecycleState.paused);
    platform.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    expect(events.map(rawEventTag), containsAllInOrder(<int>[15, 15]));
    final lifecycleEvents = events
        .where((event) => rawEventTag(event) == 15)
        .toList();
    expect(lifecycleEvents, hasLength(2));
    expect(lifecycleEvents.map(rawLifecycleKind), <int>[1, 2]);
    expect(lifecycleEvents.map(rawLifecycleGeneration), <int>[1, 1]);

    platform.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(events.where((event) => rawEventTag(event) == 15), hasLength(2));
  });

  testWidgets('background resume does not recreate the root runtime', (
    tester,
  ) async {
    final adapter = _PendingHostAdapter();
    await tester.pumpWidget(
      JournalApplicationHost(
        adapter: adapter,
        runtimeOwner: JournalRuntimeOwner(),
      ),
    );
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
        auth: auth,
        readPreference: _readBalancedPreference,
        writePreference: _writePreference,
      );
      addTearDown(platform.dispose);

      final user = await platform.handleRequest(
        request(JournalPlatformTag.authenticatedUserRequest),
      );
      expect(responseJson(user), {'userId': 'cognito-user-1'});

      final token = await platform.handleRequest(
        request(JournalPlatformTag.idTokenRequest, {
          'challengeId': 'challenge-1',
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
    'local account binding starts the local lane without consulting Amplify',
    () async {
      final auth = _Auth();
      var frameWaits = 0;
      final platform = JournalApplicationPlatform(
        auth: auth,
        readPreference: _readBalancedPreference,
        writePreference: _writePreference,
        managedSyncOrigin: 'https://api.example.test',
        readLocalAccountBinding: () async => (
          userId: 'local-user-1',
          managedSyncOrigin: 'https://api.example.test',
        ),
        waitForPresentationFrame: () async {
          frameWaits += 1;
        },
      );
      addTearDown(platform.dispose);

      final local = await platform.handleRequest(rawRequest(20));
      expect(responseJson(local), {
        'userId': 'local-user-1',
        'managedSyncOrigin': 'https://api.example.test',
      });
      expect(auth.currentUserRequests, 0);
      expect(auth.tokenRequests, 0);

      final presented = await platform.handleRequest(rawRequest(22));
      expect(responseJson(presented), {'presented': true});
      expect(frameWaits, 1);
    },
  );

  test(
    'authenticated reconciliation persists and explicit sign-out clears the binding',
    () async {
      final auth = _Auth();
      final persisted = <JournalLocalAccountBinding>[];
      var clears = 0;
      final platform = JournalApplicationPlatform(
        auth: auth,
        readPreference: _readBalancedPreference,
        writePreference: _writePreference,
        managedSyncOrigin: 'https://api.example.test',
        persistLocalAccountBinding: (binding) async => persisted.add(binding),
        clearLocalAccountBinding: () async {
          clears += 1;
        },
      );
      addTearDown(platform.dispose);

      final user = await platform.handleRequest(rawRequest(6));
      expect(responseJson(user), {'userId': 'cognito-user-1'});
      expect(persisted, [
        (
          userId: 'cognito-user-1',
          managedSyncOrigin: 'https://api.example.test',
        ),
      ]);

      await platform.handleRequest(rawRequest(10));
      expect(clears, 1);
    },
  );

  test(
    'production startup facts retain typography and local binding in one call',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('logseq_journal/platform'),
            (call) async {
              calls.add(call);
              if (call.method == 'getStartupEnvironment') {
                return <String, Object?>{
                  'applicationSupportPath': Directory.systemTemp.path,
                  'typographyPreset': 'comfortable',
                  'localAccountBinding': <String, Object>{
                    'version': 1,
                    'userId': 'local-user-1',
                    'managedSyncOrigin': 'https://api.example.test',
                  },
                };
              }
              throw StateError('unexpected native call ${call.method}');
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('logseq_journal/platform'),
              null,
            ),
      );

      final adapter = createBonsaiFlutterHostAdapter(
        baseUrl: Uri.parse('https://api.example.test'),
      );
      await adapter.createApplicationPayload();
      final platform =
          adapter.createApplicationPlatform() as JournalApplicationPlatform;
      addTearDown(platform.dispose);

      final typography = await platform.handleRequest(
        rawJsonRequest(16, {'key': 'typographyPreset'}),
      );
      expect(responseJson(typography), {
        'key': 'typographyPreset',
        'value': 'comfortable',
      });
      final binding = await platform.handleRequest(rawRequest(20));
      expect(responseJson(binding), {
        'userId': 'local-user-1',
        'managedSyncOrigin': 'https://api.example.test',
      });
      expect(calls.map((call) => call.method), ['getStartupEnvironment']);
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
