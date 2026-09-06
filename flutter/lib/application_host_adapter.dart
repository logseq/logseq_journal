import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:amplify_authenticator/amplify_authenticator.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:bonsai_flutter/bonsai_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart' as fs;

import 'journal_platform_menu.dart';

const _platformChannel = MethodChannel('logseq_journal/platform');

enum JournalStartupMilestone {
  dartEntrypointStarted,
  amplifyConfigurationComplete,
  nativeStartupFactsAvailable,
  runtimeStarted,
  localAccountBindingLoaded,
  firstIdTokenRequested,
  timelineFramePresented,
}

abstract final class JournalStartupTimeline {
  static final Stopwatch _clock = Stopwatch()..start();
  static final Map<JournalStartupMilestone, int> _elapsedMicroseconds = {};

  static void mark(JournalStartupMilestone milestone) {
    if (_elapsedMicroseconds.containsKey(milestone)) return;
    final elapsed = _clock.elapsedMicroseconds;
    _elapsedMicroseconds[milestone] = elapsed;
    developer.Timeline.instantSync(
      'logseq_journal.${milestone.name}',
      arguments: <String, Object>{'elapsedMicroseconds': elapsed},
    );
  }

  static Map<JournalStartupMilestone, int> snapshot() =>
      Map<JournalStartupMilestone, int>.unmodifiable(_elapsedMicroseconds);
}

enum JournalPlatformTag {
  authenticatedUserRequest(6),
  authenticatedUserResponse(7),
  idTokenRequest(8),
  idTokenResponse(9),
  signOutRequest(10),
  signOutResponse(11),
  prepareToTerminateEvent(12),
  terminationReadyRequest(13),
  terminationReadyResponse(14),
  networkLifecycleEvent(15),
  preferenceGetRequest(16),
  preferenceGetResponse(17),
  preferenceSetRequest(18),
  preferenceSetResponse(19),
  localAccountBindingRequest(20),
  localAccountBindingResponse(21),
  timelinePresentedRequest(22),
  timelinePresentedResponse(23);

  const JournalPlatformTag(this.wireId);
  final int wireId;

  static JournalPlatformTag fromWireId(int value) => values.firstWhere(
    (entry) => entry.wireId == value,
    orElse: () => throw FormatException('unsupported platform tag $value'),
  );
}

final class JournalPlatformEnvelope {
  const JournalPlatformEnvelope({required this.tag, required this.payload});
  final JournalPlatformTag tag;
  final Uint8List payload;
}

abstract final class JournalPlatformEnvelopeCodec {
  static const maximumPayloadBytes = 256 * 1024;
  static const _headerBytes = 32;

  static Uint8List encode(JournalPlatformEnvelope envelope) {
    if (envelope.payload.length > maximumPayloadBytes) {
      throw const FormatException('platform payload exceeds its bound');
    }
    final result = Uint8List(_headerBytes + envelope.payload.length);
    result.setRange(0, 4, ascii.encode('LJP2'));
    final data = ByteData.sublistView(result);
    data.setUint16(4, 2, Endian.little);
    data.setUint16(6, envelope.tag.wireId, Endian.little);
    data.setUint32(24, envelope.payload.length, Endian.little);
    result.setRange(_headerBytes, result.length, envelope.payload);
    return result;
  }

  static JournalPlatformEnvelope decode(Uint8List value) {
    if (value.length < _headerBytes ||
        value.length > _headerBytes + maximumPayloadBytes ||
        ascii.decode(value.sublist(0, 4), allowInvalid: true) != 'LJP2') {
      throw const FormatException('invalid platform envelope');
    }
    final data = ByteData.sublistView(value);
    final length = data.getUint32(24, Endian.little);
    if (data.getUint16(4, Endian.little) != 2 ||
        data.getInt64(8, Endian.little) != 0 ||
        data.getInt64(16, Endian.little) != 0 ||
        data.getUint32(28, Endian.little) != 0 ||
        length != value.length - _headerBytes) {
      throw const FormatException('unsupported platform envelope');
    }
    return JournalPlatformEnvelope(
      tag: JournalPlatformTag.fromWireId(data.getUint16(6, Endian.little)),
      payload: Uint8List.sublistView(value, _headerBytes),
    );
  }
}

final class LogseqDbWorkerStartupEnvelope {
  const LogseqDbWorkerStartupEnvelope({
    required this.applicationSupportDirectory,
    required this.baseUrl,
  });

  final String applicationSupportDirectory;
  final Uri baseUrl;

  Uint8List encode() {
    _validateCanonicalAbsolutePath(applicationSupportDirectory);
    if (baseUrl.scheme != 'https' ||
        baseUrl.host.isEmpty ||
        baseUrl.userInfo.isNotEmpty ||
        baseUrl.hasFragment ||
        baseUrl.path.isNotEmpty ||
        baseUrl.hasQuery) {
      throw const FormatException('sync base URL must be one HTTPS origin');
    }
    final json = utf8.encode(
      jsonEncode(<String, Object>{
        'applicationSupportDirectory': applicationSupportDirectory,
        'target': <String, Object>{
          'kind': 'managedSync',
          'baseUrl': baseUrl.toString(),
        },
        'compatibilityProfile': 'logseq-65.33-or-newer',
        'responseBudgetBytes': 262144,
        'defaultPageSize': 50,
      }),
    );
    if (json.length + 8 > 1024 * 1024) {
      throw const FormatException('startup payload exceeds its bound');
    }
    final result = Uint8List(8 + json.length);
    result.setRange(0, 4, ascii.encode('LDB1'));
    ByteData.sublistView(result).setUint32(4, json.length, Endian.little);
    result.setRange(8, result.length, json);
    return result;
  }
}

void _validateCanonicalAbsolutePath(String value) {
  final components = value.split('/');
  if (!value.startsWith('/') ||
      value == '/' ||
      components
          .skip(1)
          .any(
            (component) =>
                component.isEmpty || component == '.' || component == '..',
          ) ||
      value.contains('\\') ||
      value.contains('\u0000') ||
      utf8.encode(value).length > 4096) {
    throw const FormatException('application support path is invalid');
  }
}

enum NetworkLifecycleKind {
  backgrounded(1),
  foregroundResumed(2);

  const NetworkLifecycleKind(this.wireId);
  final int wireId;
}

typedef JournalPreferenceReader = Future<String?> Function(String key);
typedef JournalPreferenceWriter =
    Future<void> Function(String key, String value);
typedef JournalLocalAccountBinding = ({
  String userId,
  String managedSyncOrigin,
});
typedef JournalLocalAccountBindingReader =
    Future<JournalLocalAccountBinding?> Function();
typedef JournalLocalAccountBindingWriter =
    Future<void> Function(JournalLocalAccountBinding binding);
typedef JournalLocalAccountBindingClearer = Future<void> Function();

Future<JournalLocalAccountBinding?> _noLocalAccountBinding() async => null;
Future<void> _ignoreLocalAccountBinding(JournalLocalAccountBinding _) async {}
Future<void> _ignoreLocalAccountBindingClear() async {}
Future<void> _waitForFlutterPresentationFrame() =>
    WidgetsBinding.instance.endOfFrame;

abstract final class JournalPlatformCodec {
  static int requestTag(Uint8List request) =>
      JournalPlatformEnvelopeCodec.decode(request).tag.wireId;

  static void validateEmpty(Uint8List request, JournalPlatformTag tag) {
    final envelope = JournalPlatformEnvelopeCodec.decode(request);
    if (envelope.tag != tag || envelope.payload.isNotEmpty) {
      throw const FormatException('invalid empty platform request');
    }
  }

  static Map<String, dynamic> decodeJsonRequest(
    Uint8List request,
    JournalPlatformTag tag,
  ) {
    final envelope = JournalPlatformEnvelopeCodec.decode(request);
    if (envelope.tag != tag || envelope.payload.isEmpty) {
      throw const FormatException('invalid JSON platform request');
    }
    final value = jsonDecode(utf8.decode(envelope.payload));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('platform request must be a JSON object');
    }
    return value;
  }

  static Uint8List encodeNetworkLifecycle({
    required NetworkLifecycleKind kind,
    required int generation,
  }) {
    if (generation < 0) {
      throw const FormatException('network lifecycle generation is invalid');
    }
    final payload = Uint8List(16);
    payload.setRange(0, 4, ascii.encode('LJP1'));
    final data = ByteData.sublistView(payload);
    data.setUint16(4, 1, Endian.little);
    data.setUint16(6, kind.wireId, Endian.little);
    data.setInt64(8, generation, Endian.little);
    return JournalPlatformEnvelopeCodec.encode(
      JournalPlatformEnvelope(
        tag: JournalPlatformTag.networkLifecycleEvent,
        payload: payload,
      ),
    );
  }

  static ({String challengeId}) decodeIdTokenRequest(Uint8List request) {
    final envelope = JournalPlatformEnvelopeCodec.decode(request);
    if (envelope.tag != JournalPlatformTag.idTokenRequest) {
      throw const FormatException('invalid ID-token request');
    }
    final Object? decoded = jsonDecode(
      utf8.decode(envelope.payload, allowMalformed: false),
    );
    if (decoded is! Map<String, dynamic> ||
        decoded.keys.toSet().difference({'challengeId'}).isNotEmpty ||
        decoded.length != 1 ||
        decoded['challengeId'] is! String) {
      throw const FormatException('invalid ID-token request');
    }
    return (challengeId: decoded['challengeId']! as String);
  }

  static Uint8List encodeJson(JournalPlatformTag tag, Object value) {
    return JournalPlatformEnvelopeCodec.encode(
      JournalPlatformEnvelope(
        tag: tag,
        payload: Uint8List.fromList(utf8.encode(jsonEncode(value))),
      ),
    );
  }
}

abstract final class JournalAmplify {
  static Future<void>? _configured;

  static Future<void> configure() async {
    final existing = _configured;
    if (existing != null) return existing;
    final pending = _configure();
    _configured = pending;
    try {
      await pending;
    } catch (_) {
      if (identical(_configured, pending)) _configured = null;
      rethrow;
    }
  }

  static Future<void> _configure() async {
    if (Amplify.isConfigured) return;
    await Amplify.addPlugin(AmplifyAuthCognito());
    await Amplify.configure(
      jsonEncode(<String, Object>{
        'version': '1',
        'auth': <String, Object>{
          'aws_region': 'us-east-1',
          'user_pool_id': 'us-east-1_dtagLnju8',
          'user_pool_client_id': '69cs1lgme7p8kbgld8n5kseii6',
          'password_policy': <String, Object>{
            'min_length': 8,
            'require_numbers': true,
            'require_lowercase': true,
            'require_uppercase': true,
            'require_symbols': true,
          },
          'standard_required_attributes': <String>['email'],
          'username_attributes': <String>[],
          'user_verification_types': <String>['email'],
          'unauthenticated_identities_enabled': false,
        },
      }),
    );
  }
}

abstract interface class JournalAuthCapability {
  Future<String?> currentUserId();
  Future<String> freshIdToken();
  Future<void> signOut();
}

final class JournalAmplifySession implements JournalAuthCapability {
  @override
  Future<String?> currentUserId() async {
    await JournalAmplify.configure();
    try {
      final session = await Amplify.Auth.fetchAuthSession();
      if (!session.isSignedIn) return null;
      return (await Amplify.Auth.getCurrentUser()).userId;
    } on SignedOutException {
      return null;
    }
  }

  @override
  Future<String> freshIdToken() async {
    await JournalAmplify.configure();
    final session = await Amplify.Auth.fetchAuthSession();
    if (!session.isSignedIn || session is! CognitoAuthSession) {
      throw const SignedOutException('Authentication is required');
    }
    final token = session.userPoolTokensResult.value.idToken.raw;
    if (token.isEmpty ||
        token.contains('\u0000') ||
        utf8.encode(token).length >
            JournalPlatformEnvelopeCodec.maximumPayloadBytes) {
      throw const FormatException('ID token is invalid');
    }
    return token;
  }

  @override
  Future<void> signOut() async {
    await JournalAmplify.configure();
    await Amplify.Auth.signOut();
  }
}

final class JournalApplicationPlatform extends WidgetsBindingObserver
    implements BonsaiFlutterApplicationPlatform {
  JournalApplicationPlatform({
    required this.auth,
    required this.readPreference,
    required this.writePreference,
    this.managedSyncOrigin = 'https://api.logseq.io',
    this.readLocalAccountBinding = _noLocalAccountBinding,
    this.persistLocalAccountBinding = _ignoreLocalAccountBinding,
    this.clearLocalAccountBinding = _ignoreLocalAccountBindingClear,
    this.waitForPresentationFrame = _waitForFlutterPresentationFrame,
    this.prepareToTerminate,
  }) {
    WidgetsBinding.instance.addObserver(this);
    _platformChannel.setMethodCallHandler(_handleNativeSignal);
    _authEvents = Amplify.Hub.listen<AuthUser, AuthHubEvent>(HubChannel.Auth, (
      _,
    ) {
      unawaited(_emitAuthenticatedUser());
    });
  }

  final JournalAuthCapability auth;
  final JournalPreferenceReader readPreference;
  final JournalPreferenceWriter writePreference;
  final String managedSyncOrigin;
  final JournalLocalAccountBindingReader readLocalAccountBinding;
  final JournalLocalAccountBindingWriter persistLocalAccountBinding;
  final JournalLocalAccountBindingClearer clearLocalAccountBinding;
  final Future<void> Function() waitForPresentationFrame;
  final Future<void> Function()? prepareToTerminate;
  final StreamController<Uint8List> _events =
      StreamController<Uint8List>.broadcast(sync: true);
  StreamSubscription<AuthHubEvent>? _authEvents;
  Completer<void>? _terminationReady;
  Future<void>? _termination;
  int _lifecycleGeneration = 0;
  bool _backgrounded = false;
  bool _disposed = false;

  @override
  Stream<Uint8List> get events => _events.stream;

  Uint8List _authenticatedUserResponse(String? userId) {
    return JournalPlatformCodec.encodeJson(
      JournalPlatformTag.authenticatedUserResponse,
      <String, Object?>{'userId': userId},
    );
  }

  Future<Uint8List> _currentAuthenticatedUserResponse() async {
    final userId = await auth.currentUserId();
    if (userId != null) {
      try {
        await persistLocalAccountBinding((
          userId: userId,
          managedSyncOrigin: managedSyncOrigin,
        ));
      } catch (_) {
        // Advisory warm-start state must not block online reconciliation.
      }
    }
    return _authenticatedUserResponse(userId);
  }

  Future<void> _emitAuthenticatedUser() async {
    if (_disposed) return;
    final response = await _currentAuthenticatedUserResponse();
    if (!_disposed) _events.add(response);
  }

  @override
  Future<Uint8List> handleRequest(Uint8List request) async {
    switch (JournalPlatformCodec.requestTag(request)) {
      case 6:
        JournalPlatformCodec.validateEmpty(
          request,
          JournalPlatformTag.authenticatedUserRequest,
        );
        return _currentAuthenticatedUserResponse();
      case 8:
        final decoded = JournalPlatformCodec.decodeIdTokenRequest(request);
        JournalStartupTimeline.mark(
          JournalStartupMilestone.firstIdTokenRequested,
        );
        late final String token;
        try {
          token = await auth.freshIdToken();
        } on SignedOutException {
          await clearLocalAccountBinding();
          rethrow;
        }
        return JournalPlatformCodec.encodeJson(
          JournalPlatformTag.idTokenResponse,
          <String, Object>{'challengeId': decoded.challengeId, 'token': token},
        );
      case 10:
        JournalPlatformCodec.validateEmpty(
          request,
          JournalPlatformTag.signOutRequest,
        );
        await auth.signOut();
        await clearLocalAccountBinding();
        return JournalPlatformCodec.encodeJson(
          JournalPlatformTag.signOutResponse,
          <String, Object>{'signedOut': true},
        );
      case 13:
        JournalPlatformCodec.validateEmpty(
          request,
          JournalPlatformTag.terminationReadyRequest,
        );
        final ready = _terminationReady;
        if (ready != null && !ready.isCompleted) ready.complete();
        return JournalPlatformCodec.encodeJson(
          JournalPlatformTag.terminationReadyResponse,
          <String, Object>{'ready': true},
        );
      case 16:
        final decoded = JournalPlatformCodec.decodeJsonRequest(
          request,
          JournalPlatformTag.preferenceGetRequest,
        );
        if (decoded.length != 1 || decoded['key'] != 'typographyPreset') {
          throw const FormatException('preference-get request is invalid');
        }
        final value = await readPreference('typographyPreset');
        if (value != null &&
            (value.isEmpty || utf8.encode(value).length > 64)) {
          throw const FormatException('stored preference value is invalid');
        }
        return JournalPlatformCodec.encodeJson(
          JournalPlatformTag.preferenceGetResponse,
          <String, Object?>{'key': 'typographyPreset', 'value': value},
        );
      case 18:
        final decoded = JournalPlatformCodec.decodeJsonRequest(
          request,
          JournalPlatformTag.preferenceSetRequest,
        );
        final value = decoded['value'];
        if (decoded.length != 2 ||
            decoded['key'] != 'typographyPreset' ||
            (value != 'dense' &&
                value != 'balanced' &&
                value != 'comfortable')) {
          throw const FormatException('preference-set request is invalid');
        }
        await writePreference('typographyPreset', value! as String);
        return JournalPlatformCodec.encodeJson(
          JournalPlatformTag.preferenceSetResponse,
          <String, Object>{'key': 'typographyPreset', 'stored': true},
        );
      case 20:
        JournalPlatformCodec.validateEmpty(
          request,
          JournalPlatformTag.localAccountBindingRequest,
        );
        final binding = await readLocalAccountBinding();
        JournalStartupTimeline.mark(
          JournalStartupMilestone.localAccountBindingLoaded,
        );
        if (binding != null &&
            (binding.userId.isEmpty ||
                utf8.encode(binding.userId).length > 512 ||
                binding.managedSyncOrigin != managedSyncOrigin)) {
          throw const FormatException('local account binding is invalid');
        }
        return JournalPlatformCodec.encodeJson(
          JournalPlatformTag.localAccountBindingResponse,
          <String, Object?>{
            'userId': binding?.userId,
            'managedSyncOrigin': binding?.managedSyncOrigin,
          },
        );
      case 22:
        JournalPlatformCodec.validateEmpty(
          request,
          JournalPlatformTag.timelinePresentedRequest,
        );
        await waitForPresentationFrame();
        JournalStartupTimeline.mark(
          JournalStartupMilestone.timelineFramePresented,
        );
        return JournalPlatformCodec.encodeJson(
          JournalPlatformTag.timelinePresentedResponse,
          <String, Object>{'presented': true},
        );
      default:
        throw const FormatException('unsupported application platform request');
    }
  }

  Future<void> _handleNativeSignal(MethodCall call) async {
    if (call.method == 'prepareToTerminate') {
      await prepareForTermination();
    }
  }

  Future<void> prepareForTermination() =>
      _termination ??= _prepareForTerminationOnce();

  Future<void> _prepareForTerminationOnce() async {
    if (!_disposed) {
      final ready = Completer<void>();
      _terminationReady = ready;
      _events.add(
        JournalPlatformEnvelopeCodec.encode(
          JournalPlatformEnvelope(
            tag: JournalPlatformTag.prepareToTerminateEvent,
            payload: Uint8List(0),
          ),
        ),
      );
      try {
        await ready.future.timeout(const Duration(seconds: 4));
      } on TimeoutException {
        // The AppDelegate watchdog guarantees process termination if cleanup stalls.
      }
    }
    await prepareToTerminate?.call();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (!_backgrounded) {
          _backgrounded = true;
          _lifecycleGeneration += 1;
          _events.add(
            JournalPlatformCodec.encodeNetworkLifecycle(
              kind: NetworkLifecycleKind.backgrounded,
              generation: _lifecycleGeneration,
            ),
          );
        }
        break;
      case AppLifecycleState.resumed:
        if (_backgrounded) {
          _backgrounded = false;
          _events.add(
            JournalPlatformCodec.encodeNetworkLifecycle(
              kind: NetworkLifecycleKind.foregroundResumed,
              generation: _lifecycleGeneration,
            ),
          );
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _platformChannel.setMethodCallHandler(null);
    unawaited(_authEvents?.cancel());
    _authEvents = null;
    unawaited(_events.close());
  }
}

final class _NativeStartupEnvironment {
  Future<Map<Object?, Object?>>? _pending;

  Future<Map<Object?, Object?>> _load() => _pending ??= _platformChannel
      .invokeMapMethod<Object?, Object?>('getStartupEnvironment')
      .then((value) {
        if (value == null) {
          throw const FormatException('native startup environment is missing');
        }
        JournalStartupTimeline.mark(
          JournalStartupMilestone.nativeStartupFactsAvailable,
        );
        return value;
      });

  Future<Directory> applicationSupportDirectory() async {
    final path = (await _load())['applicationSupportPath'];
    if (path is! String || path.isEmpty) {
      throw const FormatException('native Application Support path is invalid');
    }
    return Directory(path);
  }

  Future<String?> readPreference(String key) async {
    if (key != 'typographyPreset') {
      throw const FormatException('native preference key is invalid');
    }
    final value = (await _load())['typographyPreset'];
    if (value != null && value is! String) {
      throw const FormatException('native preference value is invalid');
    }
    return value as String?;
  }

  Future<JournalLocalAccountBinding?> readLocalAccountBinding() async {
    final value = (await _load())['localAccountBinding'];
    if (value == null) return null;
    if (value is! Map ||
        value.length != 3 ||
        value['version'] != 1 ||
        value['userId'] is! String ||
        value['managedSyncOrigin'] is! String) {
      throw const FormatException('native local account binding is invalid');
    }
    return (
      userId: value['userId']! as String,
      managedSyncOrigin: value['managedSyncOrigin']! as String,
    );
  }

  Future<void> persistLocalAccountBinding(JournalLocalAccountBinding binding) =>
      _platformChannel.invokeMethod<void>('setLocalAccountBinding', {
        'version': 1,
        'userId': binding.userId,
        'managedSyncOrigin': binding.managedSyncOrigin,
      });

  Future<void> clearLocalAccountBinding() =>
      _platformChannel.invokeMethod<void>('clearLocalAccountBinding');

  Future<void> writePreference(String key, String value) async {
    if (key != 'typographyPreset' ||
        (value != 'dense' && value != 'balanced' && value != 'comfortable')) {
      throw const FormatException('native preference write is invalid');
    }
    await _platformChannel.invokeMethod<void>('setPreference', <String, Object>{
      'key': key,
      'value': value,
    });
  }
}

typedef ApplicationSupportDirectoryProvider = Future<Directory> Function();

final class ApplicationHostAdapter implements BonsaiFlutterHostAdapter {
  ApplicationHostAdapter({
    required this.applicationSupportDirectory,
    required this.baseUrl,
    required this.auth,
    required this.readPreference,
    required this.writePreference,
    this.readLocalAccountBinding = _noLocalAccountBinding,
    this.persistLocalAccountBinding = _ignoreLocalAccountBinding,
    this.clearLocalAccountBinding = _ignoreLocalAccountBindingClear,
    this.amplifyReady,
    this.authenticationFailureBuilder,
    this.prepareToTerminate,
  });

  final ApplicationSupportDirectoryProvider applicationSupportDirectory;
  final Uri baseUrl;
  final JournalAuthCapability auth;
  final JournalPreferenceReader readPreference;
  final JournalPreferenceWriter writePreference;
  final JournalLocalAccountBindingReader readLocalAccountBinding;
  final JournalLocalAccountBindingWriter persistLocalAccountBinding;
  final JournalLocalAccountBindingClearer clearLocalAccountBinding;
  final Future<void>? amplifyReady;
  final Widget Function()? authenticationFailureBuilder;
  final Future<void> Function()? prepareToTerminate;
  final ValueNotifier<bool?> _localBindingAvailable = ValueNotifier(null);
  late final Future<JournalLocalAccountBinding?> _initialLocalAccountBinding =
      readLocalAccountBinding().then(
        (binding) {
          _localBindingAvailable.value = binding != null;
          return binding;
        },
        onError: (Object _) {
          _localBindingAvailable.value = false;
          return null;
        },
      );

  @override
  Future<Uint8List> createApplicationPayload() async {
    final directory = await applicationSupportDirectory();
    if (!await directory.exists()) await directory.create(recursive: true);
    final root = await directory.resolveSymbolicLinks();
    return LogseqDbWorkerStartupEnvelope(
      applicationSupportDirectory: root,
      baseUrl: baseUrl,
    ).encode();
  }

  @override
  BonsaiFlutterApplicationPlatform createApplicationPlatform() =>
      JournalApplicationPlatform(
        auth: auth,
        readPreference: readPreference,
        writePreference: writePreference,
        managedSyncOrigin: baseUrl.toString(),
        readLocalAccountBinding: () => _initialLocalAccountBinding,
        persistLocalAccountBinding: persistLocalAccountBinding,
        clearLocalAccountBinding: () async {
          await clearLocalAccountBinding();
          _localBindingAvailable.value = false;
        },
        prepareToTerminate: prepareToTerminate,
      );

  @override
  Widget buildHost({required BuildContext context, required Widget child}) {
    unawaited(_initialLocalAccountBinding);
    Widget authenticatedHost() => Authenticator(
      authenticatorBuilder: (context, state) {
        if (state.currentStep == AuthenticatorStep.signIn ||
            state.currentStep == AuthenticatorStep.signUp) {
          return Scaffold(
            body: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: SignInForm(),
                  ),
                ),
              ),
            ),
          );
        }
        return null;
      },
      child: _AuthenticatedJournalHost(child: child),
    );
    Widget onlineAuthenticationGate() {
      final ready = amplifyReady;
      if (ready == null) return authenticatedHost();
      return FutureBuilder<void>(
        future: ready,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done &&
              snapshot.error == null) {
            return authenticatedHost();
          }
          if (snapshot.error != null) {
            return authenticationFailureBuilder?.call() ??
                const MaterialApp(
                  home: Center(
                    child: Text('Unable to configure authentication'),
                  ),
                );
          }
          return const MaterialApp(
            home: Center(child: CircularProgressIndicator()),
          );
        },
      );
    }

    final host = ValueListenableBuilder<bool?>(
      valueListenable: _localBindingAvailable,
      builder: (context, available, _) {
        if (available == true) return _JournalHostEnvironment(child: child);
        if (available == false) return onlineAuthenticationGate();
        return const MaterialApp(
          home: Center(child: CircularProgressIndicator()),
        );
      },
    );
    return fs.SlidableAutoCloseBehavior(
      closeWhenOpened: true,
      closeWhenTapped: true,
      child: JournalPlatformMenu(child: host),
    );
  }
}

final class _JournalHostEnvironment extends StatelessWidget {
  const _JournalHostEnvironment({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery.fromView(
    view: View.of(context),
    child: Localizations(
      locale: const Locale('en'),
      delegates: const [
        DefaultWidgetsLocalizations.delegate,
        DefaultMaterialLocalizations.delegate,
      ],
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(data: ThemeData.light(), child: child),
      ),
    ),
  );
}

final class _AuthenticatedJournalHost extends StatelessWidget {
  const _AuthenticatedJournalHost({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _JournalHostEnvironment(
    child: Builder(
      builder: (context) => Authenticator.builder()(context, child),
    ),
  );
}

ApplicationHostAdapter createBonsaiFlutterHostAdapter({
  Uri? baseUrl,
  Future<void>? amplifyReady,
  Widget Function()? authenticationFailureBuilder,
  Future<void> Function()? prepareToTerminate,
}) {
  final environment = _NativeStartupEnvironment();
  return ApplicationHostAdapter(
    applicationSupportDirectory: environment.applicationSupportDirectory,
    baseUrl: baseUrl ?? Uri.parse('https://api.logseq.io'),
    auth: JournalAmplifySession(),
    readPreference: environment.readPreference,
    writePreference: environment.writePreference,
    readLocalAccountBinding: environment.readLocalAccountBinding,
    persistLocalAccountBinding: environment.persistLocalAccountBinding,
    clearLocalAccountBinding: environment.clearLocalAccountBinding,
    amplifyReady: amplifyReady,
    authenticationFailureBuilder: authenticationFailureBuilder,
    prepareToTerminate: prepareToTerminate,
  );
}
