import 'package:flutter/material.dart';
import 'package:lui_flutter_backend/lui_flutter_backend.dart';

import 'journal_asset_import.dart';
import 'journal_asset_settings.dart';
import 'journal_chrome.dart';
import 'journal_list.dart';
import 'journal_media.dart';

const _payloadProperty = LUIExtensionProperty(
  name: 'payload',
  kind: LUIExtensionValueKind.string,
  isRequired: true,
);

const _journalEvent = LUIExtensionEventSchema(
  name: 'event',
  fields: [
    LUIExtensionEventField(
      name: 'id',
      kind: LUIExtensionValueKind.integer,
      isRequired: true,
    ),
    LUIExtensionEventField(
      name: 'payload',
      kind: LUIExtensionValueKind.string,
      isRequired: true,
    ),
  ],
);

/// Journal extension registry for the LUI Flutter backend. Fingerprints are
/// the `Lui_extension.fingerprint` digests of the OCaml registry in
/// `app/journal_lui_native.ml` — keep them in lockstep; a mismatch rejects the
/// extension batch.
/// [renderChild] renders an extension child node id — pass a closure over the
/// backend (`(id) => backend.widget(node: id)`), which can only be created
/// after this registry since the backend freezes it.
LUIFlutterExtensionRegistry journalExtensionRegistry(
  Widget Function(int nodeID) renderChild,
) {
  final registry = LUIFlutterExtensionRegistry();
  registry.register(
    LUIFlutterExtension(
      identifier: 'journal-chrome',
      fingerprint:
          'lui-extension-v1|14:journal-chrome|profiles:ios/swiftui,macos/swiftui'
          '|standard-children:1|children:20:journal-asset-import,'
          '22:journal-asset-settings,14:journal-chrome,12:journal-list,'
          '13:journal-media|properties:'
          '7:payload:string:required:none|events:',
      acceptsStandardChildren: true,
      properties: const [_payloadProperty],
      builder: (context) => buildJournalChrome(context, renderChild),
    ),
  );
  registry.register(
    LUIFlutterExtension(
      identifier: 'journal-asset-import',
      fingerprint:
          'lui-extension-v1|20:journal-asset-import|profiles:'
          'android/flutter,ios/flutter,ios/swiftui,macos/flutter,macos/swiftui'
          '|standard-children:0|children:20:journal-asset-import,'
          '22:journal-asset-settings,14:journal-chrome,12:journal-list,'
          '13:journal-media|properties:'
          '7:payload:string:required:none|events:'
          '5:event[2:id:int:required,7:payload:string:required]',
      properties: const [_payloadProperty],
      events: const [_journalEvent],
      builder: buildJournalAssetImport,
    ),
  );
  registry.register(
    LUIFlutterExtension(
      identifier: 'journal-media',
      fingerprint:
          'lui-extension-v1|13:journal-media|profiles:'
          'android/flutter,ios/flutter,ios/swiftui,macos/flutter,macos/swiftui'
          '|standard-children:1|children:20:journal-asset-import,'
          '22:journal-asset-settings,14:journal-chrome,12:journal-list,'
          '13:journal-media|properties:'
          '7:payload:string:required:none|events:'
          '5:event[2:id:int:required,7:payload:string:required]',
      properties: const [_payloadProperty],
      events: const [_journalEvent],
      builder: (context) => buildJournalMedia(context, renderChild),
    ),
  );
  registry.register(
    LUIFlutterExtension(
      identifier: 'journal-asset-settings',
      fingerprint:
          'lui-extension-v1|22:journal-asset-settings|profiles:'
          'android/flutter,ios/flutter,ios/swiftui,macos/flutter,macos/swiftui'
          '|standard-children:1|children:20:journal-asset-import,'
          '22:journal-asset-settings,14:journal-chrome,12:journal-list,'
          '13:journal-media|properties:'
          '7:payload:string:required:none|events:'
          '5:event[2:id:int:required,7:payload:string:required]',
      acceptsStandardChildren: true,
      properties: const [_payloadProperty],
      events: const [_journalEvent],
      builder: (context) => buildJournalAssetSettings(context, renderChild),
    ),
  );
  registry.register(
    LUIFlutterExtension(
      identifier: 'journal-list',
      fingerprint:
          'lui-extension-v1|12:journal-list|profiles:'
          'android/flutter,ios/flutter,ios/swiftui,macos/flutter,macos/swiftui'
          '|standard-children:1|children:20:journal-asset-import,'
          '22:journal-asset-settings,14:journal-chrome,12:journal-list,'
          '13:journal-media|properties:'
          '7:payload:string:required:none|events:'
          '5:event[2:id:int:required,7:payload:string:required]',
      acceptsStandardChildren: true,
      properties: const [_payloadProperty],
      events: const [_journalEvent],
      builder: (context) => buildJournalList(context, renderChild),
    ),
  );
  return registry;
}
