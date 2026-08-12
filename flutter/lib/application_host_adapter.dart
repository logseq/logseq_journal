import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bonsai_flutter/bonsai_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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

  JournalCalendarSnapshot copyWith({
    int? instantUnixMilliseconds,
    int? localDay,
    String? locale,
    String? timeZoneId,
    int? utcOffsetSeconds,
    int? generation,
  }) => JournalCalendarSnapshot(
    instantUnixMilliseconds:
        instantUnixMilliseconds ?? this.instantUnixMilliseconds,
    localDay: localDay ?? this.localDay,
    locale: locale ?? this.locale,
    timeZoneId: timeZoneId ?? this.timeZoneId,
    utcOffsetSeconds: utcOffsetSeconds ?? this.utcOffsetSeconds,
    generation: generation ?? this.generation,
  );

  @override
  bool operator ==(Object other) =>
      other is JournalCalendarSnapshot &&
      other.instantUnixMilliseconds == instantUnixMilliseconds &&
      other.localDay == localDay &&
      other.locale == locale &&
      other.timeZoneId == timeZoneId &&
      other.utcOffsetSeconds == utcOffsetSeconds &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(
    instantUnixMilliseconds,
    localDay,
    locale,
    timeZoneId,
    utcOffsetSeconds,
    generation,
  );
}

abstract final class _CalendarFacts {
  static const maximumLocaleBytes = 128;
  static const maximumTimeZoneBytes = 256;
  static const maximumUtcOffsetSeconds = 64800;
  static const maximumSignedInt64 = 0x7fffffffffffffff;
  static const minimumSignedInt64 = -0x8000000000000000;

  static int localMinuteOfDay(
    JournalCalendarSnapshot snapshot, {
    required Never Function(String) invalid,
  }) {
    if (!validLocalDay(snapshot.localDay)) {
      invalid('calendar local day is invalid');
    }
    if (snapshot.utcOffsetSeconds < -maximumUtcOffsetSeconds ||
        snapshot.utcOffsetSeconds > maximumUtcOffsetSeconds) {
      invalid('calendar UTC offset is out of range');
    }
    if (snapshot.generation < 0 || snapshot.generation > maximumSignedInt64) {
      invalid('calendar generation must be a nonnegative signed 64-bit value');
    }
    if (snapshot.instantUnixMilliseconds < minimumSignedInt64 ||
        snapshot.instantUnixMilliseconds > maximumSignedInt64) {
      invalid('calendar instant must fit a signed 64-bit value');
    }
    validateString(
      snapshot.locale,
      'calendar locale',
      maximumLocaleBytes,
      invalid,
    );
    validateString(
      snapshot.timeZoneId,
      'calendar time-zone ID',
      maximumTimeZoneBytes,
      invalid,
    );

    final instantSeconds = floorDiv(snapshot.instantUnixMilliseconds, 1000);
    final localSeconds = instantSeconds + snapshot.utcOffsetSeconds;
    final actualDay = floorDiv(localSeconds, 86400);
    final expectedDay = daysFromCivil(snapshot.localDay);
    if (actualDay != expectedDay) {
      invalid('calendar local day does not match instant and offset');
    }
    return floorDiv(localSeconds, 60) % 1440;
  }

  static void validateString(
    String value,
    String name,
    int maximumBytes,
    Never Function(String) invalid,
  ) {
    if (value.isEmpty) invalid('$name must not be empty');
    if (value.contains('\u0000')) invalid('$name must not contain NUL');
    if (utf8.encode(value).length > maximumBytes) {
      invalid('$name exceeds $maximumBytes UTF-8 bytes');
    }
  }

  static int floorDiv(int dividend, int divisor) {
    final quotient = dividend ~/ divisor;
    final remainder = dividend.remainder(divisor);
    return remainder < 0 ? quotient - 1 : quotient;
  }

  static int daysFromCivil(int value) {
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

  static bool validLocalDay(int value) {
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

final class JournalStartupEnvelope {
  const JournalStartupEnvelope({
    required this.applicationSupportRoot,
    required this.initialCalendar,
    this.lifecycleGeneration = 0,
  });

  static const _magic = 'LJR1';
  static const _envelopeVersion = 1;
  static const _headerSize = 64;
  static const _maximumPayloadBytes = 1024 * 1024;
  static const _maximumRootBytes = 4096;

  final String applicationSupportRoot;
  final JournalCalendarSnapshot initialCalendar;
  final int lifecycleGeneration;

  Uint8List encode() {
    _validate(argumentError: true);
    final root = utf8.encode(applicationSupportRoot);
    final locale = utf8.encode(initialCalendar.locale);
    final timeZone = utf8.encode(initialCalendar.timeZoneId);
    final size = _headerSize + root.length + locale.length + timeZone.length;
    if (size > _maximumPayloadBytes) {
      throw ArgumentError.value(size, 'startup payload', 'exceeds 1 MiB');
    }

    final bytes = Uint8List(size);
    final data = ByteData.sublistView(bytes);
    bytes.setRange(0, 4, ascii.encode(_magic));
    data.setUint32(4, _envelopeVersion, Endian.little);
    data.setUint32(8, root.length, Endian.little);
    data.setUint32(12, locale.length, Endian.little);
    data.setUint32(16, timeZone.length, Endian.little);
    data.setInt64(24, initialCalendar.instantUnixMilliseconds, Endian.little);
    data.setUint32(32, initialCalendar.localDay, Endian.little);
    data.setUint16(
      36,
      _CalendarFacts.localMinuteOfDay(
        initialCalendar,
        invalid: (message) => throw ArgumentError(message),
      ),
      Endian.little,
    );
    data.setInt32(40, initialCalendar.utcOffsetSeconds, Endian.little);
    data.setInt64(48, initialCalendar.generation, Endian.little);
    data.setInt64(56, lifecycleGeneration, Endian.little);
    var offset = _headerSize;
    for (final field in [root, locale, timeZone]) {
      bytes.setRange(offset, offset + field.length, field);
      offset += field.length;
    }
    return bytes;
  }

  static JournalStartupEnvelope decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const FormatException('startup payload is empty');
    }
    if (bytes.length > _maximumPayloadBytes) {
      throw const FormatException('startup payload exceeds 1 MiB');
    }
    if (bytes.length < _headerSize) {
      throw const FormatException('startup payload is truncated');
    }
    final data = ByteData.sublistView(bytes);
    if (ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != _magic) {
      throw const FormatException('invalid startup magic');
    }
    if (data.getUint32(4, Endian.little) != _envelopeVersion) {
      throw const FormatException('unsupported startup envelope version');
    }
    if (data.getUint32(20, Endian.little) != 0 ||
        data.getUint16(38, Endian.little) != 0 ||
        data.getUint32(44, Endian.little) != 0) {
      throw const FormatException('startup reserved bytes must be zero');
    }
    final rootLength = data.getUint32(8, Endian.little);
    final localeLength = data.getUint32(12, Endian.little);
    final timeZoneLength = data.getUint32(16, Endian.little);
    if (_headerSize + rootLength + localeLength + timeZoneLength !=
        bytes.length) {
      throw const FormatException(
        'startup payload has trailing or missing bytes',
      );
    }

    var offset = _headerSize;
    String take(int length, String name) {
      final field = bytes.sublist(offset, offset + length);
      offset += length;
      try {
        return utf8.decode(field, allowMalformed: false);
      } on FormatException {
        throw FormatException('$name must be valid UTF-8');
      }
    }

    final root = take(rootLength, 'Application Support root');
    final locale = take(localeLength, 'calendar locale');
    final timeZone = take(timeZoneLength, 'calendar time-zone ID');
    final envelope = JournalStartupEnvelope(
      applicationSupportRoot: root,
      initialCalendar: JournalCalendarSnapshot(
        instantUnixMilliseconds: data.getInt64(24, Endian.little),
        localDay: data.getUint32(32, Endian.little),
        locale: locale,
        timeZoneId: timeZone,
        utcOffsetSeconds: data.getInt32(40, Endian.little),
        generation: data.getInt64(48, Endian.little),
      ),
      lifecycleGeneration: data.getInt64(56, Endian.little),
    );
    envelope._validate(argumentError: false);
    final encodedMinute = data.getUint16(36, Endian.little);
    final actualMinute = _CalendarFacts.localMinuteOfDay(
      envelope.initialCalendar,
      invalid: (message) => throw FormatException(message),
    );
    if (encodedMinute != actualMinute) {
      throw const FormatException('calendar local minute is inconsistent');
    }
    return envelope;
  }

  void _validate({required bool argumentError}) {
    Never invalid(String message) {
      if (argumentError) throw ArgumentError(message);
      throw FormatException(message);
    }

    final rootBytes = utf8.encode(applicationSupportRoot).length;
    final rootComponents = applicationSupportRoot.split('/');
    if (!applicationSupportRoot.startsWith('/')) {
      invalid('Application Support root must be absolute');
    }
    if (applicationSupportRoot == '/' ||
        rootComponents.first.isNotEmpty ||
        rootComponents
            .skip(1)
            .any(
              (component) =>
                  component.isEmpty || component == '.' || component == '..',
            )) {
      invalid('Application Support root must be a canonical absolute path');
    }
    if (applicationSupportRoot.contains('\\')) {
      invalid('Application Support root must use platform separators');
    }
    if (applicationSupportRoot.contains('\u0000')) {
      invalid('Application Support root must not contain NUL');
    }
    if (rootBytes > _maximumRootBytes) {
      invalid(
        'Application Support root exceeds $_maximumRootBytes UTF-8 bytes',
      );
    }
    if (lifecycleGeneration < 0 ||
        lifecycleGeneration > _CalendarFacts.maximumSignedInt64) {
      invalid('lifecycle generation must be a nonnegative signed 64-bit value');
    }
    _CalendarFacts.localMinuteOfDay(initialCalendar, invalid: invalid);
  }

  @override
  bool operator ==(Object other) =>
      other is JournalStartupEnvelope &&
      other.applicationSupportRoot == applicationSupportRoot &&
      other.initialCalendar == initialCalendar &&
      other.lifecycleGeneration == lifecycleGeneration;

  @override
  int get hashCode =>
      Object.hash(applicationSupportRoot, initialCalendar, lifecycleGeneration);
}

typedef ApplicationSupportDirectoryProvider = Future<Directory> Function();
typedef InitialCalendarSnapshotProvider =
    Future<JournalCalendarSnapshot> Function();
typedef JournalDayHeadingFormatter =
    Future<Map<int, String>> Function({
      required JournalCalendarSnapshot snapshot,
      required List<int> days,
    });

enum CalendarChangeReason {
  requested(0),
  resumed(1),
  significantTimeChanged(2),
  timeZoneChanged(3),
  localeChanged(4);

  const CalendarChangeReason(this.wireId);

  final int wireId;

  static CalendarChangeReason fromWireId(int value) => values.firstWhere(
    (reason) => reason.wireId == value,
    orElse: () =>
        throw FormatException('unknown calendar change reason $value'),
  );
}

final class JournalPlatformCalendar {
  const JournalPlatformCalendar({
    required this.snapshot,
    required this.reason,
    required this.lifecycleGeneration,
  });

  final JournalCalendarSnapshot snapshot;
  final CalendarChangeReason reason;
  final int lifecycleGeneration;

  int get generation => snapshot.generation;
}

final class JournalPlatformFormatRequest {
  const JournalPlatformFormatRequest({
    required this.generation,
    required this.days,
  });

  final int generation;
  final List<int> days;
}

final class JournalPlatformFormattedDays {
  const JournalPlatformFormattedDays({
    required this.generation,
    required this.headings,
  });

  final int generation;
  final Map<int, String> headings;
}

abstract final class JournalPlatformCodec {
  static const _magic = <int>[0x4c, 0x4a, 0x50, 0x31];
  static const _version = 1;
  static const _requestTag = 1;
  static const _responseTag = 2;
  static const _eventTag = 3;
  static const _formatRequestTag = 4;
  static const _formatResponseTag = 5;
  static const _calendarHeaderBytes = 56;
  static const _formatHeaderBytes = 20;
  static const _maximumDayCount = 64;
  static const _maximumHeadingBytes = 512;

  static final Uint8List getCalendarRequest = _request(_requestTag);

  static Uint8List _request(int tag) {
    final value = Uint8List(8);
    value.setRange(0, 4, _magic);
    final data = ByteData.sublistView(value);
    data.setUint16(4, _version, Endian.little);
    data.setUint16(6, tag, Endian.little);
    return value;
  }

  static void validateGetCalendarRequest(Uint8List value) {
    if (value.length != 8 || !_hasMagic(value)) {
      throw const FormatException('invalid journal platform request');
    }
    final data = ByteData.sublistView(value);
    if (data.getUint16(4, Endian.little) != _version ||
        data.getUint16(6, Endian.little) != _requestTag) {
      throw const FormatException('unsupported journal platform request');
    }
  }

  static int requestTag(Uint8List value) {
    if (value.length < 8 || !_hasMagic(value)) {
      throw const FormatException('invalid journal platform request');
    }
    final data = ByteData.sublistView(value);
    if (data.getUint16(4, Endian.little) != _version) {
      throw const FormatException('unsupported journal platform request');
    }
    return data.getUint16(6, Endian.little);
  }

  static Uint8List formatJournalDaysRequest({
    required int generation,
    required List<int> days,
  }) {
    if (generation < 0 || days.isEmpty || days.length > _maximumDayCount) {
      throw ArgumentError('formatted day request is outside its bound');
    }
    if (days.toSet().length != days.length ||
        days.any((day) => !_CalendarFacts.validLocalDay(day))) {
      throw ArgumentError('formatted day request contains invalid days');
    }
    final value = Uint8List(_formatHeaderBytes + (days.length * 4));
    value.setRange(0, 4, _magic);
    final data = ByteData.sublistView(value);
    data.setUint16(4, _version, Endian.little);
    data.setUint16(6, _formatRequestTag, Endian.little);
    data.setInt64(8, generation, Endian.little);
    data.setUint16(16, days.length, Endian.little);
    for (var index = 0; index < days.length; index += 1) {
      data.setUint32(
        _formatHeaderBytes + (index * 4),
        days[index],
        Endian.little,
      );
    }
    return value;
  }

  static JournalPlatformFormatRequest decodeFormatJournalDaysRequest(
    Uint8List value,
  ) {
    if (value.length < _formatHeaderBytes ||
        requestTag(value) != _formatRequestTag) {
      throw const FormatException('invalid formatted day request');
    }
    final data = ByteData.sublistView(value);
    final generation = data.getInt64(8, Endian.little);
    final count = data.getUint16(16, Endian.little);
    if (generation < 0 ||
        count < 1 ||
        count > _maximumDayCount ||
        data.getUint16(18, Endian.little) != 0 ||
        value.length != _formatHeaderBytes + (count * 4)) {
      throw const FormatException('invalid formatted day request');
    }
    final days = List<int>.generate(
      count,
      (index) =>
          data.getUint32(_formatHeaderBytes + (index * 4), Endian.little),
      growable: false,
    );
    if (days.toSet().length != days.length ||
        days.any((day) => !_CalendarFacts.validLocalDay(day))) {
      throw const FormatException('invalid formatted day request');
    }
    return JournalPlatformFormatRequest(generation: generation, days: days);
  }

  static Uint8List encodeFormattedJournalDays({
    required int generation,
    required Map<int, String> headings,
  }) {
    if (generation < 0 ||
        headings.isEmpty ||
        headings.length > _maximumDayCount) {
      throw ArgumentError('formatted day response is outside its bound');
    }
    final encoded = <(int, List<int>)>[];
    for (final MapEntry(key: day, value: heading) in headings.entries) {
      final bytes = utf8.encode(heading);
      if (!_CalendarFacts.validLocalDay(day) ||
          bytes.isEmpty ||
          bytes.length > _maximumHeadingBytes) {
        throw ArgumentError('formatted day response contains invalid headings');
      }
      encoded.add((day, bytes));
    }
    final length = encoded.fold<int>(
      _formatHeaderBytes,
      (total, entry) => total + 8 + entry.$2.length,
    );
    final value = Uint8List(length);
    value.setRange(0, 4, _magic);
    final data = ByteData.sublistView(value);
    data.setUint16(4, _version, Endian.little);
    data.setUint16(6, _formatResponseTag, Endian.little);
    data.setInt64(8, generation, Endian.little);
    data.setUint16(16, encoded.length, Endian.little);
    var offset = _formatHeaderBytes;
    for (final (day, bytes) in encoded) {
      data.setUint32(offset, day, Endian.little);
      data.setUint16(offset + 4, bytes.length, Endian.little);
      value.setRange(offset + 8, offset + 8 + bytes.length, bytes);
      offset += 8 + bytes.length;
    }
    return value;
  }

  static JournalPlatformFormattedDays decodeFormattedJournalDays(
    Uint8List value,
  ) {
    if (value.length < _formatHeaderBytes || !_hasMagic(value)) {
      throw const FormatException('invalid formatted day response');
    }
    final data = ByteData.sublistView(value);
    final generation = data.getInt64(8, Endian.little);
    final count = data.getUint16(16, Endian.little);
    if (data.getUint16(4, Endian.little) != _version ||
        data.getUint16(6, Endian.little) != _formatResponseTag ||
        generation < 0 ||
        count < 1 ||
        count > _maximumDayCount ||
        data.getUint16(18, Endian.little) != 0) {
      throw const FormatException('invalid formatted day response');
    }
    var offset = _formatHeaderBytes;
    final headings = <int, String>{};
    for (var index = 0; index < count; index += 1) {
      if (offset + 8 > value.length) {
        throw const FormatException('truncated formatted day response');
      }
      final day = data.getUint32(offset, Endian.little);
      final length = data.getUint16(offset + 4, Endian.little);
      if (!_CalendarFacts.validLocalDay(day) ||
          headings.containsKey(day) ||
          length < 1 ||
          length > _maximumHeadingBytes ||
          data.getUint16(offset + 6, Endian.little) != 0 ||
          offset + 8 + length > value.length) {
        throw const FormatException('invalid formatted day response');
      }
      try {
        headings[day] = utf8.decode(
          value.sublist(offset + 8, offset + 8 + length),
          allowMalformed: false,
        );
      } on FormatException {
        throw const FormatException('invalid formatted day response');
      }
      offset += 8 + length;
    }
    if (offset != value.length) {
      throw const FormatException('formatted day response has trailing bytes');
    }
    return JournalPlatformFormattedDays(
      generation: generation,
      headings: Map.unmodifiable(headings),
    );
  }

  static Uint8List encodeCalendar(
    JournalCalendarSnapshot snapshot, {
    required CalendarChangeReason reason,
    required bool event,
    int lifecycleGeneration = 0,
  }) {
    Never invalid(String message) => throw ArgumentError(message);
    final localMinute = _CalendarFacts.localMinuteOfDay(
      snapshot,
      invalid: invalid,
    );
    if (lifecycleGeneration < 0 ||
        lifecycleGeneration > _CalendarFacts.maximumSignedInt64) {
      invalid('lifecycle generation is invalid');
    }
    final locale = utf8.encode(snapshot.locale);
    final timeZone = utf8.encode(snapshot.timeZoneId);
    final value = Uint8List(
      _calendarHeaderBytes + locale.length + timeZone.length,
    );
    value.setRange(0, 4, _magic);
    final data = ByteData.sublistView(value);
    data.setUint16(4, _version, Endian.little);
    data.setUint16(6, event ? _eventTag : _responseTag, Endian.little);
    data.setUint16(8, reason.wireId, Endian.little);
    data.setUint16(10, locale.length, Endian.little);
    data.setUint16(12, timeZone.length, Endian.little);
    data.setInt64(16, snapshot.instantUnixMilliseconds, Endian.little);
    data.setUint32(24, snapshot.localDay, Endian.little);
    data.setUint16(28, localMinute, Endian.little);
    data.setInt32(32, snapshot.utcOffsetSeconds, Endian.little);
    data.setInt64(40, snapshot.generation, Endian.little);
    data.setInt64(48, lifecycleGeneration, Endian.little);
    value.setRange(
      _calendarHeaderBytes,
      _calendarHeaderBytes + locale.length,
      locale,
    );
    value.setRange(
      _calendarHeaderBytes + locale.length,
      value.length,
      timeZone,
    );
    return value;
  }

  static JournalPlatformCalendar decodeCalendar(Uint8List value) {
    if (value.length < _calendarHeaderBytes || !_hasMagic(value)) {
      throw const FormatException('invalid journal platform calendar');
    }
    final data = ByteData.sublistView(value);
    final tag = data.getUint16(6, Endian.little);
    final localeLength = data.getUint16(10, Endian.little);
    final timeZoneLength = data.getUint16(12, Endian.little);
    if (data.getUint16(4, Endian.little) != _version ||
        (tag != _responseTag && tag != _eventTag) ||
        data.getUint16(14, Endian.little) != 0 ||
        data.getUint16(30, Endian.little) != 0 ||
        data.getUint32(36, Endian.little) != 0 ||
        value.length != _calendarHeaderBytes + localeLength + timeZoneLength) {
      throw const FormatException('unsupported journal platform calendar');
    }
    final localeEnd = _calendarHeaderBytes + localeLength;
    final snapshot = JournalCalendarSnapshot(
      instantUnixMilliseconds: data.getInt64(16, Endian.little),
      localDay: data.getUint32(24, Endian.little),
      locale: utf8.decode(value.sublist(_calendarHeaderBytes, localeEnd)),
      timeZoneId: utf8.decode(value.sublist(localeEnd)),
      utcOffsetSeconds: data.getInt32(32, Endian.little),
      generation: data.getInt64(40, Endian.little),
    );
    final localMinute = _CalendarFacts.localMinuteOfDay(
      snapshot,
      invalid: (message) => throw FormatException(message),
    );
    if (data.getUint16(28, Endian.little) != localMinute) {
      throw const FormatException('calendar local minute is inconsistent');
    }
    final lifecycleGeneration = data.getInt64(48, Endian.little);
    if (lifecycleGeneration < 0) {
      throw const FormatException('calendar lifecycle generation is invalid');
    }
    return JournalPlatformCalendar(
      snapshot: snapshot,
      reason: CalendarChangeReason.fromWireId(data.getUint16(8, Endian.little)),
      lifecycleGeneration: lifecycleGeneration,
    );
  }

  static bool _hasMagic(Uint8List value) =>
      value.length >= 4 &&
      List.generate(4, (index) => value[index]).toString() == _magic.toString();
}

final class JournalApplicationPlatform extends WidgetsBindingObserver
    implements BonsaiFlutterApplicationPlatform {
  JournalApplicationPlatform({
    required this.calendarSnapshot,
    required this.formatJournalDays,
    Future<JournalCalendarSnapshot>? initialSnapshot,
  }) {
    WidgetsBinding.instance.addObserver(this);
    _platformChannel.setMethodCallHandler(_handleNativeSignal);
    _initialization = initialSnapshot == null
        ? Future<void>.value()
        : initialSnapshot.then(_rememberInitialSnapshot);
  }

  final InitialCalendarSnapshotProvider calendarSnapshot;
  final JournalDayHeadingFormatter formatJournalDays;
  final StreamController<Uint8List> _events =
      StreamController<Uint8List>.broadcast(sync: true);
  final Map<int, JournalCalendarSnapshot> _snapshots = {};
  late final Future<void> _initialization;
  int _lastGeneration = -1;
  int _lifecycleGeneration = 0;
  bool _disposed = false;

  @override
  Stream<Uint8List> get events => _events.stream;

  void _rememberInitialSnapshot(JournalCalendarSnapshot snapshot) {
    _CalendarFacts.localMinuteOfDay(
      snapshot,
      invalid: (message) => throw FormatException(message),
    );
    _lastGeneration = snapshot.generation;
    _snapshots[snapshot.generation] = snapshot;
  }

  Future<JournalCalendarSnapshot> _freshSnapshot() async {
    await _initialization;
    final snapshot = await calendarSnapshot();
    _CalendarFacts.localMinuteOfDay(
      snapshot,
      invalid: (message) => throw FormatException(message),
    );
    if (snapshot.generation <= _lastGeneration) {
      throw StateError('calendar generation is stale');
    }
    _lastGeneration = snapshot.generation;
    _snapshots[snapshot.generation] = snapshot;
    _snapshots.removeWhere((key, _) => key < snapshot.generation - 2);
    return snapshot;
  }

  @override
  Future<Uint8List> handleRequest(Uint8List request) async {
    switch (JournalPlatformCodec.requestTag(request)) {
      case 1:
        JournalPlatformCodec.validateGetCalendarRequest(request);
        return JournalPlatformCodec.encodeCalendar(
          await _freshSnapshot(),
          reason: CalendarChangeReason.requested,
          event: false,
          lifecycleGeneration: _lifecycleGeneration,
        );
      case 4:
        final decoded = JournalPlatformCodec.decodeFormatJournalDaysRequest(
          request,
        );
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
        return JournalPlatformCodec.encodeFormattedJournalDays(
          generation: decoded.generation,
          headings: headings,
        );
      default:
        throw const FormatException('unsupported journal platform request');
    }
  }

  Future<void> refresh(CalendarChangeReason reason) async {
    if (_disposed) return;
    final snapshot = await _freshSnapshot();
    if (_disposed) return;
    if (reason == CalendarChangeReason.resumed) {
      _lifecycleGeneration += 1;
    }
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
    if (call.method != 'calendarChanged') return;
    final wireReason = call.arguments;
    await refresh(
      wireReason is int
          ? CalendarChangeReason.fromWireId(wireReason)
          : CalendarChangeReason.significantTimeChanged,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refresh(CalendarChangeReason.resumed));
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
    unawaited(_events.close());
  }
}

const _platformChannel = MethodChannel('logseq_journal/platform');

BonsaiFlutterHostAdapter createBonsaiFlutterHostAdapter() {
  final environment = _NativeStartupEnvironment();
  return ApplicationHostAdapter(
    applicationSupportDirectory: environment.applicationSupportDirectory,
    initialCalendarSnapshot: environment.initialCalendarSnapshot,
    liveCalendarSnapshot: environment.currentCalendarSnapshot,
  );
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
    final value = (await _load())['applicationSupportPath'];
    if (value is! String || value.isEmpty) {
      throw const FormatException('native Application Support path is invalid');
    }
    return Directory(value);
  }

  Future<JournalCalendarSnapshot> initialCalendarSnapshot() async {
    return _calendarSnapshot(await _load());
  }

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
      if (item is! Map) {
        throw const FormatException('native formatted journal day is invalid');
      }
      final day = item['day'];
      final heading = item['heading'];
      if (day is! int || heading is! String || heading.isEmpty) {
        throw const FormatException('native formatted journal day is invalid');
      }
      headings[day] = heading;
    }
    return headings;
  }

  JournalCalendarSnapshot _calendarSnapshot(Map<Object?, Object?> value) {
    int integer(String name) {
      final field = value[name];
      if (field is! int) throw FormatException('native $name is invalid');
      return field;
    }

    String string(String name) {
      final field = value[name];
      if (field is! String || field.isEmpty) {
        throw FormatException('native $name is invalid');
      }
      return field;
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

final class ApplicationHostAdapter implements BonsaiFlutterHostAdapter {
  ApplicationHostAdapter({
    required this.applicationSupportDirectory,
    required this.initialCalendarSnapshot,
    InitialCalendarSnapshotProvider? liveCalendarSnapshot,
  }) : liveCalendarSnapshot = liveCalendarSnapshot ?? initialCalendarSnapshot;

  final ApplicationSupportDirectoryProvider applicationSupportDirectory;
  final InitialCalendarSnapshotProvider initialCalendarSnapshot;
  final InitialCalendarSnapshotProvider liveCalendarSnapshot;
  late final Future<JournalCalendarSnapshot> _initialSnapshot =
      initialCalendarSnapshot();

  @override
  BonsaiFlutterApplicationPlatform createApplicationPlatform() =>
      JournalApplicationPlatform(
        calendarSnapshot: liveCalendarSnapshot,
        formatJournalDays: _NativeStartupEnvironment().formatJournalDays,
        initialSnapshot: _initialSnapshot,
      );

  @override
  Future<Uint8List> createApplicationPayload() async {
    final supportDirectory = await applicationSupportDirectory();
    if (!await supportDirectory.exists()) {
      await supportDirectory.create(recursive: true);
    }
    final canonicalRoot = await supportDirectory.resolveSymbolicLinks();
    return JournalStartupEnvelope(
      applicationSupportRoot: canonicalRoot,
      initialCalendar: await _initialSnapshot,
    ).encode();
  }

  @override
  Widget buildHost({required BuildContext context, required Widget child}) =>
      child;
}
