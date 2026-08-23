import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:amplify_authenticator/amplify_authenticator.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:bonsai_flutter/bonsai_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _platformChannel = MethodChannel('logseq_journal/platform');

final class JournalCalendarSnapshot {
  const JournalCalendarSnapshot({
    required this.instantUnixMilliseconds,
    required this.localDay,
    required this.locale,
    required this.timeZoneId,
    required this.utcOffsetSeconds,
    required this.generation,
  });

  final int instantUnixMilliseconds;
  final int localDay;
  final String locale;
  final String timeZoneId;
  final int utcOffsetSeconds;
  final int generation;
}

abstract final class _CalendarFacts {
  static const maximumSignedInt64 = 0x7fffffffffffffff;

  static int localMinuteOfDay(JournalCalendarSnapshot snapshot) {
    if (!_validLocalDay(snapshot.localDay) ||
        snapshot.utcOffsetSeconds.abs() > 64800 ||
        snapshot.generation < 0 ||
        snapshot.generation > maximumSignedInt64 ||
        snapshot.locale.isEmpty ||
        utf8.encode(snapshot.locale).length > 128 ||
        snapshot.timeZoneId.isEmpty ||
        utf8.encode(snapshot.timeZoneId).length > 256) {
      throw const FormatException('calendar facts are invalid');
    }
    final instantSeconds = _floorDiv(snapshot.instantUnixMilliseconds, 1000);
    final localSeconds = instantSeconds + snapshot.utcOffsetSeconds;
    if (_floorDiv(localSeconds, 86400) != _daysFromCivil(snapshot.localDay)) {
      throw const FormatException('calendar local day is inconsistent');
    }
    return _floorDiv(localSeconds, 60) % 1440;
  }

  static int _floorDiv(int dividend, int divisor) {
    final quotient = dividend ~/ divisor;
    return dividend.remainder(divisor) < 0 ? quotient - 1 : quotient;
  }

  static int _daysFromCivil(int value) {
    final year = value ~/ 10000;
    final month = (value ~/ 100) % 100;
    final day = value % 100;
    final adjustedYear = month <= 2 ? year - 1 : year;
    final era = adjustedYear ~/ 400;
    final yearOfEra = adjustedYear - (era * 400);
    final adjustedMonth = month + (month > 2 ? -3 : 9);
    final dayOfYear = (((153 * adjustedMonth) + 2) ~/ 5) + day - 1;
    final dayOfEra =
        (yearOfEra * 365) + (yearOfEra ~/ 4) - (yearOfEra ~/ 100) + dayOfYear;
    return (era * 146097) + dayOfEra - 719468;
  }

  static bool _validLocalDay(int value) {
    final year = value ~/ 10000;
    final month = (value ~/ 100) % 100;
    final day = value % 100;
    if (year < 1 || year > 9999 || month < 1 || month > 12 || day < 1) {
      return false;
    }
    final normalized = DateTime.utc(year, month, day);
    return normalized.year == year &&
        normalized.month == month &&
        normalized.day == day;
  }
}

enum JournalPlatformTag {
  calendarRequest(1),
  calendarResponse(2),
  calendarEvent(3),
  formatDaysRequest(4),
  formatDaysResponse(5),
  authenticatedUserRequest(6),
  authenticatedUserResponse(7),
  idTokenRequest(8),
  idTokenResponse(9),
  signOutRequest(10),
  signOutResponse(11),
  prepareToTerminateEvent(12),
  terminationReadyRequest(13),
  terminationReadyResponse(14),
  networkLifecycleEvent(15);

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

enum CalendarChangeReason {
  requested(0),
  resumed(1),
  significantTimeChanged(2),
  timeZoneChanged(3),
  localeChanged(4);

  const CalendarChangeReason(this.wireId);
  final int wireId;
}

enum NetworkLifecycleKind {
  backgrounded(1),
  foregroundResumed(2);

  const NetworkLifecycleKind(this.wireId);
  final int wireId;
}

typedef CalendarSnapshotProvider = Future<JournalCalendarSnapshot> Function();
typedef JournalDayHeadingFormatter =
    Future<Map<int, String>> Function({
      required JournalCalendarSnapshot snapshot,
      required List<int> days,
    });

abstract final class JournalPlatformCodec {
  static int requestTag(Uint8List request) =>
      JournalPlatformEnvelopeCodec.decode(request).tag.wireId;

  static void validateEmpty(Uint8List request, JournalPlatformTag tag) {
    final envelope = JournalPlatformEnvelopeCodec.decode(request);
    if (envelope.tag != tag || envelope.payload.isNotEmpty) {
      throw const FormatException('invalid empty platform request');
    }
  }

  static Uint8List encodeCalendar(
    JournalCalendarSnapshot snapshot, {
    required CalendarChangeReason reason,
    required bool event,
    required int lifecycleGeneration,
  }) {
    final locale = utf8.encode(snapshot.locale);
    final timeZone = utf8.encode(snapshot.timeZoneId);
    final payload = Uint8List(56 + locale.length + timeZone.length);
    payload.setRange(0, 4, ascii.encode('LJP1'));
    final data = ByteData.sublistView(payload);
    data.setUint16(4, 1, Endian.little);
    data.setUint16(6, event ? 3 : 2, Endian.little);
    data.setUint16(8, reason.wireId, Endian.little);
    data.setUint16(10, locale.length, Endian.little);
    data.setUint16(12, timeZone.length, Endian.little);
    data.setInt64(16, snapshot.instantUnixMilliseconds, Endian.little);
    data.setUint32(24, snapshot.localDay, Endian.little);
    data.setUint16(
      28,
      _CalendarFacts.localMinuteOfDay(snapshot),
      Endian.little,
    );
    data.setInt32(32, snapshot.utcOffsetSeconds, Endian.little);
    data.setInt64(40, snapshot.generation, Endian.little);
    data.setInt64(48, lifecycleGeneration, Endian.little);
    payload.setRange(56, 56 + locale.length, locale);
    payload.setRange(56 + locale.length, payload.length, timeZone);
    return JournalPlatformEnvelopeCodec.encode(
      JournalPlatformEnvelope(
        tag: event
            ? JournalPlatformTag.calendarEvent
            : JournalPlatformTag.calendarResponse,
        payload: payload,
      ),
    );
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

  static ({int generation, List<int> days}) decodeFormatRequest(
    Uint8List request,
  ) {
    final envelope = JournalPlatformEnvelopeCodec.decode(request);
    final payload = envelope.payload;
    if (envelope.tag != JournalPlatformTag.formatDaysRequest ||
        payload.length < 20 ||
        ascii.decode(payload.sublist(0, 4), allowInvalid: true) != 'LJP1') {
      throw const FormatException('invalid formatted-day request');
    }
    final data = ByteData.sublistView(payload);
    final generation = data.getInt64(8, Endian.little);
    final count = data.getUint16(16, Endian.little);
    if (data.getUint16(4, Endian.little) != 1 ||
        data.getUint16(6, Endian.little) != 4 ||
        generation < 0 ||
        count < 1 ||
        count > 64 ||
        data.getUint16(18, Endian.little) != 0 ||
        payload.length != 20 + (count * 4)) {
      throw const FormatException('invalid formatted-day request');
    }
    final days = List<int>.generate(
      count,
      (index) => data.getUint32(20 + (index * 4), Endian.little),
      growable: false,
    );
    return (generation: generation, days: days);
  }

  static Uint8List encodeFormattedDays({
    required int generation,
    required Map<int, String> headings,
  }) {
    final encoded = headings.entries
        .map((entry) => (entry.key, utf8.encode(entry.value)))
        .toList(growable: false);
    if (generation < 0 ||
        encoded.isEmpty ||
        encoded.length > 64 ||
        encoded.any((entry) => entry.$2.isEmpty || entry.$2.length > 512)) {
      throw const FormatException('formatted-day response is invalid');
    }
    final payload = Uint8List(
      encoded.fold(20, (length, entry) => length + 8 + entry.$2.length),
    );
    payload.setRange(0, 4, ascii.encode('LJP1'));
    final data = ByteData.sublistView(payload);
    data.setUint16(4, 1, Endian.little);
    data.setUint16(6, 5, Endian.little);
    data.setInt64(8, generation, Endian.little);
    data.setUint16(16, encoded.length, Endian.little);
    var offset = 20;
    for (final (day, heading) in encoded) {
      data.setUint32(offset, day, Endian.little);
      data.setUint16(offset + 4, heading.length, Endian.little);
      payload.setRange(offset + 8, offset + 8 + heading.length, heading);
      offset += 8 + heading.length;
    }
    return JournalPlatformEnvelopeCodec.encode(
      JournalPlatformEnvelope(
        tag: JournalPlatformTag.formatDaysResponse,
        payload: payload,
      ),
    );
  }

  static ({String challengeId, String purpose}) decodeIdTokenRequest(
    Uint8List request,
  ) {
    final envelope = JournalPlatformEnvelopeCodec.decode(request);
    if (envelope.tag != JournalPlatformTag.idTokenRequest) {
      throw const FormatException('invalid ID-token request');
    }
    final Object? decoded = jsonDecode(
      utf8.decode(envelope.payload, allowMalformed: false),
    );
    if (decoded is! Map<String, dynamic> ||
        decoded.keys.toSet().difference({
          'challengeId',
          'purpose',
        }).isNotEmpty ||
        decoded.length != 2 ||
        decoded['challengeId'] is! String ||
        decoded['purpose'] is! String ||
        !(const {
          'catalogDiscovery',
          'snapshotBootstrap',
          'e2eeKeyAccess',
          'httpPull',
          'transactionSubmission',
          'websocketConnect',
        }).contains(decoded['purpose'])) {
      throw const FormatException('invalid ID-token request');
    }
    return (
      challengeId: decoded['challengeId']! as String,
      purpose: decoded['purpose']! as String,
    );
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
    required this.calendarSnapshot,
    required this.formatJournalDays,
    required this.auth,
    this.prepareToTerminate,
    Future<JournalCalendarSnapshot>? initialSnapshot,
  }) {
    WidgetsBinding.instance.addObserver(this);
    _platformChannel.setMethodCallHandler(_handleNativeSignal);
    _initialization = initialSnapshot == null
        ? Future<void>.value()
        : initialSnapshot.then(_rememberSnapshot);
    _authEvents = Amplify.Hub.listen<AuthUser, AuthHubEvent>(HubChannel.Auth, (
      _,
    ) {
      unawaited(_emitAuthenticatedUser());
    });
  }

  final CalendarSnapshotProvider calendarSnapshot;
  final JournalDayHeadingFormatter formatJournalDays;
  final JournalAuthCapability auth;
  final Future<void> Function()? prepareToTerminate;
  final StreamController<Uint8List> _events =
      StreamController<Uint8List>.broadcast(sync: true);
  final Map<int, JournalCalendarSnapshot> _snapshots = {};
  late final Future<void> _initialization;
  StreamSubscription<AuthHubEvent>? _authEvents;
  Completer<void>? _terminationReady;
  Future<void>? _termination;
  int _lastGeneration = -1;
  int _lifecycleGeneration = 0;
  bool _backgrounded = false;
  bool _disposed = false;

  @override
  Stream<Uint8List> get events => _events.stream;

  void _rememberSnapshot(JournalCalendarSnapshot snapshot) {
    _CalendarFacts.localMinuteOfDay(snapshot);
    _lastGeneration = snapshot.generation;
    _snapshots[snapshot.generation] = snapshot;
  }

  Future<JournalCalendarSnapshot> _freshSnapshot() async {
    await _initialization;
    final snapshot = await calendarSnapshot();
    _CalendarFacts.localMinuteOfDay(snapshot);
    if (snapshot.generation <= _lastGeneration) {
      throw StateError('calendar generation is stale');
    }
    _rememberSnapshot(snapshot);
    _snapshots.removeWhere((key, _) => key < snapshot.generation - 2);
    return snapshot;
  }

  Uint8List _authenticatedUserResponse(String? userId) {
    return JournalPlatformCodec.encodeJson(
      JournalPlatformTag.authenticatedUserResponse,
      <String, Object?>{'userId': userId},
    );
  }

  Future<void> _emitAuthenticatedUser() async {
    if (_disposed) return;
    final response = _authenticatedUserResponse(await auth.currentUserId());
    if (!_disposed) _events.add(response);
  }

  @override
  Future<Uint8List> handleRequest(Uint8List request) async {
    switch (JournalPlatformCodec.requestTag(request)) {
      case 1:
        JournalPlatformCodec.validateEmpty(
          request,
          JournalPlatformTag.calendarRequest,
        );
        return JournalPlatformCodec.encodeCalendar(
          await _freshSnapshot(),
          reason: CalendarChangeReason.requested,
          event: false,
          lifecycleGeneration: _lifecycleGeneration,
        );
      case 4:
        final decoded = JournalPlatformCodec.decodeFormatRequest(request);
        final snapshot = _snapshots[decoded.generation];
        if (snapshot == null) {
          throw StateError('calendar generation is no longer retained');
        }
        final headings = await formatJournalDays(
          snapshot: snapshot,
          days: decoded.days,
        );
        if (headings.keys.toSet().difference(decoded.days.toSet()).isNotEmpty ||
            decoded.days.toSet().difference(headings.keys.toSet()).isNotEmpty) {
          throw StateError('native day formatter returned a mismatched batch');
        }
        return JournalPlatformCodec.encodeFormattedDays(
          generation: decoded.generation,
          headings: headings,
        );
      case 6:
        JournalPlatformCodec.validateEmpty(
          request,
          JournalPlatformTag.authenticatedUserRequest,
        );
        return _authenticatedUserResponse(await auth.currentUserId());
      case 8:
        final decoded = JournalPlatformCodec.decodeIdTokenRequest(request);
        return JournalPlatformCodec.encodeJson(
          JournalPlatformTag.idTokenResponse,
          <String, Object>{
            'challengeId': decoded.challengeId,
            'token': await auth.freshIdToken(),
          },
        );
      case 10:
        JournalPlatformCodec.validateEmpty(
          request,
          JournalPlatformTag.signOutRequest,
        );
        await auth.signOut();
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
      default:
        throw const FormatException('unsupported application platform request');
    }
  }

  Future<void> refresh(CalendarChangeReason reason) async {
    if (_disposed) return;
    final snapshot = await _freshSnapshot();
    if (_disposed) return;
    _events.add(
      JournalPlatformCodec.encodeCalendar(
        snapshot,
        reason: reason,
        event: true,
        lifecycleGeneration: _lifecycleGeneration,
      ),
    );
  }

  Future<void> _handleNativeSignal(MethodCall call) async {
    if (call.method == 'prepareToTerminate') {
      await prepareForTermination();
      return;
    }
    if (call.method != 'calendarChanged') return;
    final reason = call.arguments;
    await refresh(
      reason is int &&
              reason >= 0 &&
              reason < CalendarChangeReason.values.length
          ? CalendarChangeReason.values.firstWhere(
              (value) => value.wireId == reason,
            )
          : CalendarChangeReason.significantTimeChanged,
    );
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
        unawaited(refresh(CalendarChangeReason.resumed));
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    unawaited(refresh(CalendarChangeReason.localeChanged));
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
        return value;
      });

  Future<Directory> applicationSupportDirectory() async {
    final path = (await _load())['applicationSupportPath'];
    if (path is! String || path.isEmpty) {
      throw const FormatException('native Application Support path is invalid');
    }
    return Directory(path);
  }

  Future<JournalCalendarSnapshot> initialCalendarSnapshot() async =>
      _calendarSnapshot(await _load());

  Future<JournalCalendarSnapshot> currentCalendarSnapshot() async {
    final value = await _platformChannel.invokeMapMethod<Object?, Object?>(
      'getStartupEnvironment',
    );
    if (value == null) {
      throw const FormatException('native calendar environment is missing');
    }
    return _calendarSnapshot(value);
  }

  Future<Map<int, String>> formatJournalDays({
    required JournalCalendarSnapshot snapshot,
    required List<int> days,
  }) async {
    final value = await _platformChannel.invokeListMethod<Object?>(
      'formatJournalDays',
      <String, Object>{
        'days': days,
        'locale': snapshot.locale,
        'timeZoneId': snapshot.timeZoneId,
      },
    );
    if (value == null || value.length != days.length) {
      throw const FormatException('native formatted journal days are invalid');
    }
    final headings = <int, String>{};
    for (final item in value) {
      if (item is! Map || item['day'] is! int || item['heading'] is! String) {
        throw const FormatException('native formatted journal day is invalid');
      }
      headings[item['day']! as int] = item['heading']! as String;
    }
    return headings;
  }

  JournalCalendarSnapshot _calendarSnapshot(Map<Object?, Object?> value) {
    int integer(String key) {
      final result = value[key];
      if (result is! int) throw FormatException('native $key is invalid');
      return result;
    }

    String string(String key) {
      final result = value[key];
      if (result is! String || result.isEmpty) {
        throw FormatException('native $key is invalid');
      }
      return result;
    }

    return JournalCalendarSnapshot(
      instantUnixMilliseconds: integer('instantUnixMilliseconds'),
      localDay: integer('localDay'),
      locale: string('locale'),
      timeZoneId: string('timeZoneId'),
      utcOffsetSeconds: integer('utcOffsetSeconds'),
      generation: integer('generation'),
    );
  }
}

typedef ApplicationSupportDirectoryProvider = Future<Directory> Function();

final class ApplicationHostAdapter implements BonsaiFlutterHostAdapter {
  ApplicationHostAdapter({
    required this.applicationSupportDirectory,
    required this.baseUrl,
    required this.initialCalendarSnapshot,
    required this.liveCalendarSnapshot,
    required this.formatJournalDays,
    required this.auth,
    this.amplifyReady,
    this.prepareToTerminate,
  });

  final ApplicationSupportDirectoryProvider applicationSupportDirectory;
  final Uri baseUrl;
  final CalendarSnapshotProvider initialCalendarSnapshot;
  final CalendarSnapshotProvider liveCalendarSnapshot;
  final JournalDayHeadingFormatter formatJournalDays;
  final JournalAuthCapability auth;
  final Future<void>? amplifyReady;
  final Future<void> Function()? prepareToTerminate;
  late final Future<JournalCalendarSnapshot> _initialSnapshot =
      initialCalendarSnapshot();

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
        calendarSnapshot: liveCalendarSnapshot,
        formatJournalDays: formatJournalDays,
        auth: auth,
        prepareToTerminate: prepareToTerminate,
        initialSnapshot: _initialSnapshot,
      );

  @override
  Widget buildHost({required BuildContext context, required Widget child}) {
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
    final ready = amplifyReady;
    if (ready == null) return authenticatedHost();
    return FutureBuilder<void>(
      future: ready,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done &&
            snapshot.error == null) {
          return authenticatedHost();
        }
        return const MaterialApp(
          home: Center(child: CircularProgressIndicator()),
        );
      },
    );
  }
}

final class _AuthenticatedJournalHost extends StatelessWidget {
  const _AuthenticatedJournalHost({required this.child});

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
        child: Theme(
          data: ThemeData.light(),
          child: Builder(
            builder: (context) => Authenticator.builder()(context, child),
          ),
        ),
      ),
    ),
  );
}

ApplicationHostAdapter createBonsaiFlutterHostAdapter({
  Uri? baseUrl,
  Future<void> Function()? prepareToTerminate,
}) {
  final environment = _NativeStartupEnvironment();
  return ApplicationHostAdapter(
    applicationSupportDirectory: environment.applicationSupportDirectory,
    baseUrl: baseUrl ?? Uri.parse('https://api.logseq.io'),
    initialCalendarSnapshot: environment.initialCalendarSnapshot,
    liveCalendarSnapshot: environment.currentCalendarSnapshot,
    formatJournalDays: environment.formatJournalDays,
    auth: JournalAmplifySession(),
    prepareToTerminate: prepareToTerminate,
  );
}
