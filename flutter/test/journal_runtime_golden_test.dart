import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bonsai_flutter/bonsai_flutter.dart';
// ignore: implementation_imports
import 'package:bonsai_flutter/src/runtime/foreground_frame_loop.dart';
// ignore: implementation_imports
import 'package:bonsai_flutter/src/renderer/pressable_host.dart';
import 'package:bonsai_flutter_logseq_journal_host/application_host_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_slidable/flutter_slidable.dart' as fs;
import 'package:flutter_test/flutter_test.dart';

const _parentSource = '混合脚本 Journal 2026 条目';
const _firstChild = 'Increase block row height';
const _secondChild = 'Show parent and child preview';
const _thirdChild = 'Keep bounded virtualization';

final _runtimeBrightness =
    Platform.environment['JOURNAL_GOLDEN_BRIGHTNESS'] == 'dark'
    ? Brightness.dark
    : Brightness.light;
final _runtimeHighContrast =
    Platform.environment['JOURNAL_GOLDEN_HIGH_CONTRAST'] == '1';
final _writesReferenceGoldens =
    _runtimeBrightness == Brightness.light && !_runtimeHighContrast;

final class _TestAuth implements JournalAuthCapability {
  @override
  Future<String?> currentUserId() async => null;

  @override
  Future<String> freshIdToken() async => throw StateError('unused');

  @override
  Future<void> signOut() async => throw StateError('unused');
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
          closeTo(56 + 47 + 1, 0.5),
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
        await tester.tap(find.text('Settings').last);
        await harness.pumpUntil(
          () => find.text(label).evaluate().isNotEmpty,
          reason: 'the typography choice group did not open',
        );
        await tester.tap(find.text(label));
        await harness.pumpUntil(() {
          final chip = find.ancestor(
            of: find.text(label),
            matching: find.byType(ChoiceChip),
          );
          return chip.evaluate().isNotEmpty &&
              tester.widget<ChoiceChip>(chip).selected;
        }, reason: 'the $storedValue preset did not become selected');
        await tester.tap(find.text('Close'));
        await harness.pumpUntil(
          () => find.byType(ChoiceChip).evaluate().isEmpty,
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
        tester.getCenter(find.text('Doing line one')),
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
        tester.getCenter(find.text('Doing line one')),
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
      var journalAppBar = tester.widget<SliverAppBar>(
        find.byType(SliverAppBar),
      );
      expect(journalAppBar.pinned, isTrue);
      expect(journalAppBar.floating, isFalse);
      expect(journalAppBar.snap, isFalse);
      expect(journalAppBar.stretch, isFalse);
      expect(journalAppBar.automaticallyImplyLeading, isFalse);
      expect(journalAppBar.centerTitle, isTrue);
      expect(journalAppBar.expandedHeight, 97);
      expect(journalAppBar.collapsedHeight, 57);
      expect(journalAppBar.toolbarHeight, 56);
      expect(journalAppBar.elevation, 0);
      expect(journalAppBar.backgroundColor, isNull);
      expect(journalAppBar.foregroundColor, isNull);
      expect(journalAppBar.leading, isNotNull);
      expect(journalAppBar.flexibleSpace, isNotNull);
      expect(journalAppBar.bottom, isNull);
      expect(journalAppBar.actions, isNotEmpty);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Wed, Aug 12'), findsOneWidget);
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
        closeTo(96 + 47 + 1, 0.5),
      );
      final journalScroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        ),
      );
      journalScroll.position.jumpTo(80);
      await tester.pump();
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Wed, Aug 12').hitTestable(), findsNothing);
      expect(
        _sliverPaintExtent(tester, find.byType(SliverAppBar)),
        closeTo(56 + 47 + 1, 0.5),
      );
      journalScroll.position.jumpTo(0);
      await tester.pump();
      expect(find.text('Wed, Aug 12').hitTestable(), findsOneWidget);
      expect(find.text(_parentSource), findsOneWidget);
      expect(find.text(_firstChild), findsOneWidget);
      expect(find.text('21:37'), findsOneWidget);
      for (final line in const [
        'Todo rail',
        'Doing line one',
        'Doing line two',
        'Done line one',
        'Done line two',
        'Done line three',
        'Later line one',
        'Later line two',
        'Later line three',
        'Later line four',
      ]) {
        expect(find.text(line), findsOneWidget);
      }
      expect(find.text('Later line five'), findsNothing);
      for (final status in const ['Todo', 'Doing', 'Done', 'Backlog']) {
        expect(find.bySemanticsLabel(RegExp('status $status')), findsOneWidget);
      }
      _expectSeedOwnedSemanticColors(
        tester,
        brightness: _runtimeBrightness,
        highContrast: _runtimeHighContrast,
      );
      expect(
        find.bySemanticsLabel(
          '$_parentSource, $_firstChild, $_secondChild, $_thirdChild, created at 21:37',
        ),
        findsOneWidget,
      );

      final rowRect = _ancestorRectWithHeight(
        tester,
        find.text(_parentSource),
        100,
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
          '$_parentSource, $_firstChild, $_secondChild, $_thirdChild, created at 21:37',
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
      expect(firstChildTop - parentTop, closeTo(38, 0.1));
      expect(secondChildTop - firstChildTop, closeTo(44, 0.1));
      expect(
        tester.getTopLeft(find.text(_parentSource)).dy,
        closeTo(collapsedParentTop, 0.1),
      );
      expect(
        find.bySemanticsLabel('$_parentSource, created at 21:37'),
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

      final swipeGesture = await tester.startGesture(
        tester.getCenter(find.text(_parentSource)),
      );
      await swipeGesture.moveBy(
        const Offset(-80, 0),
        timeStamp: const Duration(milliseconds: 500),
      );
      await tester.pump();
      final parentSlidable = find.ancestor(
        of: find.text(_parentSource),
        matching: find.byType(fs.Slidable),
      );
      final parentDelete = find.descendant(
        of: parentSlidable,
        matching: find.text('Delete'),
      );
      expect(parentDelete, findsOneWidget);
      final deleteAction = tester.widget<fs.CustomSlidableAction>(
        find.descendant(
          of: parentSlidable,
          matching: find.byType(fs.CustomSlidableAction),
        ),
      );
      expect(deleteAction.borderRadius, BorderRadius.zero);
      final deleteActionFinder = find.descendant(
        of: parentSlidable,
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

      final parentController = fs.Slidable.of(
        tester.element(find.text(_parentSource)),
      )!;
      expect(parentController.ratio, closeTo(-0.25, 0.01));
      await tester.tapAt(tester.getCenter(find.text('Doing line one')));
      await _pumpSlidableMotion(tester);
      expect(parentController.ratio, closeTo(0, 0.01));

      await tester.drag(find.text(_parentSource), const Offset(-390, 0));
      await _pumpSlidableMotion(tester);
      expect(find.text(_parentSource), findsOneWidget);
      expect(parentController.ratio, closeTo(-0.25, 0.01));
      expect(find.text('Block and descendants removed'), findsNothing);

      final secondController = fs.Slidable.of(
        tester.element(find.text('Doing line one')),
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
      final shortestAction = find.descendant(
        of: find.ancestor(
          of: find.text('Todo rail'),
          matching: find.byType(fs.Slidable),
        ),
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
                3 &&
            tester
                    .widget<SliverAppBar>(find.byType(SliverAppBar))
                    .toolbarHeight >
                100,
        reason: 'large text scale did not reach the composer',
      );
      journalAppBar = tester.widget<SliverAppBar>(find.byType(SliverAppBar));
      expect(journalAppBar.collapsedHeight, closeTo(106.6, 0.1));
      expect(journalAppBar.toolbarHeight, closeTo(105.6, 0.1));
      expect(journalAppBar.expandedHeight, closeTo(178.6, 0.1));
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
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '   \n');
      await tester.pump();
      expect(find.byTooltip('Save journal block'), findsNothing);
      await tester.enterText(find.byType(TextField), stagedDraft);
      await tester.pump();
      await tester.tap(find.byTooltip('Save journal block'));
      await harness.pumpUntil(
        () =>
            find.byType(MessageComposer).evaluate().isEmpty &&
            find.text(stagedDraft).evaluate().isNotEmpty,
        reason: 'direct Capture did not persist and close after success',
      );
      expect(find.text('New block'), findsNothing);

      final timelineScroll = find
          .ancestor(
            of: find.text(stagedDraft),
            matching: find.byType(Scrollable),
          )
          .last;
      await tester.drag(timelineScroll, const Offset(0, 4000));
      await harness.pumpUntil(
        () => find.text(_parentSource).evaluate().isNotEmpty,
        reason: 'parent row did not return for explicit Delete activation',
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
    tester.getRect(find.text('Today')).top,
    greaterThanOrEqualTo(topInset),
  );
  expect(
    tester.getRect(find.bySemanticsLabel('Account menu')).top,
    greaterThanOrEqualTo(topInset),
  );
  expect(find.text('Wed, Aug 12').hitTestable(), findsOneWidget);
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
      .ancestor(
        of: find.text('Doing line one'),
        matching: find.byType(Scrollable),
      )
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
    required this.frameEligibility,
    required this.root,
    required this.removeRoot,
  });

  final WidgetTester tester;
  final RuntimeClient runtime;
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
    late final String snapshotToken;
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
      snapshotToken = (fixture.stdout as String).trim();
    } else {
      snapshotToken =
          Platform.environment['JOURNAL_GOLDEN_SNAPSHOT_TOKEN'] ??
          (throw StateError(
            'JOURNAL_GOLDEN_SNAPSHOT_TOKEN is required with '
            'JOURNAL_GOLDEN_SUPPORT_ROOT',
          ));
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
    final payload = _snapshotApplicationPayload(root.path, snapshotToken);
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
    final platform = JournalApplicationPlatform(
      calendarSnapshot: calendar,
      initialSnapshot: Future.value(initialSnapshot),
      formatJournalDays: ({required snapshot, required days}) async => {
        for (final day in days) day: day == 20260812 ? 'Wed, Aug 12' : '$day',
      },
      auth: _TestAuth(),
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
        ),
      ),
    );
    final harness = _RuntimeHarness(
      tester: tester,
      runtime: runtime,
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
    await tester.pumpWidget(const SizedBox.shrink());
    if (removeRoot) {
      try {
        root.deleteSync(recursive: true);
      } on PathNotFoundException {
        // Runtime shutdown may remove the support root before test cleanup.
      }
    }
  }
}

Uint8List _snapshotApplicationPayload(String supportRoot, String token) {
  final json = utf8.encode(
    jsonEncode(<String, Object>{
      'applicationSupportDirectory': supportRoot,
      'target': <String, Object>{'kind': 'snapshot', 'token': token},
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
  for (final element in candidates.evaluate()) {
    final finder = find.byElementPredicate((candidate) => candidate == element);
    final rect = tester.getRect(finder);
    if ((rect.height - height).abs() < 0.1 && rect.width > 300) return rect;
  }
  throw TestFailure('no $height-point row ancestor was found');
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
  for (final color in railColors) {
    expect(_contrastRatio(color, scheme.surface), greaterThanOrEqualTo(3));
  }
  for (final element in find.byType(fs.CustomSlidableAction).evaluate()) {
    final action = element.widget as fs.CustomSlidableAction;
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
