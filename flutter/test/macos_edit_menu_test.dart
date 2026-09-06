import 'dart:io';

import 'package:bonsai_flutter/bonsai_flutter.dart';
import 'package:bonsai_flutter_logseq_journal_host/application_host_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:material_ui/material_ui.dart';

final class _UnusedAuth implements JournalAuthCapability {
  @override
  Future<String?> currentUserId() async => throw StateError('unused');
  @override
  Future<String> freshIdToken() async => throw StateError('unused');
  @override
  Future<void> signOut() async => throw StateError('unused');
}

void main() {
  testWidgets(
    'native Edit menu updates the Capture controller and save text',
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      Object? menus;
      String? clipboard = '中文 😀\nsecond line';
      messenger.setMockMethodCallHandler(SystemChannels.menu, (call) async {
        if (call.method == 'Menu.setMenus') menus = call.arguments;
        return null;
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': clipboard};
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.menu, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });
      final adapter = ApplicationHostAdapter(
        applicationSupportDirectory: () async => Directory.systemTemp,
        baseUrl: Uri.parse('https://example.invalid'),
        auth: _UnusedAuth(),
        readPreference: (_) async => null,
        writePreference: (_, _) async {},
        readLocalAccountBinding: () async =>
            (userId: 'fixture', managedSyncOrigin: 'https://example.invalid'),
      );
      String? changed;
      String? saved;
      await tester.pumpWidget(
        Builder(
          builder: (context) => adapter.buildHost(
            context: context,
            child: MaterialApp(
              home: Scaffold(
                body: ExpandableMessageComposer(
                  fabPresentation:
                      ExpandableMessageComposerFabPresentation.extended,
                  fabLabel: 'Capture',
                  fabTooltip: 'Open Capture',
                  fabIcon: const Icon(Icons.add),
                  buttons: const [
                    MessageComposerButton(
                      id: 1,
                      tooltip: 'Save',
                      child: Icon(Icons.send),
                    ),
                  ],
                  onChanged: (value) => changed = value,
                  onButtonPressed: (_, value) => saved = value,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open Capture'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), 'Prefix ');

      int? menuId(Object? tree, String label) {
        if (tree is Map) {
          if (tree['label'] == label) return tree['id'] as int?;
          for (final value in tree.values) {
            final result = menuId(value, label);
            if (result != null) return result;
          }
        } else if (tree is List) {
          for (final value in tree) {
            final result = menuId(value, label);
            if (result != null) return result;
          }
        }
        return null;
      }

      Future<void> select(String label) async {
        final id = menuId(menus, label);
        expect(
          id,
          isNotNull,
          reason: '$label must reach Flutter through the native menu',
        );
        await messenger.handlePlatformMessage(
          SystemChannels.menu.name,
          SystemChannels.menu.codec.encodeMethodCall(
            MethodCall('Menu.selectedCallback', id),
          ),
          (_) {},
        );
        await tester.pumpAndSettle();
      }

      await select('Paste');
      expect(changed, 'Prefix 中文 😀\nsecond line');
      const followingEdit = 'Prefix 中文 😀\nsecond line!';
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: followingEdit,
          selection: TextSelection.collapsed(offset: followingEdit.length),
        ),
      );
      await tester.pumpAndSettle();
      await select('Select All');
      await select('Copy');
      expect(clipboard, followingEdit);
      await select('Cut');
      expect(changed, '');
      await select('Paste');
      expect(changed, followingEdit);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(saved, followingEdit);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
