import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lui_flutter_backend/lui_flutter_backend.dart';

/// Shared helpers for the journal LUI extension renderers. Every journal
/// extension carries one required string property `payload` (JSON, the same
/// shape the old `~encode_props` produced) and emits `event` events with
/// `id:int` + `payload:string` fields (the old `BonsaiNativeEvent` contract).

Map<String, Object?> decodeJournalPayload(LUIFlutterExtensionContext context) {
  final raw = context.property('payload');
  if (raw is! String) {
    throw const FormatException('journal extension payload is not a string');
  }
  final value = jsonDecode(raw);
  if (value is! Map<String, Object?>) {
    throw const FormatException('journal extension payload must be an object');
  }
  return value;
}

/// Emits `event` with the legacy `BonsaiNativeEvent(id, payload)` shape.
/// `payload` may be a pre-encoded string or a JSON-serializable value.
void emitJournalEvent(
  LUIFlutterExtensionContext context,
  int id,
  Object payload,
) {
  context.emit(
    name: 'event',
    values: <String, Object>{
      'id': id,
      'payload': payload is String ? payload : jsonEncode(payload),
    },
  );
}

final Random _uuidRandom = Random.secure();

String newJournalUuid() {
  final bytes = List<int>.generate(16, (_) => _uuidRandom.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Closest Material glyph for the SF Symbol names the journal payloads use.
/// Approximation: Flutter has no SF Symbols, so names map onto Material icons.
IconData journalSymbolIcon(String? name) => switch (name) {
  'checkmark.circle' => Icons.check_circle_outline,
  'trash' => Icons.delete_outline,
  'paperclip' => Icons.attach_file,
  'doc' => Icons.insert_drive_file_outlined,
  'photo' => Icons.image_outlined,
  'arrow.up.right.square' => Icons.open_in_new,
  'ellipsis.circle' => Icons.more_horiz,
  'book' => Icons.menu_book_outlined,
  'magnifyingglass' => Icons.search,
  'plus' => Icons.add,
  'xmark' => Icons.close,
  'chevron.right' => Icons.chevron_right,
  'chevron.down' => Icons.expand_more,
  'gearshape' => Icons.settings_outlined,
  'person.crop.circle' => Icons.account_circle_outlined,
  'bell' => Icons.notifications_none,
  'star' => Icons.star_outline,
  'star.fill' => Icons.star,
  _ => Icons.circle_outlined,
};

/// `#rrggbb` / `#aarrggbb` / `rgb(r,g,b)` -> Color. Null-safe no-op on miss.
Color? journalColor(Object? value) {
  if (value is! String || value.isEmpty) return null;
  final hex = value.startsWith('#') ? value.substring(1) : value;
  if (hex.length == 6) {
    final v = int.tryParse(hex, radix: 16);
    return v == null ? null : Color(0xff000000 | v);
  }
  if (hex.length == 8) {
    final v = int.tryParse(hex, radix: 16);
    return v == null ? null : Color(v);
  }
  return null;
}

/// Accessibility hook used in place of `.accessibilityIdentifier`: keeps the
/// legacy identifier text on the semantics label so QA tooling can find it.
Widget journalTestId(String? testId, Widget child) {
  if (testId == null || testId.isEmpty) return child;
  return Semantics(container: true, label: testId, child: child);
}
