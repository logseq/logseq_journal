import 'dart:io';

import 'package:bonsai_flutter/bonsai_flutter.dart';
// ignore: implementation_imports
import 'package:bonsai_flutter/src/runtime/foreground_frame_loop.dart';
import 'package:bonsai_flutter_logseq_journal_host/application_host_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  if (binding is LiveTestWidgetsFlutterBinding) {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  }

  testWidgets(
    'real OCaml runtime renders the complete reduced journal milestone',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      await tester.runAsync(_loadGoldenFonts);

      final configuredRoot =
          Platform.environment['JOURNAL_GOLDEN_SUPPORT_ROOT'];
      final root = configuredRoot == null
          ? await tester.runAsync(
              () => Directory.systemTemp.createTemp('journal-golden-'),
            )
          : Directory(configuredRoot);
      expect(root, isNotNull);
      if (configuredRoot == null) {
        addTearDown(() => tester.runAsync(() => root!.delete(recursive: true)));
        final fixture = await tester.runAsync(
          () => Process.run(
            '../_build/default/test/journal_runtime_golden_fixture.exe',
            [root!.path],
          ),
        );
        expect(fixture, isNotNull);
        expect(
          fixture!.exitCode,
          0,
          reason: '${fixture.stdout}\n${fixture.stderr}',
        );
      }
      const taskSource = 'Timeline golden task';
      const longSource =
          'A deliberately long literal source with #plain-tag @plain-mention '
          'and no styled pills or attachment thumbnail';
      var generation = 7;
      Future<JournalCalendarSnapshot> calendar() async =>
          JournalCalendarSnapshot(
            instantUnixMilliseconds: 1786055400000,
            localDay: 20260807,
            locale: 'en_US',
            timeZoneId: 'Europe/Paris',
            utcOffsetSeconds: 7200,
            generation: generation++,
          );
      final initialSnapshot = await calendar();

      final adapter = ApplicationHostAdapter(
        applicationSupportDirectory: () async => root!,
        initialCalendarSnapshot: () async => initialSnapshot,
        liveCalendarSnapshot: calendar,
      );
      final applicationPayload = await tester.runAsync(
        adapter.createApplicationPayload,
      );
      expect(applicationPayload, isNotNull);
      final config = RuntimeBootstrapConfig(
        entrypoint: 'logseq_journal',
        launchPolicy: RuntimeLaunchPolicy.replaceExisting,
        applicationPayload: applicationPayload!,
      ).encode();
      final runtime = await tester.runAsync(
        () => RuntimeClient.start(
          config: config,
        ).timeout(const Duration(seconds: 15)),
      );
      expect(runtime, isNotNull);
      final frameEligibility = _ControllableFrameEligibilitySource();
      var disposed = false;
      Future<void> disposeHarness() async {
        if (disposed) return;
        disposed = true;
        var settled = await tester.runAsync(runtime!.debugSnapshot);
        for (
          var attempt = 0;
          attempt < 8 &&
              settled?.state == RuntimeWorkerState.awaitingPresentation;
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
        expect(settled?.state, RuntimeWorkerState.ready);
        frameEligibility.setEligible(false);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }

      addTearDown(disposeHarness);

      final boundaryKey = GlobalKey();
      const labels = <int, String>{
        20260807: 'Fri, Aug 7',
        20260806: 'Thu, Aug 6',
        20260805: 'Wed, Aug 5',
      };
      var formatCalls = 0;
      var formattedDays = const <int>[];
      final applicationPlatform = JournalApplicationPlatform(
        calendarSnapshot: calendar,
        initialSnapshot: Future.value(initialSnapshot),
        formatJournalDays: ({required snapshot, required days}) async {
          formatCalls += 1;
          formattedDays = List.of(days);
          return {for (final day in days) day: labels[day]!};
        },
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: 'Roboto',
              fontFamilyFallback: const ['Apple Color Emoji'],
            ),
            home: BonsaiFlutterRoot(
              config: config,
              runtimeStarter: (_) async => runtime!,
              applicationPlatform: applicationPlatform,
              frameEligibilitySource: frameEligibility,
            ),
          ),
        ),
      );

      final stopwatch = Stopwatch()..start();
      bool targetFrameIsVisible() =>
          find.text('Today').evaluate().isNotEmpty &&
          find.text('Fri, Aug 7').evaluate().isNotEmpty &&
          find.text(taskSource).evaluate().isNotEmpty &&
          find.text(longSource).evaluate().isNotEmpty &&
          find.text('Thu, Aug 6').evaluate().isNotEmpty;
      while (!targetFrameIsVisible() &&
          stopwatch.elapsed < const Duration(seconds: 15)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(
        targetFrameIsVisible(),
        isTrue,
        reason:
            'the real runtime did not publish the expected timeline frame:\n'
            'Today=${find.text('Today').evaluate().length} '
            'subtitle=${find.text('Fri, Aug 7').evaluate().length} '
            'task=${find.text(taskSource).evaluate().length} '
            'long=${find.text(longSource).evaluate().length} '
            'older=${find.text('Thu, Aug 6').evaluate().length} '
            'formatCalls=$formatCalls formattedDays=$formattedDays\n'
            '${tester.allWidgets.whereType<Text>().map((widget) => widget.data).whereType<String>().join(' | ')}',
      );

      final todayCount = find.text('Today').evaluate().length;
      final searchCount = find.textContaining('Search').evaluate().length;
      final todayCenter = todayCount == 1
          ? tester.getCenter(find.text('Today')).dx
          : double.nan;
      final rowText = tester.widget<Text>(find.text(longSource));
      final todayText = tester.widget<Text>(find.text('Today'));

      expect(todayCount, 1);
      expect(searchCount, 0);
      expect(todayCenter, closeTo(195, 2));
      expect(find.text('Fri, Aug 7'), findsOneWidget);
      expect(find.text('Thu, Aug 6'), findsOneWidget);
      expect(find.text('2026-08-07'), findsNothing);
      expect(find.text('2026-08-06'), findsNothing);
      final dateContext = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == 'Today, Fri, Aug 7',
        description: 'view-only localized date semantics',
      );
      expect(dateContext, findsOneWidget);
      final dateSemantics = tester.widget<Semantics>(dateContext);
      expect(dateSemantics.properties.onTap, isNull);
      expect(dateSemantics.properties.button, isFalse);
      expect(
        find.descendant(of: dateContext, matching: find.byType(Icon)),
        findsNothing,
      );
      expect(rowText.maxLines, 1);
      expect(rowText.overflow, TextOverflow.ellipsis);
      expect(rowText.style?.fontSize, 15);
      expect(rowText.style?.fontWeight, FontWeight.w400);
      expect(todayText.style?.fontSize, 22);
      expect(todayText.style?.fontWeight, FontWeight.w700);
      final subtitleText = tester.widget<Text>(find.text('Fri, Aug 7'));
      expect(subtitleText.style?.fontSize, 15);
      expect(subtitleText.style?.fontWeight, FontWeight.w500);
      expect(find.textContaining('#plain-tag'), findsOneWidget);
      expect(find.textContaining('Search'), findsNothing);
      expect(find.textContaining('Attachment'), findsNothing);
      expect(find.textContaining('Thumbnail'), findsNothing);
      expect(_materialGlyph(0xe3dc), findsOneWidget);
      expect(_materialGlyph(0xe402), findsOneWidget);
      expect(find.bySemanticsLabel('Menu'), findsNothing);
      expect(find.bySemanticsLabel('More'), findsNothing);
      expect(find.text('☰'), findsNothing);
      expect(find.text('•••'), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp('Mark as done: $taskSource')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('$taskSource, created at 09:01')),
        findsOneWidget,
      );
      final timeLeft = tester.getTopLeft(find.text('09:01')).dx;
      final timeRight = tester.getTopRight(find.text('09:01')).dx;
      final sourceLeft = tester.getTopLeft(find.text(taskSource)).dx;
      final plainSourceLeft = tester
          .getTopLeft(find.text('Mention-like source for @alex'))
          .dx;
      final timelineTop = tester.getTopLeft(find.byType(Scrollable).first).dy;
      final firstSourceTop = tester.getTopLeft(find.text(taskSource)).dy;
      expect(timeLeft, greaterThan(sourceLeft));
      expect(timeRight, closeTo(366, 3));
      expect(sourceLeft, closeTo(63, 2));
      expect(plainSourceLeft, closeTo(28, 2));
      expect(
        (tester.getCenter(find.text(taskSource)).dy -
                tester.getCenter(find.text('09:01')).dy)
            .abs(),
        lessThanOrEqualTo(1),
        reason: 'source and time must share one visual row center',
      );
      final disclosure = _materialGlyph(0xe15f);
      expect(disclosure, findsOneWidget);
      expect(
        tester.getTopLeft(disclosure).dx -
            tester.getTopRight(find.text(taskSource)).dx,
        inInclusiveRange(0, 12),
        reason: 'parent metadata must follow the visible source inline',
      );
      expect(
        tester.widget<Text>(_materialGlyph(0xe504).first).style?.fontSize,
        14,
      );
      final captureTarget = find.bySemanticsLabel('Capture');
      expect(tester.getSize(captureTarget), const Size(56, 56));
      expect(tester.getCenter(captureTarget).dx, closeTo(195, 2));
      expect(844 - tester.getRect(captureTarget).bottom, closeTo(54, 2));
      final captureCircle = _decoratedCircle(const Color(0xff181e34));
      expect(captureCircle, findsOneWidget);
      expect(tester.getSize(captureCircle), const Size(48, 48));
      expect(tester.widget<Text>(find.text('09:01')).style?.fontSize, 13);
      expect(
        tester.widget<Text>(find.text('09:01')).style?.height,
        closeTo(18 / 13, 0.001),
      );
      final captureRect = tester.getRect(captureCircle);
      expect(timelineTop, closeTo(104, 2));
      expect(firstSourceTop, closeTo(118, 2));
      expect(_actionSurfaceCircle, findsNothing);
      expect(_innerRestingShadow, findsNothing);
      final visibleTimes = find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.data != null &&
            RegExp(r'^\d{2}:\d{2}$').hasMatch(widget.data!),
        description: 'visible journal times',
      );
      for (final element in visibleTimes.evaluate()) {
        final candidate = find.byElementPredicate((value) => value == element);
        expect(
          tester.getRect(candidate).overlaps(captureRect),
          isFalse,
          reason: 'initially visible time is obscured by Capture',
        );
      }
      await expectLater(
        find.byKey(boundaryKey),
        matchesGoldenFile('goldens/journal-reference-alignment.png'),
      );
      final rowBody = find.bySemanticsLabel(
        RegExp('$taskSource, created at 09:01'),
      );
      final taskSemantics = find.bySemanticsLabel(
        RegExp('Mark as done: $taskSource'),
      );
      final taskTarget = find.descendant(
        of: taskSemantics,
        matching: _materialGlyph(0xe504),
      );
      expect(taskTarget, findsOneWidget);
      expect(
        tester
            .getSemantics(rowBody)
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
      );
      expect(
        tester
            .getSemantics(taskSemantics)
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
      );
      final taskGesture = await tester.startGesture(
        tester.getCenter(taskTarget),
      );
      await tester.pump(const Duration(milliseconds: 120));
      expect(_pressedOverlay, findsOneWidget);
      expect(tester.getSize(_pressedOverlay), const Size(44, 44));
      await taskGesture.moveBy(
        const Offset(-80, 0),
        timeStamp: const Duration(milliseconds: 500),
      );
      await tester.pump();
      await taskGesture.up(timeStamp: const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      expect(_pressedOverlay, findsNothing);
      expect(
        find.bySemanticsLabel(RegExp('Mark as done: $taskSource')),
        findsOneWidget,
      );
      final rowGesture = await tester.startGesture(
        tester.getCenter(find.text(taskSource)),
      );
      await tester.pump(const Duration(milliseconds: 120));
      expect(_pressedOverlay, findsOneWidget);
      expect(
        tester.getRect(_pressedOverlay).left,
        greaterThanOrEqualTo(tester.getRect(taskTarget).right - 1),
        reason: 'row-body feedback overlaps the independent task target',
      );
      await rowGesture.moveBy(
        const Offset(-80, 0),
        timeStamp: const Duration(milliseconds: 500),
      );
      await tester.pump();
      expect(
        tester.getTopLeft(find.text(taskSource)).dx,
        lessThan(sourceLeft - 20),
        reason: 'swipe threshold did not displace the resting row',
      );
      final swipeFeedback = find.byKey(
        const ValueKey<String>('bonsai-swipe-action-pill'),
      );
      final swipeDecoration = tester.widget<DecoratedBox>(
        find.descendant(of: swipeFeedback, matching: find.byType(DecoratedBox)),
      );
      expect(
        (swipeDecoration.decoration as BoxDecoration).borderRadius,
        BorderRadius.zero,
      );
      await expectLater(
        find.byKey(boundaryKey),
        matchesGoldenFile('goldens/journal-swipe-delete-threshold.png'),
      );
      await rowGesture.up(timeStamp: const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_pressedOverlay, findsNothing);
      expect(
        find.bySemanticsLabel(RegExp('Mark as done: $taskSource')),
        findsOneWidget,
      );
      expect(
        firstSourceTop - timelineTop,
        lessThan(30),
        reason:
            'the populated timeline must not apply the top safe area again '
            'after the header consumes it',
      );
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      final finalRowStopwatch = Stopwatch()..start();
      while (find.text('Timeline golden final row').evaluate().isEmpty &&
          finalRowStopwatch.elapsed < const Duration(seconds: 5)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.text('Timeline golden final row'), findsOneWidget);
      for (var attempt = 0; attempt < 4; attempt += 1) {
        final rowBottom = tester
            .getBottomLeft(find.text('Timeline golden final row'))
            .dy;
        final captureTop = tester
            .getTopLeft(find.bySemanticsLabel('Capture'))
            .dy;
        if (rowBottom < captureTop) break;
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
        await tester.pump();
      }
      final rowBottom = tester
          .getBottomLeft(find.text('Timeline golden final row'))
          .dy;
      final captureTop = tester.getTopLeft(find.bySemanticsLabel('Capture')).dy;
      expect(
        rowBottom,
        lessThan(captureTop),
        reason: 'the final timeline row must scroll clear of the overlay FAB',
      );
      expect(
        tester.getSize(find.byKey(boundaryKey)),
        const Size(390, 844),
        reason: 'the real runtime must fill the compact golden boundary',
      );

      await disposeHarness();
    },
    skip: Platform.environment['RUN_REAL_OCAML_GOLDEN'] != '1',
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

Finder get _pressedOverlay => find.byWidgetPredicate(
  (widget) => widget is ColoredBox && widget.color == const Color(0x1f0d142f),
  description: 'active journal pressed overlay',
);

Future<void> _loadGoldenFonts() async {
  final materialFonts = _findMaterialFontsDirectory();
  Future<ByteData> load(String name) async => ByteData.sublistView(
    await File('${materialFonts.path}/$name').readAsBytes(),
  );

  await (FontLoader('Roboto')..addFont(load('Roboto-Regular.ttf'))).load();
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

Finder _materialGlyph(int codePoint) => find.byWidgetPredicate(
  (widget) =>
      widget is Text &&
      widget.data == String.fromCharCode(codePoint) &&
      widget.style?.fontFamily == 'MaterialIcons',
  description: 'MaterialIcons U+${codePoint.toRadixString(16)}',
);

Finder _decoratedCircle(Color color) => find.byWidgetPredicate(
  (widget) =>
      widget is DecoratedBox &&
      widget.decoration is BoxDecoration &&
      (widget.decoration as BoxDecoration).color == color &&
      (widget.decoration as BoxDecoration).borderRadius ==
          BorderRadius.circular(24),
  description: '48 logical pixel circular decoration in $color',
);

Finder get _actionSurfaceCircle => find.byWidgetPredicate(
  (widget) =>
      widget is DecoratedBox &&
      widget.decoration is BoxDecoration &&
      (widget.decoration as BoxDecoration).color == const Color(0xfff5f5f6) &&
      (widget.decoration as BoxDecoration).borderRadius ==
          BorderRadius.circular(15),
  description: 'resting More action surface',
);

Finder get _innerRestingShadow => find.byWidgetPredicate(
  (widget) =>
      widget is DecoratedBox &&
      widget.decoration is BoxDecoration &&
      (widget.decoration as BoxDecoration).color == const Color(0x1c0d142f),
  description: 'second resting Center Orb shadow layer',
);

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
