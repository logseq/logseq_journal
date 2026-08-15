import 'dart:io';

import 'package:bonsai_flutter/bonsai_flutter.dart';
// ignore: implementation_imports
import 'package:bonsai_flutter/src/runtime/foreground_frame_loop.dart';
// ignore: implementation_imports
import 'package:bonsai_flutter/src/renderer/pressable_host.dart';
import 'package:bonsai_flutter_logseq_journal_host/application_host_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _parentSource = 'Plan journal redesign';
const _firstChild = 'Increase block row height';
const _secondChild = 'Show parent and child preview';
const _thirdChild = 'Keep bounded virtualization';
const _dividerColor = Color(0xffe8e9ed);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  if (binding is LiveTestWidgetsFlutterBinding) {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  }

  testWidgets(
    'real runtime matches row, divider, Capture, preview, and swipe contracts',
    (tester) async {
      final harness = await _RuntimeHarness.start(tester);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Wed, Aug 12'), findsOneWidget);
      expect(find.text(_parentSource), findsOneWidget);
      expect(find.text(_firstChild), findsOneWidget);
      expect(find.text('21:37'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          '$_parentSource, $_firstChild, $_secondChild, created at 21:37',
        ),
        findsOneWidget,
      );

      final rowRect = _ancestorRectWithHeight(
        tester,
        find.text(_parentSource),
        76,
      );
      expect(rowRect.width, closeTo(390, 0.5));
      expect(
        tester.getTopLeft(find.text('21:37')).dx,
        greaterThan(tester.getTopRight(find.text(_parentSource)).dx),
      );
      final dividers = _timelineDividers(tester, devicePixelRatio: 1);
      expect(dividers, hasLength(4));
      for (final rect in dividers) {
        expect(rect.left, closeTo(0, 0.25));
        expect(rect.right, closeTo(390, 0.25));
        expect(rect.height, closeTo(1, 0.05));
      }

      final restingOuter = _decoratedCircle(
        color: const Color(0x120d142f),
        radius: 26,
      );
      final restingInner = _decoratedCircle(
        color: const Color(0xff181e34),
        radius: 24,
      );
      final pressedOuter = _decoratedCircle(
        color: const Color(0x120d142f),
        radius: 25,
      );
      final pressedInner = _decoratedCircle(
        color: const Color(0xff181e34),
        radius: 22.08,
      );
      expect(tester.getSize(restingOuter), const Size(52, 52));
      expect(tester.getSize(restingInner), const Size(48, 48));
      expect(tester.getSize(pressedOuter), const Size(50, 50));
      expect(tester.getSize(pressedInner), const Size(44.16, 44.16));
      _expectSameCenter(tester, restingOuter, restingInner);
      _expectSameCenter(tester, pressedOuter, pressedInner);
      final plusRects = find
          .descendant(
            of: restingInner,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is DecoratedBox &&
                  widget.decoration is BoxDecoration &&
                  (widget.decoration as BoxDecoration).color ==
                      const Color(0xfffcfcfd),
            ),
          )
          .evaluate()
          .map(
            (element) =>
                tester.getRect(find.byElementPredicate((e) => e == element)),
          )
          .toList();
      expect(plusRects, hasLength(2));
      final plusBounds = plusRects.reduce(
        (left, right) => left.expandToInclude(right),
      );
      expect(
        plusBounds.center.dx,
        closeTo(tester.getCenter(restingInner).dx, 0.05),
      );
      expect(
        plusBounds.center.dy,
        closeTo(tester.getCenter(restingInner).dy, 0.05),
      );
      final disclosureSemantics = tester.getSemantics(
        find.bySemanticsLabel(
          '$_parentSource, $_firstChild, $_secondChild, created at 21:37',
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
      expect(firstChildTop - parentTop, closeTo(36, 0.1));
      expect(secondChildTop - firstChildTop, closeTo(36, 0.1));
      expect(
        tester.getTopLeft(find.text(_parentSource)).dy,
        closeTo(collapsedParentTop, 0.1),
      );
      expect(
        find.bySemanticsLabel('$_parentSource, created at 21:37'),
        findsOneWidget,
      );
      expect(_timelineDividers(tester, devicePixelRatio: 1), hasLength(3));
      await expectLater(
        find.byKey(harness.boundaryKey),
        matchesGoldenFile('goldens/journal-reference-alignment.png'),
      );
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
      await expectLater(
        find.byKey(harness.boundaryKey),
        matchesGoldenFile('goldens/journal-swipe-delete-threshold.png'),
      );
      await swipeGesture.up(timeStamp: const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 200));

      for (final dpr in const [2.0, 3.0, 4.0]) {
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(390 * dpr, 844 * dpr);
        tester.view.padding = FakeViewPadding(top: 47 * dpr, bottom: 34 * dpr);
        await harness.pumpUntil(
          () => _timelineDividers(tester, devicePixelRatio: dpr).length == 4,
          reason: 'divider geometry did not settle at ${dpr.toInt()}x',
        );
        final scaledDividers = _timelineDividers(tester, devicePixelRatio: dpr);
        expect(scaledDividers, hasLength(4));
        for (final rect in scaledDividers) {
          expect(rect.height * dpr, closeTo(1, 0.08));
          expect(rect.left, closeTo(0, 0.25));
          expect(rect.right, closeTo(390, 0.25));
        }
      }
      await harness.dispose();
    },
    skip: Platform.environment['RUN_REAL_OCAML_GOLDEN'] != '1',
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

final class _RuntimeHarness {
  _RuntimeHarness({
    required this.tester,
    required this.runtime,
    required this.frameEligibility,
    required this.root,
    required this.removeRoot,
    required this.boundaryKey,
  });

  final WidgetTester tester;
  final RuntimeClient runtime;
  final _ControllableFrameEligibilitySource frameEligibility;
  final Directory root;
  final bool removeRoot;
  final GlobalKey boundaryKey;
  bool _disposed = false;

  static Future<_RuntimeHarness> start(
    WidgetTester tester, {
    double devicePixelRatio = 1,
  }) async {
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
      snapshotToken = fixture.stdout.toString().trim();
    } else {
      snapshotToken = Platform.environment['JOURNAL_GOLDEN_SNAPSHOT_TOKEN'] ??
          (throw StateError(
            'JOURNAL_GOLDEN_SNAPSHOT_TOKEN is required with JOURNAL_GOLDEN_SUPPORT_ROOT',
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
    final adapter = ApplicationHostAdapter(
      applicationSupportDirectory: () async => root,
      graphTarget: () async => LogseqDbTarget.snapshot(snapshotToken),
      initialCalendarSnapshot: () async => initialSnapshot,
      liveCalendarSnapshot: calendar,
    );
    final payload = (await tester.runAsync(adapter.createApplicationPayload))!;
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
    final boundaryKey = GlobalKey();
    final platform = JournalApplicationPlatform(
      calendarSnapshot: calendar,
      initialSnapshot: Future.value(initialSnapshot),
      formatJournalDays: ({required snapshot, required days}) async => {
        for (final day in days) day: day == 20260812 ? 'Wed, Aug 12' : '$day',
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
            runtimeStarter: (_) async => runtime,
            applicationPlatform: platform,
            frameEligibilitySource: frameEligibility,
          ),
        ),
      ),
    );
    final harness = _RuntimeHarness(
      tester: tester,
      runtime: runtime,
      frameEligibility: frameEligibility,
      root: root,
      removeRoot: configuredRoot == null,
      boundaryKey: boundaryKey,
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
      await tester.pump();
    }
    expect(predicate(), isTrue, reason: reason);
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
    if (removeRoot && root.existsSync()) {
      await tester.runAsync(() => root.delete(recursive: true));
    }
  }
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
      .byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).color == _dividerColor,
      )
      .evaluate()
      .map(
        (element) =>
            tester.getRect(find.byElementPredicate((e) => e == element)),
      )
      .where(
        (rect) =>
            rect.top > 110 &&
            rect.width > 300 &&
            (rect.height - expectedHeight).abs() < 0.08,
      )
      .toList();
}

Finder _decoratedCircle({required Color color, required double radius}) =>
    find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).color == color &&
          (widget.decoration as BoxDecoration).borderRadius ==
              BorderRadius.circular(radius),
    );

Finder _directChildText(String source) => find.byWidgetPredicate(
  (widget) =>
      widget is Text &&
      widget.data == source &&
      widget.style?.color == const Color(0xff0d142f),
);

void _expectSameCenter(WidgetTester tester, Finder outer, Finder inner) {
  expect(tester.getCenter(inner).dx, closeTo(tester.getCenter(outer).dx, 0.01));
  expect(tester.getCenter(inner).dy, closeTo(tester.getCenter(outer).dy, 0.01));
}

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
