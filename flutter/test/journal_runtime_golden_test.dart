import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Tristate;

import 'package:bonsai_flutter/bonsai_flutter.dart';
// ignore: implementation_imports
import 'package:bonsai_flutter/src/runtime/foreground_frame_loop.dart';
// ignore: implementation_imports
import 'package:bonsai_flutter/src/renderer/pressable_host.dart';
import 'package:bonsai_flutter_logseq_journal_host/application_host_adapter.dart';
import 'package:bonsai_flutter_logseq_journal_host/journal_widget_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:material_3_expressive/material_3_expressive.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_slidable/flutter_slidable.dart' as fs;
import 'package:flutter_test/flutter_test.dart';

const _parentSource = '混合脚本 Journal 2026 条目';
const _firstChild = 'Increase block row height';
const _secondChild = 'Show parent and child preview';
const _thirdChild = 'Keep bounded virtualization';
const _lightStatusCategoryBackgrounds = <Color>[
  Color(0xff585c7e),
  Color(0xff00677c),
  Color(0xff006b57),
  Color(0xff7c3aed),
];
const _lightStatusCategoryForegrounds = <Color>[
  Colors.white,
  Colors.white,
  Colors.white,
  Colors.white,
];
const _darkStatusCategoryBackgrounds = <Color>[
  Color(0xffc0c4eb),
  Color(0xff86d1e9),
  Color(0xff83d6bd),
  Color(0xff7c3aed),
];
const _darkStatusCategoryForegrounds = <Color>[
  Color(0xff2a2e50),
  Color(0xff003642),
  Color(0xff00382b),
  Colors.white,
];

final _runtimeBrightness =
    Platform.environment['JOURNAL_GOLDEN_BRIGHTNESS'] == 'dark'
    ? Brightness.dark
    : Brightness.light;
final _runtimeHighContrast =
    Platform.environment['JOURNAL_GOLDEN_HIGH_CONTRAST'] == '1';
final _writesReferenceGoldens =
    _runtimeBrightness == Brightness.light && !_runtimeHighContrast;

final class _TestAuth implements JournalAuthCapability {
  _TestAuth({String? authenticatedUserId}) {
    if (authenticatedUserId != null) {
      _currentUser.complete(authenticatedUserId);
    }
  }

  final Completer<String?> _currentUser = Completer<String?>();
  final Completer<String> _freshToken = Completer<String>();
  bool _freshTokenRequested = false;

  @override
  Future<String?> currentUserId() => _currentUser.future;

  @override
  Future<String> freshIdToken() {
    _freshTokenRequested = true;
    return _freshToken.future;
  }

  @override
  Future<void> signOut() async => throw StateError('unused');

  void rejectPendingAuthentication() {
    if (!_currentUser.isCompleted) {
      _currentUser.completeError(StateError('golden harness disposed'));
    }
    if (_freshTokenRequested && !_freshToken.isCompleted) {
      _freshToken.completeError(StateError('golden harness disposed'));
    }
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  WidgetsApp.debugAllowBannerOverride = false;
  if (binding is LiveTestWidgetsFlutterBinding) {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  }

  testWidgets(
    'real runtime renders all typography presets at 390 x 844',
    (tester) async {
      final harness = await _RuntimeHarness.start(
        tester,
        brightness: Brightness.light,
        highContrast: false,
        reconcileAuthenticatedUser: true,
      );
      expect(tester.takeException(), isNull);

      Future<void> expectPresetGolden(String preset) async {
        final scrollable = find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        );
        final position = tester.state<ScrollableState>(scrollable).position;
        position.jumpTo(80);
        await tester.pump();
        expect(
          _sliverPaintExtent(tester, find.byType(SliverAppBar)),
          closeTo(64 + 47, 0.5),
        );
        position.jumpTo(0);
        await tester.pump(const Duration(milliseconds: 220));
        _expectTimelineStartsBelowHeader(tester);
        expect(find.text(_parentSource), findsOneWidget);
        expect(
          DefaultTextStyle.of(
            tester.element(find.text(_parentSource)),
          ).style.fontFamily,
          'PingFang SC',
        );
        await expectLater(
          find.byType(Scaffold).first,
          matchesGoldenFile('goldens/journal-typography-$preset.png'),
        );
      }

      Future<void> selectPreset(String label, String storedValue) async {
        await tester.tap(find.bySemanticsLabel('Account menu'));
        await harness.pumpUntil(
          () => find.text('Settings').evaluate().isNotEmpty,
          reason: 'the Account dialog did not expose Settings',
        );
        expect(find.byType(M3EDialog), findsOneWidget);
        final accountDialog = tester.widget<M3EDialog>(find.byType(M3EDialog));
        expect(accountDialog.actions, hasLength(1));
        final accountButtons = find.descendant(
          of: find.byType(M3EDialog),
          matching: find.byType(M3EButton),
        );
        expect(accountButtons, findsNWidgets(6));
        for (final element in accountButtons.evaluate()) {
          expect((element.widget as M3EButton).style, M3EButtonStyle.text);
        }
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Settings').last);
        await harness.pumpUntil(
          () => find.text(label).evaluate().isNotEmpty,
          reason: 'the typography choice group did not open',
        );
        await tester.tap(find.text(label));
        await harness.pumpUntil(() {
          final chip = find.ancestor(
            of: find.text(label),
            matching: find.byType(M3EChip),
          );
          return chip.evaluate().isNotEmpty &&
              tester.widget<M3EChip>(chip).type == M3EChipType.filter &&
              tester.widget<M3EChip>(chip).selected;
        }, reason: 'the $storedValue preset did not become selected');
        await tester.tap(find.text('Close'));
        await harness.pumpUntil(
          () => find.byType(M3EChip).evaluate().isEmpty,
          reason: 'Settings did not close after selecting $storedValue',
        );
        await tester.pump(const Duration(milliseconds: 220));
      }

      await expectPresetGolden('balanced');
      await selectPreset('A Dense', 'dense');
      await expectPresetGolden('dense');
      await selectPreset('C Comfortable', 'comfortable');
      await expectPresetGolden('comfortable');
    },
    skip: Platform.environment['RUN_REAL_OCAML_GOLDEN'] != '1',
  );

  testWidgets(
    'real runtime morphs Capture FAB with standard motion',
    (tester) async {
      final harness = await _RuntimeHarness.start(
        tester,
        brightness: Brightness.light,
        highContrast: false,
      );
      tester.view.physicalSize = const Size(390, 600);
      await tester.pump();
      expect(tester.takeException(), isNull);
      final composer = find.byType(ExpandableMessageComposer);
      final floatingActionButton = find.byType(FloatingActionButton);
      final scrollable = find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(24));
      final extendedWidth = tester.getSize(floatingActionButton).width;
      final extendedRect = tester.getRect(floatingActionButton);

      final gesture = await tester.startGesture(
        tester.getCenter(find.text(_parentSource)),
      );
      await gesture.moveBy(const Offset(0, -19));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -23));
      await tester.pump(const Duration(milliseconds: 250));
      expect(position.pixels, closeTo(23, 0.1));
      expect(
        tester.widget<ExpandableMessageComposer>(composer).fabPresentation,
        ExpandableMessageComposerFabPresentation.extended,
      );

      await gesture.moveBy(const Offset(0, -1));
      await harness.pumpUntil(
        () =>
            tester
                .widget<ExpandableMessageComposer>(composer)
                .fabPresentation ==
            ExpandableMessageComposerFabPresentation.compact,
        reason: '24 points of downward travel did not compact Capture',
      );
      expect(tester.getSize(floatingActionButton).width, extendedWidth);
      expect(tester.getRect(floatingActionButton).right, extendedRect.right);
      expect(find.text('Capture'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 90));
      expect(
        tester.getSize(floatingActionButton).width,
        allOf(greaterThan(56), lessThan(extendedWidth)),
        reason:
            'standard motion did not animate FAB width from the trailing edge',
      );
      final labelOpacity = tester.widget<Opacity>(
        find.ancestor(of: find.text('Capture'), matching: find.byType(Opacity)),
      );
      expect(labelOpacity.opacity, inExclusiveRange(0, 1));
      expect(
        tester.getRect(floatingActionButton).right,
        closeTo(extendedRect.right, 0.01),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getSize(floatingActionButton), const Size(56, 56));
      expect(find.text('Capture'), findsNothing);
      await gesture.up();
      await harness.dispose();
    },
    skip: Platform.environment['RUN_REAL_OCAML_GOLDEN'] != '1',
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'real runtime renders compact Capture in RTL at large text',
    (tester) async {
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      final harness = await _RuntimeHarness.start(
        tester,
        brightness: Brightness.light,
        highContrast: false,
      );
      tester.view.physicalSize = const Size(390, 600);
      await tester.pump();
      expect(tester.takeException(), isNull);
      final composer = find.byType(ExpandableMessageComposer);
      final scrollable = find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(24));
      position.jumpTo(24);
      await _dispatchScrollUpdate(tester, scrollable, 24);
      await harness.pumpUntil(
        () =>
            tester
                .widget<ExpandableMessageComposer>(composer)
                .fabPresentation ==
            ExpandableMessageComposerFabPresentation.compact,
        reason: 'Capture did not settle compact before RTL coverage',
      );
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.text('Capture'), findsNothing);
      expect(
        tester.getSize(find.byType(FloatingActionButton)),
        const Size(56, 56),
      );

      tester.binding.platformDispatcher.localesTestValue = const [
        Locale('ar', 'SA'),
      ];
      tester.platformDispatcher.textScaleFactorTestValue = 3.2;
      await tester.pump();
      await harness.pumpUntil(
        () =>
            Directionality.of(tester.element(composer)) == TextDirection.rtl &&
            MediaQuery.textScalerOf(tester.element(composer)).scale(1) > 3,
        reason: 'RTL large-text environment did not reach compact Capture',
      );
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.text('Capture'), findsNothing);
      expect(
        tester.getSize(find.byType(FloatingActionButton)),
        const Size(56, 56),
      );
      final rtlStatusRow = find.text(_parentSource);
      final rtlSlidable = find.ancestor(
        of: rtlStatusRow,
        matching: find.byType(fs.Slidable),
      );
      await tester.drag(rtlStatusRow, const Offset(-390, 0));
      await _pumpSlidableMotion(tester);
      expect(tester.takeException(), isNull);
      final actionLabel = find.descendant(
        of: rtlSlidable,
        matching: find.text('No status'),
      );
      expect(actionLabel, findsOneWidget);
      expect(
        tester
            .getRect(
              find.ancestor(
                of: actionLabel,
                matching: find.byType(fs.CustomSlidableAction),
              ),
            )
            .width,
        greaterThanOrEqualTo(44),
      );
      expect(
        fs.Slidable.of(tester.element(rtlStatusRow))!.ratio,
        closeTo(-0.25, 0.01),
        reason: 'RTL did not mirror the logical-start status button',
      );
      final rtlClose = fs.Slidable.of(tester.element(rtlStatusRow))!.close();
      await _pumpSlidableMotion(tester);
      await rtlClose;
      await expectLater(
        find.byType(Scaffold).first,
        matchesGoldenFile('goldens/journal-capture-compact-rtl-large-text.png'),
      );
      await harness.dispose();
    },
    skip: Platform.environment['RUN_REAL_OCAML_GOLDEN'] != '1',
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'real runtime preserves Capture behavior across directional presentation changes',
    (tester) async {
      final harness = await _RuntimeHarness.start(
        tester,
        brightness: Brightness.light,
        highContrast: false,
      );
      tester.view.physicalSize = const Size(390, 600);
      await tester.pump();
      expect(tester.takeException(), isNull);
      final composer = find.byType(ExpandableMessageComposer);
      final floatingActionButton = find.byType(FloatingActionButton);
      final scrollable = find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(24));
      final composerState = tester.state(composer);
      expect(
        tester.widget<ExpandableMessageComposer>(composer).fabPresentation,
        ExpandableMessageComposerFabPresentation.extended,
      );
      expect(
        tester.widget<FloatingActionButton>(floatingActionButton).isExtended,
        isTrue,
      );
      expect(find.text('Capture'), findsOneWidget);

      final gesture = await tester.startGesture(
        tester.getCenter(find.text(_parentSource)),
      );
      await gesture.moveBy(const Offset(0, -19));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -23));
      await tester.pump(const Duration(milliseconds: 250));
      expect(position.pixels, closeTo(23, 0.1));
      expect(
        tester.widget<ExpandableMessageComposer>(composer).fabPresentation,
        ExpandableMessageComposerFabPresentation.extended,
        reason: 'sub-threshold downward travel compacted Capture',
      );
      expect(tester.state(composer), same(composerState));

      await gesture.moveBy(const Offset(0, -1));
      await harness.pumpUntil(
        () =>
            tester
                .widget<ExpandableMessageComposer>(composer)
                .fabPresentation ==
            ExpandableMessageComposerFabPresentation.compact,
        reason: '24 points of downward travel did not compact Capture',
      );
      await tester.pump(const Duration(milliseconds: 180));
      await gesture.up();
      expect(tester.state(composer), same(composerState));
      final compactFab = tester.widget<FloatingActionButton>(
        floatingActionButton,
      );
      expect(compactFab.isExtended, isFalse);
      expect(compactFab.mini, isFalse);
      expect(tester.getSize(floatingActionButton), const Size(56, 56));
      expect(find.text('Capture'), findsNothing);
      expect(find.bySemanticsLabel('Open Capture'), findsOneWidget);
      _expectMaterialGlyph(
        floatingActionButton,
        Icons.add,
        role: 'compact FAB',
      );

      position.jumpTo(124);
      await _dispatchScrollUpdate(tester, scrollable, 100);
      await tester.pump(const Duration(milliseconds: 220));
      expect(
        tester.widget<ExpandableMessageComposer>(composer).fabPresentation,
        ExpandableMessageComposerFabPresentation.compact,
        reason: 'downward travel while compact toggled the FAB',
      );
      await tester.tap(floatingActionButton);
      await tester.pump();
      const draft = '  retained while scrolling 👩🏽‍💻  ';
      await tester.enterText(find.byType(TextField), draft);
      await tester.pump();
      final textField = tester.widget<TextField>(find.byType(TextField));
      final controller = textField.controller;
      final focusNode = textField.focusNode;
      final route = ModalRoute.of(tester.element(find.byType(MessageComposer)));
      expect(route, isNotNull);
      expect(focusNode!.hasFocus, isTrue);

      position.jumpTo(101);
      await _dispatchScrollUpdate(tester, scrollable, -23);
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        tester.widget<ExpandableMessageComposer>(composer).fabPresentation,
        ExpandableMessageComposerFabPresentation.compact,
        reason: '23 points of upward travel extended Capture',
      );
      position.jumpTo(100);
      await _dispatchScrollUpdate(tester, scrollable, -1);
      await harness.pumpUntil(
        () =>
            tester
                .widget<ExpandableMessageComposer>(composer)
                .fabPresentation ==
            ExpandableMessageComposerFabPresentation.extended,
        reason: '24 points of upward travel did not extend Capture',
      );
      expect(tester.state(composer), same(composerState));
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byType(MessageComposer))),
        same(route),
      );
      final updatedTextField = tester.widget<TextField>(find.byType(TextField));
      expect(updatedTextField.controller, same(controller));
      expect(updatedTextField.focusNode, same(focusNode));
      expect(updatedTextField.controller!.text, draft);
      expect(updatedTextField.focusNode!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await harness.pumpUntil(
        () => find.byType(BottomSheet).evaluate().isEmpty,
        reason: 'Escape did not dismiss Capture after presentation changes',
      );
      expect(find.text('Capture'), findsOneWidget);

      position.jumpTo(200);
      await _dispatchScrollUpdate(tester, scrollable, 100);
      await harness.pumpUntil(
        () =>
            tester
                .widget<ExpandableMessageComposer>(composer)
                .fabPresentation ==
            ExpandableMessageComposerFabPresentation.compact,
        reason: 'one large downward event did not compact Capture',
      );
      await tester.pump(const Duration(milliseconds: 220));
      expect(tester.state(composer), same(composerState));
      position.jumpTo(0);
      await _dispatchScrollUpdate(tester, scrollable, -200);
      await harness.pumpUntil(
        () =>
            tester
                .widget<ExpandableMessageComposer>(composer)
                .fabPresentation ==
            ExpandableMessageComposerFabPresentation.extended,
        reason: 'the top boundary did not restore extended Capture',
      );
      await tester.pump(const Duration(milliseconds: 220));

      await expectLater(
        find.byType(Scaffold).first,
        matchesGoldenFile('goldens/journal-capture-extended-light.png'),
      );
      position.jumpTo(24);
      await _dispatchScrollUpdate(tester, scrollable, 24);
      await harness.pumpUntil(
        () =>
            tester
                .widget<ExpandableMessageComposer>(composer)
                .fabPresentation ==
            ExpandableMessageComposerFabPresentation.compact,
        reason: 'Capture did not settle compact for golden coverage',
      );
      await tester.pump(const Duration(milliseconds: 220));
      await expectLater(
        find.byType(Scaffold).first,
        matchesGoldenFile('goldens/journal-capture-compact-light.png'),
      );

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pump();
      await harness.pumpUntil(
        () => Theme.of(tester.element(composer)).brightness == Brightness.dark,
        reason: 'dark appearance did not reach compact Capture',
      );
      await tester.pump(const Duration(milliseconds: 220));
      await expectLater(
        find.byType(Scaffold).first,
        matchesGoldenFile('goldens/journal-capture-compact-dark.png'),
      );
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(highContrast: true);
      await tester.pump();
      await harness.pumpUntil(
        () => MediaQuery.highContrastOf(tester.element(composer)),
        reason: 'high contrast did not reach compact Capture',
      );
      await tester.pump(const Duration(milliseconds: 220));
      await expectLater(
        find.byType(Scaffold).first,
        matchesGoldenFile(
          'goldens/journal-capture-compact-high-contrast-dark.png',
        ),
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pump();
      await harness.pumpUntil(
        () => Theme.of(tester.element(composer)).brightness == Brightness.light,
        reason: 'high-contrast light appearance did not reach compact Capture',
      );
      await tester.pump(const Duration(milliseconds: 220));
      await expectLater(
        find.byType(Scaffold).first,
        matchesGoldenFile(
          'goldens/journal-capture-compact-high-contrast-light.png',
        ),
      );
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(
            disableAnimations: true,
            accessibleNavigation: true,
          );
      await tester.pump();
      tester.state<ScrollableState>(scrollable).position.jumpTo(0);
      await _dispatchScrollUpdate(tester, scrollable, -24);
      await harness.pumpUntil(
        () =>
            tester
                .widget<ExpandableMessageComposer>(composer)
                .animationDuration ==
            Duration.zero,
        reason: 'Reduced Motion did not remove Capture transition duration',
      );
      tester.state<ScrollableState>(scrollable).position.jumpTo(24);
      await _dispatchScrollUpdate(tester, scrollable, 24);
      await harness.pumpUntil(
        () =>
            tester
                .widget<ExpandableMessageComposer>(composer)
                .fabPresentation ==
            ExpandableMessageComposerFabPresentation.compact,
        reason: 'Reduced Motion did not apply compact presentation',
      );
      expect(tester.getSize(floatingActionButton), const Size(56, 56));
      await harness.dispose();
    },
    skip: Platform.environment['RUN_REAL_OCAML_GOLDEN'] != '1',
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'real runtime preserves Capture task intent and applies the single status sheet',
    (tester) async {
      final harness = await _RuntimeHarness.start(
        tester,
        brightness: Brightness.light,
        highContrast: false,
      );
      expect(tester.takeException(), isNull);

      final parentRow = find.text(_parentSource);
      final parentSlidable = find.ancestor(
        of: parentRow,
        matching: find.byType(fs.Slidable),
      );
      final parentController = fs.Slidable.of(tester.element(parentRow))!;
      await tester.drag(parentRow, const Offset(390, 0));
      await _pumpSlidableMotion(tester);
      expect(parentController.ratio, closeTo(0.25, 0.01));
      final actionLabel = find.descendant(
        of: parentSlidable,
        matching: find.text('No status'),
      );
      expect(actionLabel, findsOneWidget);
      final currentNoStatus = tester.widget<fs.CustomSlidableAction>(
        find.ancestor(
          of: actionLabel,
          matching: find.byType(fs.CustomSlidableAction),
        ),
      );
      expect(currentNoStatus.onPressed, isNotNull);
      final parentClose = parentController.close();
      await _pumpSlidableMotion(tester);
      await parentClose;
      await tester.drag(parentRow, const Offset(390, 0));
      await _pumpSlidableMotion(tester);
      expect(parentController.ratio, closeTo(0.25, 0.01));
      expect(
        find.bySemanticsLabel(RegExp('$_parentSource.*status ')),
        findsNothing,
        reason: 'a full-width drag changed status without an explicit tap',
      );
      await tester.tap(actionLabel);
      await harness.pumpUntil(
        () => find.text('Set status').evaluate().isNotEmpty,
        reason: 'the status button did not open the modal bottom sheet',
      );
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.byType(BottomSheet), findsWidgets);
      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
      final statusButtons = find.descendant(
        of: find.byType(DraggableScrollableSheet),
        matching: find.byType(M3EButton),
      );
      expect(statusButtons, findsNWidgets(7));
      for (final element in statusButtons.evaluate()) {
        expect((element.widget as M3EButton).style, M3EButtonStyle.text);
      }
      final sheetRect = tester.getRect(find.byType(DraggableScrollableSheet));
      final screenHeight = tester.getSize(find.byType(MaterialApp)).height;
      expect(
        sheetRect.height,
        closeTo(screenHeight * 0.5, 1),
        reason: 'the status sheet did not open at the Medium detent',
      );
      expect(
        find.bySemanticsLabel('Status picker size'),
        findsOneWidget,
        reason: 'the Medium detent has no accessible drag handle',
      );
      for (final label in const [
        'Backlog',
        'Todo',
        'Doing',
        'In review',
        'Done',
        'Canceled',
        'Clear',
      ]) {
        final option = find.text(label, skipOffstage: false);
        expect(option, findsOneWidget);
        expect(
          sheetRect.contains(tester.getCenter(option)),
          isTrue,
          reason: '$label is not visible inside the Medium detent',
        );
        if (label != 'Clear') {
          expect(
            option.hitTestable(),
            findsOneWidget,
            reason: '$label is inside the Medium detent but cannot be tapped',
          );
        }
      }
      expect(find.text('Now'), findsNothing);
      expect(find.text('Waiting'), findsNothing);
      expect(find.text('Later'), findsNothing);
      expect(find.text('Clear'), findsOneWidget);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Clear'))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/journal-status-sheet-medium.png'),
      );
      await tester.drag(
        find.bySemanticsLabel('Status picker size'),
        const Offset(0, 420),
      );
      await harness.pumpUntil(
        () => find.text('Set status').evaluate().isEmpty,
        reason: 'dragging the Medium status sheet down did not dismiss it',
      );
      expect(
        find.bySemanticsLabel(RegExp('$_parentSource.*status ')),
        findsNothing,
        reason: 'drag dismissal changed status',
      );
      await tester.pump(const Duration(milliseconds: 220));
      await _pumpSlidableMotion(tester);
      final reopenStatus = parentController.openStartActionPane();
      await _pumpSlidableMotion(tester);
      await reopenStatus;
      await tester.tap(actionLabel);
      await harness.pumpUntil(
        () => find.text('Set status').evaluate().isNotEmpty,
        reason: 'the status sheet did not reopen after drag dismissal',
      );
      await tester.pump(const Duration(milliseconds: 220));
      await tester.tap(find.text('Doing'));
      await harness.pumpUntil(
        () =>
            find.text('Set status').evaluate().isEmpty &&
            find
                .bySemanticsLabel(RegExp('$_parentSource.*status Doing'))
                .evaluate()
                .isNotEmpty,
        reason: 'the Doing sheet option did not reconcile through the Worker',
      );
      await _pumpSlidableMotion(tester);
      expect(parentController.ratio, closeTo(0, 0.01));

      await tester.tap(find.byType(FloatingActionButton));
      await harness.pumpUntil(
        () => find.byType(MessageComposer).evaluate().isNotEmpty,
        reason: 'Capture composer did not open',
      );
      await tester.pump(const Duration(milliseconds: 220));
      const draft = '  Capture task 中文 👩🏽‍💻 exact  ';
      await tester.enterText(find.byType(TextField), draft);
      await tester.pump();
      _expectMaterialGlyph(
        find.byTooltip('Capture as task, off'),
        Icons.timelapse,
        role: 'unchecked Capture task action',
      );
      await tester.tap(find.byTooltip('Capture as task, off').hitTestable());
      await harness.pumpUntil(
        () => find.byTooltip('Capture as task, on').evaluate().isNotEmpty,
        reason: 'Capture task action did not become checked',
      );
      _expectMaterialGlyph(
        find.byTooltip('Capture as task, on'),
        Icons.timelapse,
        role: 'checked Capture task action',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        draft,
      );
      await tester.drag(find.byType(MessageComposer), const Offset(0, 80));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.byType(MessageComposer), findsNothing);
      await tester.tap(find.byType(FloatingActionButton));
      await harness.pumpUntil(
        () =>
            find.byType(TextField).evaluate().isNotEmpty &&
            tester.widget<TextField>(find.byType(TextField)).controller!.text ==
                draft &&
            find.byTooltip('Capture as task, on').evaluate().isNotEmpty,
        reason: 'dismissed Capture draft and task intent were not restored',
      );
      await tester.pump(const Duration(milliseconds: 220));
      await tester.drag(find.byType(MessageComposer), const Offset(0, 80));
      await tester.pump(const Duration(milliseconds: 440));
      await harness.dispose();
    },
    skip: Platform.environment['RUN_REAL_OCAML_GOLDEN'] != '1',
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'real runtime matches row, divider, expandable Capture, preview, and swipe contracts',
    (tester) async {
      final harness = await _RuntimeHarness.start(
        tester,
        brightness: _runtimeBrightness,
        highContrast: _runtimeHighContrast,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(fs.SlidableAutoCloseBehavior), findsOneWidget);
      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(materialApp.themeMode, ThemeMode.system);
      expect(find.byType(MessageComposer), findsNothing);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      _expectMaterialGlyph(
        find.byType(FloatingActionButton),
        Icons.add,
        role: 'Capture FAB',
      );
      expect(find.text('Capture'), findsOneWidget);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.bottomNavigationBar, isNull);
      expect(scaffold.bottomSheet, isNull);
      expect(scaffold.floatingActionButton, isNotNull);
      final scaffoldRect = tester.getRect(find.byType(Scaffold).first);
      final bodyRect = tester.getRect(find.byWidget(scaffold.body!));
      expect(bodyRect.bottom, closeTo(scaffoldRect.bottom, 0.1));
      final composerRect = tester.getRect(
        find.byType(ExpandableMessageComposer),
      );
      final captureFabRect = tester.getRect(find.byType(FloatingActionButton));
      expect(composerRect, captureFabRect);
      expect(captureFabRect.width, lessThan(scaffoldRect.width));
      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(find.byType(SliverAppBar), findsOneWidget);
      expect(
        find.ancestor(
          of: find.bySemanticsLabel('Account menu'),
          matching: find.byType(M3ETooltip),
        ),
        findsOneWidget,
      );
      var journalAppBar = tester.widget<SliverAppBar>(
        find.byType(SliverAppBar),
      );
      expect(journalAppBar.pinned, isTrue);
      expect(journalAppBar.floating, isFalse);
      expect(journalAppBar.snap, isFalse);
      expect(journalAppBar.stretch, isFalse);
      expect(journalAppBar.automaticallyImplyLeading, isTrue);
      expect(journalAppBar.centerTitle, isTrue);
      expect(journalAppBar.expandedHeight, 64);
      expect(journalAppBar.collapsedHeight, 64);
      expect(journalAppBar.toolbarHeight, 56);
      expect(journalAppBar.elevation, isNull);
      expect(journalAppBar.backgroundColor, isNotNull);
      expect(journalAppBar.foregroundColor, isNotNull);
      expect(journalAppBar.leading, isNotNull);
      expect(journalAppBar.flexibleSpace, isNull);
      expect(journalAppBar.bottom, isNull);
      expect(journalAppBar.actions, isNotEmpty);
      expect(find.text('Today · Wed, Aug 12'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Today, Wed, Aug 12',
        ),
        findsOneWidget,
      );
      expect(
        _sliverPaintExtent(tester, find.byType(SliverAppBar)),
        closeTo(64 + 47, 0.5),
      );
      final journalScroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        ),
      );
      journalScroll.position.jumpTo(80);
      await tester.pump();
      expect(find.text('Today · Wed, Aug 12').hitTestable(), findsOneWidget);
      expect(
        _sliverPaintExtent(tester, find.byType(SliverAppBar)),
        closeTo(64 + 47, 0.5),
      );
      journalScroll.position.jumpTo(0);
      await tester.pump();
      expect(find.text('Today · Wed, Aug 12').hitTestable(), findsOneWidget);
      expect(find.text(_parentSource), findsOneWidget);
      expect(find.text(_firstChild), findsOneWidget);
      expect(find.text('21:37'), findsOneWidget);
      expect(find.text('Todo rail'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('status Todo')), findsOneWidget);
      _expectSeedOwnedSemanticColors(
        tester,
        brightness: _runtimeBrightness,
        highContrast: _runtimeHighContrast,
      );
      expect(
        find.bySemanticsLabel(
          RegExp('^${RegExp.escape(_parentSource)}.*created at 21:37'),
        ),
        findsOneWidget,
      );

      final rowRect = _ancestorRectWithHeight(
        tester,
        find.text(_parentSource),
        82,
      );
      expect(rowRect.width, closeTo(390, 0.5));
      expect(
        tester.getTopLeft(find.text('21:37')).dx,
        greaterThan(tester.getTopRight(find.text(_parentSource)).dx),
      );
      final dividers = _timelineDividers(tester, devicePixelRatio: 1);
      expect(dividers.length, inInclusiveRange(1, 3));
      for (final rect in dividers) {
        expect(rect.left, closeTo(0, 0.25));
        expect(rect.right, closeTo(390, 0.25));
        expect(rect.height, closeTo(1, 0.05));
      }

      final disclosureSemantics = tester.getSemantics(
        find.bySemanticsLabel(
          RegExp('^${RegExp.escape(_parentSource)}.*created at 21:37'),
        ),
      );
      expect(
        disclosureSemantics.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
      );
      final disclosurePressable = find
          .ancestor(
            of: find.text(_parentSource),
            matching: find.byType(PressableHost),
          )
          .first;
      final collapsedParentTop = tester.getTopLeft(find.text(_parentSource)).dy;
      await tester.tap(disclosurePressable);
      await tester.pump(const Duration(milliseconds: 80));
      await harness.pumpUntil(
        () => _directChildText(_firstChild).evaluate().isNotEmpty,
        reason: 'expanded direct children were not published',
      );
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.text(_firstChild), findsOneWidget);
      expect(find.text(_secondChild), findsOneWidget);
      expect(find.text(_thirdChild), findsNWidgets(2));
      final parentTop = tester.getTopLeft(find.text(_parentSource)).dy;
      final firstChildTop = tester.getTopLeft(_directChildText(_firstChild)).dy;
      final secondChildTop = tester
          .getTopLeft(_directChildText(_secondChild))
          .dy;
      expect(firstChildTop - parentTop, closeTo(50, 0.1));
      expect(secondChildTop - firstChildTop, closeTo(44, 0.1));
      expect(
        tester.getTopLeft(find.text(_parentSource)).dy,
        closeTo(collapsedParentTop, 0.1),
      );
      expect(
        find.bySemanticsLabel(
          RegExp('^${RegExp.escape(_parentSource)}.*created at 21:37'),
        ),
        findsOneWidget,
      );
      expect(
        _timelineDividers(tester, devicePixelRatio: 1).length,
        inInclusiveRange(1, 3),
      );
      if (_writesReferenceGoldens) {
        await expectLater(
          find.byType(Scaffold).first,
          matchesGoldenFile('goldens/journal-reference-alignment.png'),
        );
      }
      await tester.tap(disclosurePressable);
      await tester.pump(const Duration(milliseconds: 80));
      await harness.pumpUntil(
        () => _directChildText(_firstChild).evaluate().isEmpty,
        reason: 'direct children did not collapse',
      );
      await tester.pump(const Duration(milliseconds: 220));
      expect(
        tester.getTopLeft(find.text(_parentSource)).dy,
        closeTo(collapsedParentTop, 0.1),
      );

      final parentSlidable = find.ancestor(
        of: find.text(_parentSource),
        matching: find.byType(fs.Slidable),
      );
      final parentController = fs.Slidable.of(
        tester.element(find.text(_parentSource)),
      )!;
      await tester.dragFrom(
        tester.getCenter(parentSlidable),
        const Offset(390, 0),
      );
      await _pumpSlidableMotion(tester);
      expect(parentController.ratio, closeTo(0.25, 0.01));
      _expectStatusButtonColors(
        tester,
        parentSlidable,
        brightness: _runtimeBrightness,
        currentStatus: 'No status',
      );
      final noStatusButton = find.descendant(
        of: parentSlidable,
        matching: find.text('No status'),
      );
      expect(noStatusButton, findsOneWidget);
      final currentNoStatus = tester.widget<fs.CustomSlidableAction>(
        find.ancestor(
          of: noStatusButton,
          matching: find.byType(fs.CustomSlidableAction),
        ),
      );
      expect(currentNoStatus.onPressed, isNotNull);
      await tester.dragFrom(
        tester.getCenter(parentSlidable),
        const Offset(390, 0),
      );
      await _pumpSlidableMotion(tester);
      expect(parentController.ratio, closeTo(0.25, 0.01));
      expect(
        find.bySemanticsLabel(RegExp('$_parentSource.*status ')),
        findsNothing,
        reason: 'a full-width status drag mutated the block',
      );
      await tester.tap(noStatusButton);
      await harness.pumpUntil(
        () => find.text('Set status').evaluate().isNotEmpty,
        reason: 'status sheet did not open',
      );
      await tester.tapAt(const Offset(8, 8));
      await harness.pumpUntil(
        () => find.text('Set status').evaluate().isEmpty,
        reason: 'status sheet barrier did not dismiss the route',
      );
      expect(
        find.bySemanticsLabel(RegExp('$_parentSource.*status ')),
        findsNothing,
        reason: 'barrier dismissal changed status',
      );
      await _pumpSlidableMotion(tester);
      expect(parentController.ratio, closeTo(0, 0.01));
      final statusReopen = parentController.openStartActionPane();
      await _pumpSlidableMotion(tester);
      await statusReopen;
      expect(parentController.ratio, closeTo(0.25, 0.01));
      await tester.tap(noStatusButton);
      await harness.pumpUntil(
        () => find.text('Set status').evaluate().isNotEmpty,
        reason: 'status sheet did not reopen after dismissal',
      );
      await tester.pump(const Duration(milliseconds: 220));
      await tester.tap(find.text('Doing'));
      await harness.pumpUntil(
        () =>
            find.text('Set status').evaluate().isEmpty &&
            find
                .bySemanticsLabel(RegExp('$_parentSource.*status Doing'))
                .evaluate()
                .isNotEmpty,
        reason: 'explicit Doing option did not reconcile through the runtime',
      );
      await tester.pump(const Duration(milliseconds: 220));
      await _pumpSlidableMotion(tester);
      expect(parentController.ratio, closeTo(0, 0.01));

      final swipeGesture = await tester.startGesture(
        tester.getCenter(parentSlidable),
      );
      await swipeGesture.moveBy(
        const Offset(-80, 0),
        timeStamp: const Duration(milliseconds: 500),
      );
      await tester.pump();
      final parentDelete = find.descendant(
        of: parentSlidable,
        matching: find.text('Delete'),
      );
      expect(parentDelete, findsOneWidget);
      final deleteAction = tester.widget<fs.CustomSlidableAction>(
        find.ancestor(
          of: parentDelete,
          matching: find.byType(fs.CustomSlidableAction),
        ),
      );
      expect(deleteAction.borderRadius, BorderRadius.zero);
      final deleteActionFinder = find.ancestor(
        of: parentDelete,
        matching: find.byType(fs.CustomSlidableAction),
      );
      final actionRect = tester.getRect(deleteActionFinder);
      final actionDividers = find.descendant(
        of: deleteActionFinder,
        matching: find.byType(Divider),
      );
      expect(actionDividers, findsNWidgets(2));
      final dividerRects = actionDividers
          .evaluate()
          .map(
            (element) => tester.getRect(
              find.byElementPredicate((candidate) => candidate == element),
            ),
          )
          .toList();
      expect(dividerRects.first.top, closeTo(actionRect.top, 0.1));
      expect(dividerRects.last.bottom, closeTo(actionRect.bottom, 0.1));
      for (final dividerRect in dividerRects) {
        expect(dividerRect.width, closeTo(actionRect.width, 0.1));
        expect(dividerRect.height, closeTo(1, 0.1));
      }
      if (_writesReferenceGoldens) {
        await expectLater(
          find.byType(Scaffold).first,
          matchesGoldenFile('goldens/journal-slidable-open.png'),
        );
      }
      await swipeGesture.up(timeStamp: const Duration(milliseconds: 600));
      await _pumpSlidableMotion(tester);
      expect(find.text(_parentSource), findsOneWidget);
      expect(find.text('Block and descendants removed'), findsNothing);

      expect(parentController.ratio, closeTo(-0.25, 0.01));
      await tester.tapAt(tester.getCenter(find.text('Todo rail')));
      await _pumpSlidableMotion(tester);
      expect(parentController.ratio, closeTo(0, 0.01));

      await tester.drag(find.text(_parentSource), const Offset(-390, 0));
      await _pumpSlidableMotion(tester);
      expect(find.text(_parentSource), findsOneWidget);
      expect(parentController.ratio, closeTo(-0.25, 0.01));
      expect(find.text('Block and descendants removed'), findsNothing);

      final secondController = fs.Slidable.of(
        tester.element(find.text('Todo rail')),
      )!;
      final secondOpen = secondController.openEndActionPane();
      await _pumpSlidableMotion(tester);
      await secondOpen;
      expect(secondController.ratio, closeTo(-0.25, 0.01));
      expect(parentController.ratio, closeTo(0, 0.01));

      await tester.tapAt(tester.getCenter(find.text(_parentSource)));
      await _pumpSlidableMotion(tester);
      expect(secondController.ratio, closeTo(0, 0.01));
      final shortestController = fs.Slidable.of(
        tester.element(find.text('Todo rail')),
      )!;
      final shortestOpen = shortestController.openEndActionPane();
      await _pumpSlidableMotion(tester);
      await shortestOpen;
      expect(
        tester.takeException(),
        isNull,
        reason: 'the delete action overflowed the shortest Journal row',
      );
      final shortestRow = _ancestorRectWithHeight(
        tester,
        find.text('Todo rail'),
        44,
      );
      final shortestSlidable = find.ancestor(
        of: find.text('Todo rail'),
        matching: find.byType(fs.Slidable),
      );
      final shortestDelete = find.descendant(
        of: shortestSlidable,
        matching: find.text('Delete'),
      );
      final shortestAction = find.ancestor(
        of: shortestDelete,
        matching: find.byType(fs.CustomSlidableAction),
      );
      expect(
        tester.getRect(shortestAction).height,
        closeTo(shortestRow.height, 0.1),
      );
      await tester.tapAt(tester.getCenter(find.text(_parentSource)));
      await _pumpSlidableMotion(tester);
      expect(shortestController.ratio, closeTo(0, 0.01));

      for (final dpr in const [2.0, 3.0, 4.0]) {
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(390 * dpr, 844 * dpr);
        tester.view.padding = FakeViewPadding(top: 47 * dpr, bottom: 34 * dpr);
        await harness.pumpUntil(() {
          final count = _timelineDividers(tester, devicePixelRatio: dpr).length;
          return count >= 1 && count <= 3;
        }, reason: 'divider geometry did not settle at ${dpr.toInt()}x');
        final scaledDividers = _timelineDividers(tester, devicePixelRatio: dpr);
        expect(scaledDividers.length, inInclusiveRange(1, 3));
        for (final rect in scaledDividers) {
          expect(rect.height * dpr, closeTo(1, 0.08));
          expect(rect.left, closeTo(0, 0.25));
          expect(rect.right, closeTo(390, 0.25));
        }
      }
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      await tester.pump();
      await _expectLastRowAboveCaptureBar(tester, harness);

      final fab = find.byType(FloatingActionButton);
      await tester.tap(fab);
      await tester.pump();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(MessageComposer), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
        reason: 'Capture input did not focus on the first mounted sheet frame',
      );
      await tester.pump(const Duration(milliseconds: 110));
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      await tester.pump(const Duration(milliseconds: 90));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
        reason: 'Capture input lost focus during its standard transition',
      );
      tester.platformDispatcher.textScaleFactorTestValue = 3.2;
      await harness.pumpUntil(
        () =>
            MediaQuery.textScalerOf(
              tester.element(find.byType(MessageComposer)),
            ).scale(1) >
            3,
        reason: 'large text scale did not reach the composer',
      );
      journalAppBar = tester.widget<SliverAppBar>(find.byType(SliverAppBar));
      expect(journalAppBar.collapsedHeight, 64);
      expect(journalAppBar.toolbarHeight, 56);
      expect(journalAppBar.expandedHeight, 64);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      expect(
        tester.getBottomRight(find.byType(MessageComposer)).dy,
        lessThanOrEqualTo(844 - 320),
      );
      tester.view.resetViewInsets();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));

      const stagedDraft = '  Capture 中文 👩🏽‍💻 literal-token  ';
      await tester.enterText(find.byType(TextField), stagedDraft);
      await tester.pump();
      _expectMaterialGlyph(
        find.byTooltip('Capture as task, off'),
        Icons.timelapse,
        role: 'unchecked Capture task action',
      );
      await tester.tap(find.byTooltip('Capture as task, off'));
      await harness.pumpUntil(
        () => find.byTooltip('Capture as task, on').evaluate().isNotEmpty,
        reason: 'Capture task action did not become checked',
      );
      _expectMaterialGlyph(
        find.byTooltip('Capture as task, on'),
        Icons.timelapse,
        role: 'checked Capture task action',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        stagedDraft,
        reason: 'task selection changed the exact Capture draft',
      );
      _expectMaterialGlyph(
        find.byTooltip('Save journal block'),
        Icons.arrow_upward,
        role: 'Capture submit',
      );
      expect(find.byType(FloatingActionButton), findsNothing);
      await tester.drag(find.byType(MessageComposer), const Offset(0, 80));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pump(const Duration(milliseconds: 220));
      expect(
        find.byType(FloatingActionButton),
        findsOneWidget,
        reason: 'downward swipe did not restore the Capture FAB',
      );
      expect(find.byType(MessageComposer), findsNothing);
      await tester.tap(find.byType(FloatingActionButton));
      await harness.pumpUntil(
        () =>
            find.byType(TextField).evaluate().isNotEmpty &&
            tester.widget<TextField>(find.byType(TextField)).controller!.text ==
                stagedDraft,
        reason: 'Capture draft was not restored after re-expansion',
      );
      expect(
        find.byTooltip('Capture as task, on'),
        findsOneWidget,
        reason: 'Capture task intent was not restored after re-expansion',
      );
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '   \n');
      await tester.pump();
      expect(find.byTooltip('Save journal block'), findsNothing);
      await tester.enterText(find.byType(TextField), stagedDraft);
      await tester.pump();
      await tester.drag(find.byType(MessageComposer), const Offset(0, 80));
      await tester.pump(const Duration(milliseconds: 440));
      await harness.pumpUntil(
        () => find.text(_parentSource).evaluate().isNotEmpty,
        reason: 'parent row was unavailable for explicit Delete activation',
      );
      await tester.drag(find.text(_parentSource), const Offset(-80, 0));
      await _pumpSlidableMotion(tester);
      final explicitDelete = find.descendant(
        of: find.ancestor(
          of: find.text(_parentSource),
          matching: find.byType(fs.Slidable),
        ),
        matching: find.text('Delete'),
      );
      await tester.tap(explicitDelete.hitTestable());
      await harness.pumpUntil(
        () =>
            find.text(_parentSource).evaluate().isEmpty &&
            find.text('Block and descendants removed').evaluate().isNotEmpty,
        reason: 'explicit Delete action did not remove the parent row',
      );
      expect(find.text('Block and descendants removed'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Undo'));
      await harness.pumpUntil(
        () =>
            find.text(_parentSource).evaluate().isNotEmpty &&
            find.text('Block and descendants removed').evaluate().isEmpty,
        reason: 'Undo did not restore the explicitly deleted parent row',
      );
      await harness.dispose();
    },
    skip: Platform.environment['RUN_REAL_OCAML_GOLDEN'] != '1',
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'real runtime uses one centered status button with exact category colors',
    (tester) async {
      final harness = await _RuntimeHarness.start(
        tester,
        brightness: _runtimeBrightness,
        highContrast: _runtimeHighContrast,
      );
      final row = find.text(_parentSource);
      final slidable = find.ancestor(
        of: row,
        matching: find.byType(fs.Slidable),
      );
      final controller = fs.Slidable.of(tester.element(row))!;

      await tester.drag(row, const Offset(390, 0));
      await _pumpSlidableMotion(tester);
      expect(controller.ratio, closeTo(0.25, 0.01));
      final statusActions = tester
          .widgetList<fs.CustomSlidableAction>(
            find.descendant(
              of: slidable,
              matching: find.byType(fs.CustomSlidableAction),
            ),
          )
          .toList();
      expect(statusActions, hasLength(1));
      _expectStatusButtonColors(
        tester,
        slidable,
        brightness: _runtimeBrightness,
        currentStatus: 'No status',
      );
      for (final action in statusActions) {
        expect(action.borderRadius, BorderRadius.zero);
        expect(action.padding, isNull);
        expect(action.alignment, isNull);
      }
      _expectActionContentCentered(tester, slidable, 'No status');
      _expectStatusActionVerticallyStackedAndComplete(
        tester,
        slidable,
        'No status',
      );

      await tester.tap(
        find.descendant(of: slidable, matching: find.text('No status')),
      );
      await harness.pumpUntil(
        () => find.text('Set status').evaluate().isNotEmpty,
        reason: 'status sheet did not open before category color coverage',
      );
      await tester.pump(const Duration(milliseconds: 220));
      _expectStatusSheetIconOnlyColors(tester, brightness: _runtimeBrightness);
      await tester.tap(find.text('In review'));
      await harness.pumpUntil(
        () =>
            find.text('Set status').evaluate().isEmpty &&
            find
                .bySemanticsLabel(RegExp('$_parentSource.*status In review'))
                .evaluate()
                .isNotEmpty,
        reason:
            'In review did not reconcile before Delete presentation coverage',
      );
      await tester.pump(const Duration(milliseconds: 220));
      await _pumpSlidableMotion(tester);
      expect(controller.ratio, closeTo(0, 0.01));
      final reopenStatus = controller.openStartActionPane();
      await _pumpSlidableMotion(tester);
      await reopenStatus;
      _expectStatusActionVerticallyStackedAndComplete(
        tester,
        slidable,
        'In review',
      );
      final closeStatus = controller.close();
      await _pumpSlidableMotion(tester);
      await closeStatus;

      final deleteGesture = await tester.startGesture(tester.getCenter(row));
      await deleteGesture.moveBy(
        const Offset(-80, 0),
        timeStamp: const Duration(milliseconds: 500),
      );
      await tester.pump();
      _expectActionContentCentered(tester, slidable, 'Delete');
      if (_writesReferenceGoldens) {
        await expectLater(
          find.byType(Scaffold).first,
          matchesGoldenFile('goldens/journal-slidable-open-status-flow.png'),
        );
      }
      await deleteGesture.up(timeStamp: const Duration(milliseconds: 600));
      await _pumpSlidableMotion(tester);
      await harness.dispose();
    },
    skip: Platform.environment['RUN_REAL_OCAML_GOLDEN'] != '1',
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

Future<void> _dispatchScrollUpdate(
  WidgetTester tester,
  Finder scrollable,
  double delta,
) async {
  await tester.pump();
  final state = tester.state<ScrollableState>(scrollable);
  ScrollUpdateNotification(
    metrics: state.position,
    context: tester.element(scrollable),
    scrollDelta: delta,
  ).dispatch(tester.element(scrollable));
}

Future<void> _pumpSlidableMotion(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

void _expectTimelineStartsBelowHeader(WidgetTester tester) {
  const topInset = 47.0;
  final appBar = find.byType(SliverAppBar);
  final paintBoundary =
      tester.getRect(find.byType(CustomScrollView)).top +
      _sliverPaintExtent(tester, appBar);
  expect(
    tester.getRect(find.text('Today · Wed, Aug 12').first).top,
    greaterThanOrEqualTo(topInset),
  );
  expect(
    tester.getRect(find.bySemanticsLabel('Account menu')).top,
    greaterThanOrEqualTo(topInset),
  );
  expect(find.text('Today · Wed, Aug 12').hitTestable(), findsOneWidget);
  expect(
    tester.getRect(find.text(_parentSource)).top,
    greaterThanOrEqualTo(paintBoundary - 0.5),
    reason: 'the first timeline slot paints underneath the expanded app bar',
  );
}

double _sliverPaintExtent(WidgetTester tester, Finder finder) {
  final renderSliver = tester.renderObject<RenderSliver>(finder);
  return renderSliver.geometry!.paintExtent;
}

void _expectMaterialGlyph(
  Finder scope,
  IconData expected, {
  required String role,
}) {
  final glyphs = find.descendant(
    of: scope,
    matching: find.byWidgetPredicate(
      (widget) => widget is Text && widget.style?.fontFamily == 'MaterialIcons',
    ),
  );
  expect(glyphs, findsOneWidget, reason: '$role has no Material glyph');
  final text = (glyphs.evaluate().single.widget as Text).data;
  expect(text, isNotNull, reason: '$role has no glyph character');
  expect(
    text!.runes.single,
    expected.codePoint,
    reason: '$role does not render ${expected.codePoint.toRadixString(16)}',
  );
}

Future<void> _expectLastRowAboveCaptureBar(
  WidgetTester tester,
  _RuntimeHarness harness,
) async {
  final timelineScroll = find
      .ancestor(of: find.text('Todo rail'), matching: find.byType(Scrollable))
      .last;
  await tester.drag(timelineScroll, const Offset(0, -4000));
  await harness.pumpUntil(
    () => find.text('Todo rail').evaluate().isNotEmpty,
    reason: 'the final journal row was not retained at the end of the timeline',
  );
  await tester.pump(const Duration(milliseconds: 220));
  final row = tester.getRect(find.text('Todo rail'));
  final captureBar = tester.getRect(find.byType(FloatingActionButton));
  expect(
    row.bottom,
    lessThanOrEqualTo(captureBar.top + 0.5),
    reason: 'the final journal row is obscured by the Capture FAB',
  );
}

final class _RuntimeHarness {
  _RuntimeHarness({
    required this.tester,
    required this.runtime,
    required this.auth,
    required this.platform,
    required this.frameEligibility,
    required this.root,
    required this.removeRoot,
  });

  final WidgetTester tester;
  final RuntimeClient runtime;
  final _TestAuth auth;
  final JournalApplicationPlatform platform;
  final _ControllableFrameEligibilitySource frameEligibility;
  final Directory root;
  final bool removeRoot;
  bool _disposed = false;

  static Future<_RuntimeHarness> start(
    WidgetTester tester, {
    double devicePixelRatio = 1,
    Brightness brightness = Brightness.light,
    bool highContrast = false,
    String typographyPreset = 'balanced',
    bool reconcileAuthenticatedUser = false,
  }) async {
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(highContrast: highContrast);
    tester.view.devicePixelRatio = devicePixelRatio;
    tester.view.physicalSize = Size(
      390 * devicePixelRatio,
      844 * devicePixelRatio,
    );
    tester.view.padding = FakeViewPadding(
      top: 47 * devicePixelRatio,
      bottom: 34 * devicePixelRatio,
    );
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.runAsync(_loadGoldenFonts);

    final configuredRoot = Platform.environment['JOURNAL_GOLDEN_SUPPORT_ROOT'];
    final root = configuredRoot == null
        ? (await tester.runAsync(
            () => Directory.systemTemp.createTemp('journal-golden-'),
          ))!
        : Directory(configuredRoot);
    late final String userId;
    late final String baseUrl;
    if (configuredRoot == null) {
      final fixture = (await tester.runAsync(
        () => Process.run(
          '../_build/default/test/journal_runtime_golden_fixture.exe',
          [root.path],
        ),
      ))!;
      expect(
        fixture.exitCode,
        0,
        reason: '${fixture.stdout}\n${fixture.stderr}',
      );
      final generated =
          jsonDecode((fixture.stdout as String).trim()) as Map<String, dynamic>;
      userId = generated['userId']! as String;
      baseUrl = generated['baseUrl']! as String;
    } else {
      userId =
          Platform.environment['JOURNAL_GOLDEN_USER_ID'] ??
          (throw StateError(
            'JOURNAL_GOLDEN_USER_ID is required with '
            'JOURNAL_GOLDEN_SUPPORT_ROOT',
          ));
      baseUrl =
          Platform.environment['JOURNAL_GOLDEN_BASE_URL'] ??
          'https://api.logseq.io';
    }

    var generation = 7;
    Future<JournalCalendarSnapshot> calendar() async => JournalCalendarSnapshot(
      instantUnixMilliseconds: 1786563420000,
      localDay: 20260812,
      locale: 'en_US',
      timeZoneId: 'Europe/Paris',
      utcOffsetSeconds: 7200,
      generation: generation++,
    );
    final initialSnapshot = await calendar();
    final payload = _managedApplicationPayload(root.path, baseUrl);
    final config = RuntimeBootstrapConfig(
      entrypoint: 'logseq_journal',
      launchPolicy: RuntimeLaunchPolicy.replaceExisting,
      applicationPayload: payload,
    ).encode();
    final runtime = (await tester.runAsync(
      () => RuntimeClient.start(
        config: config,
      ).timeout(const Duration(seconds: 15)),
    ))!;
    final frameEligibility = _ControllableFrameEligibilitySource();
    final auth = _TestAuth(
      authenticatedUserId: reconcileAuthenticatedUser ? userId : null,
    );
    final platform = JournalApplicationPlatform(
      calendarSnapshot: calendar,
      initialSnapshot: Future.value(initialSnapshot),
      formatJournalDays: ({required snapshot, required days}) async => {
        for (final day in days) day: day == 20260812 ? 'Wed, Aug 12' : '$day',
      },
      auth: auth,
      managedSyncOrigin: baseUrl,
      readLocalAccountBinding: () async =>
          (userId: userId, managedSyncOrigin: baseUrl),
      readPreference: (_) async => typographyPreset,
      writePreference: (_, _) async {},
    );
    await tester.pumpWidget(
      fs.SlidableAutoCloseBehavior(
        closeWhenOpened: true,
        closeWhenTapped: true,
        child: BonsaiFlutterRoot(
          config: config,
          runtimeStarter: (_) async => runtime,
          applicationPlatform: platform,
          frameEligibilitySource: frameEligibility,
          registry: createJournalWidgetRegistry(),
        ),
      ),
    );
    final harness = _RuntimeHarness(
      tester: tester,
      runtime: runtime,
      auth: auth,
      platform: platform,
      frameEligibility: frameEligibility,
      root: root,
      removeRoot: configuredRoot == null,
    );
    addTearDown(harness.dispose);
    await harness.pumpUntil(
      () =>
          find.text('Today').evaluate().isNotEmpty &&
          find.text('Wed, Aug 12').evaluate().isNotEmpty &&
          find.text(_parentSource).evaluate().isNotEmpty &&
          find.text('Capture interaction notes').evaluate().isNotEmpty,
      reason: 'the real runtime did not publish the approved fixture',
    );
    return harness;
  }

  Future<void> pumpUntil(
    bool Function() predicate, {
    required String reason,
  }) async {
    final stopwatch = Stopwatch()..start();
    while (!predicate() && stopwatch.elapsed < const Duration(seconds: 15)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
      final exception = tester.takeException();
      if (exception != null) {
        fail('$reason; renderer exception: $exception');
      }
    }
    if (!predicate()) {
      final mountedText = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data)
          .whereType<String>()
          .toList();
      final runtimeState = await tester.runAsync(runtime.debugSnapshot);
      fail(
        '$reason; mounted text: $mountedText; runtime: '
        'state=${runtimeState?.state} generation=${runtimeState?.liveGeneration} '
        'eligible=${runtimeState?.eligible} grant=${runtimeState?.hasCoalescedGrant} '
        'presentation=${runtimeState?.unresolvedPresentationId} '
        'revision=${runtimeState?.unresolvedRevision} pumps=${runtimeState?.pumpCount}',
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    auth.rejectPendingAuthentication();
    var terminationCompleted = false;
    final termination = platform.prepareForTermination().whenComplete(() {
      terminationCompleted = true;
    });
    final terminationWatch = Stopwatch()..start();
    while (!terminationCompleted &&
        terminationWatch.elapsed < const Duration(seconds: 5)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    await termination;
    var settled = await tester.runAsync(runtime.debugSnapshot);
    for (
      var attempt = 0;
      attempt < 8 && settled?.state == RuntimeWorkerState.awaitingPresentation;
      attempt += 1
    ) {
      runtime.presentationSucceeded(
        generation: settled!.liveGeneration,
        presentationId: settled.unresolvedPresentationId!,
        revision: settled.unresolvedRevision!,
        eventBatch: Uint8List(0),
      );
      settled = await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return runtime.debugSnapshot();
      });
    }
    frameEligibility.setEligible(false);
    await tester.runAsync(
      () => runtime.dispose().timeout(const Duration(seconds: 5)),
    );
    platform.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    if (removeRoot) {
      try {
        root.deleteSync(recursive: true);
      } on PathNotFoundException {
        // Runtime shutdown may remove the support root before test cleanup.
      }
    }
  }
}

Uint8List _managedApplicationPayload(String supportRoot, String baseUrl) {
  final json = utf8.encode(
    jsonEncode(<String, Object>{
      'applicationSupportDirectory': supportRoot,
      'target': <String, Object>{'kind': 'managedSync', 'baseUrl': baseUrl},
      'compatibilityProfile': 'logseq-65.33-or-newer',
      'responseBudgetBytes': 262144,
      'defaultPageSize': 50,
    }),
  );
  final payload = Uint8List(8 + json.length);
  payload.setRange(0, 4, ascii.encode('LDB1'));
  ByteData.sublistView(payload).setUint32(4, json.length, Endian.little);
  payload.setRange(8, payload.length, json);
  return payload;
}

Rect _ancestorRectWithHeight(WidgetTester tester, Finder child, double height) {
  final candidates = find.ancestor(
    of: child,
    matching: find.byWidgetPredicate((widget) => widget is SizedBox),
  );
  final candidateRects = <Rect>[];
  for (final element in candidates.evaluate()) {
    final finder = find.byElementPredicate((candidate) => candidate == element);
    final rect = tester.getRect(finder);
    candidateRects.add(rect);
    if ((rect.height - height).abs() < 0.1 && rect.width > 300) return rect;
  }
  throw TestFailure(
    'no $height-point row ancestor was found; candidates: $candidateRects',
  );
}

void _expectActionContentCentered(
  WidgetTester tester,
  Finder slidable,
  String label,
) {
  final actionLabel = find.descendant(of: slidable, matching: find.text(label));
  final action = find.ancestor(
    of: actionLabel,
    matching: find.byType(fs.CustomSlidableAction),
  );
  final content = find.descendant(of: action, matching: find.byType(Text));
  expect(
    content,
    findsNWidgets(2),
    reason: '$label action does not contain exactly one icon and one label',
  );
  final actionCenter = tester.getCenter(action);
  final contentRect = _combinedRect(tester, content);
  final contentCenter = contentRect.center;
  expect(
    contentCenter.dx,
    closeTo(actionCenter.dx, 0.1),
    reason: '$label content is not horizontally centered',
  );
  expect(
    contentCenter.dy,
    closeTo(actionCenter.dy, 0.1),
    reason:
        '$label content $contentRect is not vertically centered in the action at $actionCenter',
  );
}

void _expectStatusActionVerticallyStackedAndComplete(
  WidgetTester tester,
  Finder slidable,
  String label,
) {
  final actionLabel = find.descendant(of: slidable, matching: find.text(label));
  final action = find.ancestor(
    of: actionLabel,
    matching: find.byType(fs.CustomSlidableAction),
  );
  final textElements = find
      .descendant(of: action, matching: find.byType(Text))
      .evaluate()
      .toList();
  expect(textElements, hasLength(2));
  final labelElement = actionLabel.evaluate().single;
  final iconElement = textElements.singleWhere(
    (element) => !identical(element, labelElement),
  );
  final icon = find.byElementPredicate(
    (element) => identical(element, iconElement),
  );
  final iconRect = tester.getRect(icon);
  final labelRect = tester.getRect(actionLabel);
  final actionRect = tester.getRect(action);
  expect(
    iconRect.bottom,
    lessThanOrEqualTo(labelRect.top),
    reason: '$label icon is not above its label',
  );
  expect(iconRect.center.dx, closeTo(actionRect.center.dx, 0.1));
  expect(labelRect.center.dx, closeTo(actionRect.center.dx, 0.1));
  final labelWidget = tester.widget<Text>(actionLabel);
  expect(
    labelWidget.overflow,
    isNot(TextOverflow.ellipsis),
    reason: '$label still permits ellipsis',
  );
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: actionLabel, matching: find.byType(RichText)),
  );
  expect(
    paragraph.didExceedMaxLines,
    isFalse,
    reason: '$label does not fit completely in the status action',
  );
}

void _expectStatusSheetIconOnlyColors(
  WidgetTester tester, {
  required Brightness brightness,
}) {
  final iconColors = brightness == Brightness.light
      ? _lightStatusCategoryBackgrounds
      : _darkStatusCategoryBackgrounds;
  final noStatusForeground = brightness == Brightness.light
      ? const Color(0xff00262f)
      : const Color(0xffa7b8bc);
  final rows = <(String, Color)>[
    ('Backlog', iconColors[3]),
    ('Todo', iconColors[0]),
    ('Doing', iconColors[1]),
    ('In review', iconColors[1]),
    ('Done', iconColors[2]),
    ('Canceled', iconColors[2]),
    ('Clear', noStatusForeground),
  ];
  for (final (label, expectedIconColor) in rows) {
    final labelFinder = find.text(label);
    final coloredRows = find
        .ancestor(
          of: labelFinder,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox && widget.decoration is BoxDecoration,
          ),
        )
        .evaluate()
        .where((element) {
          final rect = tester.getRect(
            find.byElementPredicate(
              (candidate) => identical(candidate, element),
            ),
          );
          return rect.width > 300 && rect.height >= 44 && rect.height < 80;
        })
        .toList();
    expect(
      coloredRows,
      isEmpty,
      reason: '$label still has a full-width status background',
    );
    final rowCandidates = find
        .ancestor(of: labelFinder, matching: find.byType(Row))
        .evaluate()
        .where((element) {
          final rect = tester.getRect(
            find.byElementPredicate(
              (candidate) => identical(candidate, element),
            ),
          );
          return rect.width > 300 && rect.height >= 44 && rect.height < 80;
        })
        .toList();
    expect(rowCandidates, hasLength(1));
    final row = find.byElementPredicate(
      (element) => identical(element, rowCandidates.single),
    );
    final texts = tester
        .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
        .toList();
    expect(texts, hasLength(2));
    final labelText = texts.singleWhere((text) => text.data == label);
    final iconText = texts.singleWhere((text) => text.data != label);
    expect(labelText.style?.color, isNull);
    expect(iconText.style?.color, expectedIconColor);
  }
}

Rect _combinedRect(WidgetTester tester, Finder finder) {
  final elements = finder.evaluate().toList();
  if (elements.isEmpty) throw TestFailure('cannot combine an empty finder');
  return elements
      .map(
        (element) => tester.getRect(
          find.byElementPredicate((candidate) => identical(candidate, element)),
        ),
      )
      .reduce((combined, rect) => combined.expandToInclude(rect));
}

List<Rect> _timelineDividers(
  WidgetTester tester, {
  required double devicePixelRatio,
}) {
  final expectedHeight = 1 / devicePixelRatio;
  return find
      .byType(Divider)
      .evaluate()
      .map(
        (element) =>
            tester.getRect(find.byElementPredicate((e) => e == element)),
      )
      .where(
        (rect) =>
            rect.width > 300 && (rect.height - expectedHeight).abs() < 0.08,
      )
      .toList();
}

Finder _directChildText(String source) => find.descendant(
  of: find.bySemanticsLabel(RegExp('^Direct child: ${RegExp.escape(source)}')),
  matching: find.text(source),
);

void _expectSeedOwnedSemanticColors(
  WidgetTester tester, {
  required Brightness brightness,
  required bool highContrast,
}) {
  final context = tester.element(find.text('Today'));
  final scheme = Theme.of(context).colorScheme;
  final expected = ColorScheme.fromSeed(
    seedColor: const Color(0xff00262f),
    brightness: brightness,
    contrastLevel: highContrast ? 1 : 0,
  );
  expect(scheme.brightness, brightness);
  expect(scheme.primary, expected.primary);
  expect(scheme.surface, expected.surface);
  expect(scheme.onSurface, expected.onSurface);
  expect(scheme.error, expected.error);
  expect(tester.widget<Text>(find.text('Today')).style?.color, isNull);
  expect(tester.widget<Text>(find.text('Wed, Aug 12')).style?.color, isNull);
  final railColors = _statusRailColors(tester);
  expect(railColors, hasLength(4));
  expect(railColors.toSet(), hasLength(4));
  final expectedBackgrounds = brightness == Brightness.light
      ? _lightStatusCategoryBackgrounds
      : _darkStatusCategoryBackgrounds;
  expect(
    railColors.toSet(),
    expectedBackgrounds.toSet(),
    reason: 'status rails do not use the brightness-specific semantic colors',
  );
  for (final color in railColors) {
    expect(_contrastRatio(color, scheme.surface), greaterThanOrEqualTo(3));
  }
  for (final element in find.byType(fs.CustomSlidableAction).evaluate()) {
    final action = element.widget as fs.CustomSlidableAction;
    if (action.backgroundColor.a == 0) {
      expect(action.foregroundColor, isNotNull);
      expect(
        _contrastRatio(action.foregroundColor!, scheme.surface),
        greaterThanOrEqualTo(4.5),
      );
      continue;
    }
    expect(
      _contrastRatio(action.backgroundColor, scheme.surface),
      greaterThanOrEqualTo(3),
    );
    expect(action.foregroundColor, isNotNull);
    expect(
      _contrastRatio(action.foregroundColor!, action.backgroundColor),
      greaterThanOrEqualTo(4.5),
    );
  }
}

void _expectStatusButtonColors(
  WidgetTester tester,
  Finder slidable, {
  required Brightness brightness,
  required String currentStatus,
}) {
  final expectedBackgrounds = brightness == Brightness.light
      ? _lightStatusCategoryBackgrounds
      : _darkStatusCategoryBackgrounds;
  final expectedForegrounds = brightness == Brightness.light
      ? _lightStatusCategoryForegrounds
      : _darkStatusCategoryForegrounds;
  final categoryIndex = switch (currentStatus) {
    'Todo' => 0,
    'Doing' || 'In review' || 'Now' => 1,
    'Done' || 'Canceled' => 2,
    'Backlog' || 'Waiting' || 'Later' => 3,
    'No status' => null,
    _ => throw TestFailure('unknown exact status $currentStatus'),
  };
  final action = tester.widget<fs.CustomSlidableAction>(
    find.ancestor(
      of: find.descendant(of: slidable, matching: find.text(currentStatus)),
      matching: find.byType(fs.CustomSlidableAction),
    ),
  );
  expect(
    action.backgroundColor,
    categoryIndex == null
        ? Colors.transparent
        : expectedBackgrounds[categoryIndex],
    reason: '$currentStatus background does not match $brightness',
  );
  expect(
    action.foregroundColor,
    categoryIndex == null
        ? brightness == Brightness.light
              ? const Color(0xff00262f)
              : const Color(0xffa7b8bc)
        : expectedForegrounds[categoryIndex],
    reason: '$currentStatus foreground does not match $brightness',
  );
}

List<Color> _statusRailColors(WidgetTester tester) => find
    .byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).borderRadius ==
              BorderRadius.circular(2),
    )
    .evaluate()
    .where((element) {
      final rect = tester.getRect(find.byElementPredicate((e) => e == element));
      return (rect.width - 4).abs() < 0.1;
    })
    .map(
      (element) =>
          ((element.widget as DecoratedBox).decoration as BoxDecoration).color!,
    )
    .toList();

double _contrastRatio(Color left, Color right) {
  final lighter = left.computeLuminance() > right.computeLuminance()
      ? left
      : right;
  final darker = identical(lighter, left) ? right : left;
  return (lighter.computeLuminance() + 0.05) /
      (darker.computeLuminance() + 0.05);
}

Future<void> _loadGoldenFonts() async {
  final materialFonts = _findMaterialFontsDirectory();
  Future<ByteData> load(String name) async => ByteData.sublistView(
    await File('${materialFonts.path}/$name').readAsBytes(),
  );
  await (FontLoader('Roboto')..addFont(load('Roboto-Regular.ttf'))).load();
  // FontLoader cannot select a face from the system PingFang TTC collection.
  // Register one deterministic mixed-script test face under the production
  // family name; protocol assertions separately verify the published chain.
  await (FontLoader('PingFang SC')..addFont(
        File(
          '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
        ).readAsBytes().then(ByteData.sublistView),
      ))
      .load();
  await (FontLoader('Apple Color Emoji')..addFont(
        File(
          '/System/Library/Fonts/Apple Color Emoji.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      ))
      .load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(load('MaterialIcons-Regular.otf'))).load();
}

Directory _findMaterialFontsDirectory() {
  var directory = File(Platform.resolvedExecutable).parent;
  for (var depth = 0; depth < 8; depth += 1) {
    final candidate = Directory(
      '${directory.path}/bin/cache/artifacts/material_fonts',
    );
    if (candidate.existsSync()) return candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError('Flutter SDK material fonts directory is unavailable');
}

final class _ControllableFrameEligibilitySource
    implements FrameEligibilitySource {
  bool _eligible = true;
  void Function(bool)? _onChanged;

  @override
  bool get isEligible => _eligible;

  @override
  void start(void Function(bool isEligible) onChanged) {
    _onChanged = onChanged;
  }

  void setEligible(bool eligible) {
    if (_eligible == eligible) return;
    _eligible = eligible;
    _onChanged?.call(eligible);
  }

  @override
  void dispose() {
    _onChanged = null;
  }
}
