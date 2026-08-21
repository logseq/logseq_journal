import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:bonsai_flutter/bonsai_flutter.dart';
// ignore: implementation_imports
import 'package:bonsai_flutter/src/runtime/foreground_frame_loop.dart';
// ignore: implementation_imports
import 'package:bonsai_flutter/src/renderer/pressable_host.dart';
import 'package:bonsai_flutter_logseq_journal_host/application_host_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'runtime_flow_fixture.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  if (binding is LiveTestWidgetsFlutterBinding) {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  }

  for (final locale in const [
    Locale('ar', 'SA'),
    Locale('fa', 'IR'),
    Locale('he', 'IL'),
    Locale('ur', 'PK'),
  ]) {
    testWidgets('compiled OCaml runtime centers Capture for '
        '${locale.toLanguageTag()}', (tester) async {
      final harness = await _RuntimeHarness.start(tester);
      final semantics = tester.ensureSemantics();
      try {
        await harness.show(
          tester,
          locale: locale,
          textDirection: TextDirection.rtl,
        );
        await _pumpUntil(
          tester,
          () => find.text('No journal entries yet').evaluate().isNotEmpty,
        );
        await _pumpRuntime(tester);
        await _pumpRuntime(tester);
        expect(
          tester.getCenter(find.text('Today')).dx,
          closeTo(_renderViewWidth(tester) / 2, 2),
        );
        expect(find.bySemanticsLabel('Menu'), findsNothing);
        expect(find.bySemanticsLabel('More'), findsNothing);
        expect(
          tester.getCenter(_materialGlyph(0xe3dc)).dx,
          greaterThan(tester.getCenter(_materialGlyph(0xe402)).dx),
          reason: 'RTL must mirror the noninteractive header shells',
        );
        expect(
          tester.getCenter(find.bySemanticsLabel('Capture')).dx,
          closeTo(_applicationViewportSize(tester).width / 2, 2),
          reason: '${locale.toLanguageTag()} must center Capture',
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await harness.dispose(tester);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  testWidgets(
    'compiled OCaml runtime centers Capture and preserves route admission for en-US',
    (tester) async {
      final harness = await _RuntimeHarness.start(tester);
      final semantics = tester.ensureSemantics();
      try {
        await harness.show(tester);
        await _pumpUntil(
          tester,
          () => find.text('No journal entries yet').evaluate().isNotEmpty,
        );
        await _pumpRuntime(tester);
        await _pumpRuntime(tester);
        expect(
          tester.getCenter(find.text('Today')).dx,
          closeTo(_renderViewWidth(tester) / 2, 2),
        );
        expect(find.bySemanticsLabel('Menu'), findsNothing);
        expect(find.bySemanticsLabel('More'), findsNothing);
        expect(
          tester.getCenter(_materialGlyph(0xe3dc)).dx,
          lessThan(tester.getCenter(_materialGlyph(0xe402)).dx),
          reason: 'LTR must preserve the noninteractive header shells',
        );
        expect(
          tester.getCenter(find.bySemanticsLabel('Capture')).dx,
          closeTo(_applicationViewportSize(tester).width / 2, 2),
          reason: 'en-US must center Capture',
        );
        final capture = find.bySemanticsLabel('Capture');
        if (!Platform.isIOS) {
          final cancelled = await tester.startGesture(
            tester.getCenter(capture),
          );
          await tester.pump();
          expect(find.text('New block'), findsNothing);
          await cancelled.moveBy(const Offset(80, 0));
          await tester.pump();
          await cancelled.up();
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.text('New block'), findsNothing);
        }

        final captureSemantics = tester.getSemantics(capture);
        expect(
          captureSemantics.getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
        );
        captureSemantics.owner!.performAction(
          captureSemantics.id,
          SemanticsAction.tap,
        );
        captureSemantics.owner!.performAction(
          captureSemantics.id,
          SemanticsAction.tap,
        );
        await tester.pump();
        if (!Platform.isIOS) {
          expect(find.text('New block'), findsNothing);
          await tester.pump(const Duration(milliseconds: 80));
        }
        await _pumpRuntime(tester);
        await _pumpUntil(
          tester,
          () => find.text('New block').evaluate().isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('New block'), findsOneWidget);
        expect(find.byType(ModalBarrier), findsWidgets);
        expect(find.text('Today'), findsOneWidget);
        expect(
          ModalRoute.of(tester.element(find.text('New block'))),
          isA<ModalBottomSheetRoute<void>>(),
        );
        expect(find.byType(TextField), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).autofocus,
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await _tapSemantics(tester, 'Close new block editor');
        await _pumpRuntime(tester);
        await _pumpUntil(
          tester,
          () => find.text('New block').evaluate().isEmpty,
        );
        expect(find.text('Today'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await harness.dispose(tester);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'compiled OCaml runtime drains visible continuations without a gesture',
    (tester) async {
      final harness = await _RuntimeHarness.start(
        tester,
        fixtureMode: RuntimeFlowFixtureMode.pagination,
      );
      try {
        await harness.show(tester);
        await _pumpUntil(
          tester,
          () => find.text('Pagination day five row 01').evaluate().isNotEmpty,
        );
        await _pumpUntil(
          tester,
          () => find.text('Loading more journal entries').evaluate().isEmpty,
        );
        expect(find.text('Loading more journal entries'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await harness.dispose(tester);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'benchmark macOS continuous trackpad scrolling',
    (tester) async {
      if (!Platform.isMacOS) return;
      final harness = await _RuntimeHarness.start(
        tester,
        fixtureMode: RuntimeFlowFixtureMode.pagination,
      );
      try {
        await harness.show(tester);
        await _pumpUntil(
          tester,
          () => find.text('Pagination day five row 01').evaluate().isNotEmpty,
        );
        await _pumpUntil(
          tester,
          () => find.text('Loading more journal entries').evaluate().isEmpty,
        );
        for (final benchmark in const [
          (name: 'steady', flingDistance: 560.0, speed: 1800.0, flingCount: 6),
          (
            name: 'high-velocity',
            flingDistance: 900.0,
            speed: 9000.0,
            flingCount: 6,
          ),
        ]) {
          final position = tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position;
          position.jumpTo(position.minScrollExtent);
          await tester.pump();
          await _pumpRuntime(tester);
          await _runMacosScrollBenchmark(
            binding,
            tester,
            name: benchmark.name,
            flingDistance: benchmark.flingDistance,
            speed: benchmark.speed,
            flingCount: benchmark.flingCount,
          );
        }
      } finally {
        await harness.dispose(tester);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'compiled OCaml runtime drains child demand queued behind pagination',
    (tester) async {
      final harness = await _RuntimeHarness.start(
        tester,
        fixtureMode: RuntimeFlowFixtureMode.pagination,
      );
      try {
        await harness.show(tester);
        await _pumpUntil(
          tester,
          () => find.text('Pagination expandable parent').evaluate().isNotEmpty,
        );
        final parentPressable = find
            .ancestor(
              of: find.text('Pagination expandable parent'),
              matching: find.byType(PressableHost),
            )
            .first;
        await tester.tap(parentPressable);
        await _pumpUntil(
          tester,
          () => find.text('Loading direct child blocks').evaluate().isNotEmpty,
        );
        await _pumpUntil(
          tester,
          () =>
              find.text('Pagination persisted child').evaluate().isNotEmpty &&
              find.text('Loading direct child blocks').evaluate().isEmpty,
        );
        expect(find.text('Loading direct child blocks'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await harness.dispose(tester);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'compiled OCaml runtime honors the safe-area adaptive environment',
    (tester) async {
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      final harness = await _RuntimeHarness.start(tester);
      try {
        await harness.show(tester);
        await _pumpUntil(
          tester,
          () => find.text('No journal entries yet').evaluate().isNotEmpty,
        );
        expect(
          tester.getBottomRight(find.bySemanticsLabel('Capture')).dy,
          lessThanOrEqualTo(810),
          reason: 'the Capture target must clear the 34-point safe bottom',
        );
      } finally {
        tester.view.resetPadding();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        await harness.dispose(tester);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'compiled OCaml runtime owns the contextual Capture sheet and task flow',
    (tester) async {
      final harness = await _RuntimeHarness.start(tester);
      final semantics = tester.ensureSemantics();
      try {
        await harness.show(tester);
        await _pumpUntil(
          tester,
          () => find.text('No journal entries yet').evaluate().isNotEmpty,
        );
        expect(find.text('Today'), findsOneWidget);
        await _pumpUntil(
          tester,
          () =>
              find.text('Fri, Aug 7').evaluate().isNotEmpty ||
              find.text('Date unavailable').evaluate().isNotEmpty,
        );
        await _tapSemantics(tester, 'Capture');
        await _pumpRuntime(tester);
        await _pumpUntil(
          tester,
          () => find.text('New block').evaluate().isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('Today'), findsOneWidget);
        expect(find.byType(ModalBarrier), findsWidgets);
        expect(
          ModalRoute.of(tester.element(find.text('New block'))),
          isA<ModalBottomSheetRoute<void>>(),
        );
        expect(
          tester.getSemantics(find.bySemanticsLabel('Capture')).owner,
          isNull,
          reason:
              'the Timeline semantics node must be detached by the modal route',
        );
        const literalSource = '中文 👩🏽‍💻 e\u0301 #literal @mention';
        await tester.enterText(find.byType(TextField), literalSource);
        await _pumpRuntime(tester);
        expect(find.text('New block'), findsOneWidget);
        expect(find.text(literalSource), findsOneWidget);

        await _tapSemantics(tester, 'Close new block editor');
        await _pumpRuntime(tester);
        await _pumpUntil(
          tester,
          () => find.text('Discard draft?').evaluate().isNotEmpty,
        );
        await tester.tap(find.text('Keep editing').last);
        await _pumpRuntime(tester);
        await _pumpUntil(
          tester,
          () => find.text('Discard draft?').evaluate().isEmpty,
        );
        expect(find.text(literalSource), findsOneWidget);

        await _tapSemantics(tester, 'Make task');
        await _pumpRuntime(tester);
        await _pumpUntil(
          tester,
          () => find.text('To do').evaluate().isNotEmpty,
        );
        await _tapSemantics(tester, 'Save journal block');
        await _pumpRuntime(tester);
        await _pumpUntil(
          tester,
          () =>
              find.text('New block').evaluate().isEmpty &&
              find.byType(TextField).evaluate().isEmpty,
        );
        await _pumpUntil(
          tester,
          () => find
              .bySemanticsLabel(
                RegExp('Mark as done: ${RegExp.escape(literalSource)}'),
              )
              .evaluate()
              .isNotEmpty,
        );
        await tester.tap(_materialGlyph(0xe504).last);
        await tester.pump(const Duration(milliseconds: 110));
        await _pumpRuntime(tester);
        await _pumpUntil(
          tester,
          () => find
              .bySemanticsLabel(
                RegExp('Mark as todo: ${RegExp.escape(literalSource)}'),
              )
              .evaluate()
              .isNotEmpty,
        );

        expect(find.text('Entry detail'), findsNothing);
        // Scope frame-duration evidence to the Timeline row and environment
        // matrix implemented by this tranche, excluding Capture route startup.
        BonsaiFlutterDebug.reset();
        await _exerciseEnvironmentMatrix(tester, source: literalSource);
        await _requireMechanicalBudgets(tester, harness.runtime);

        expect(find.textContaining('Search'), findsNothing);
        expect(find.textContaining('Attachment'), findsNothing);
        expect(find.textContaining('Thumbnail'), findsNothing);
        expect(
          find.text('Fri, Aug 7').evaluate().length +
              find.text('Date unavailable').evaluate().length,
          1,
          reason: 'the compiled runtime must expose one truthful date context',
        );
      } finally {
        semantics.dispose();
        await harness.dispose(tester);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'compiled OCaml runtime arbitrates end-to-start delete, scrolling, RTL, and Undo',
    (tester) async {
      final harness = await _RuntimeHarness.start(tester);
      final semantics = tester.ensureSemantics();
      const source = 'Swipe delete compiled runtime row';
      try {
        await harness.show(tester);
        await _pumpUntil(
          tester,
          () => find.text('No journal entries yet').evaluate().isNotEmpty,
        );
        await _tapSemantics(tester, 'Capture');
        await _pumpUntil(
          tester,
          () => find.text('New block').evaluate().isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.enterText(find.byType(TextField), source);
        await _pumpRuntime(tester);
        await _tapSemantics(tester, 'Make task');
        await _pumpRuntime(tester);
        await _pumpUntil(
          tester,
          () => find.text('To do').evaluate().isNotEmpty,
        );
        await _tapSemantics(tester, 'Save journal block');
        await _pumpUntil(
          tester,
          () =>
              find.text('New block').evaluate().isEmpty &&
              find.byType(TextField).evaluate().isEmpty,
        );
        await _pumpUntil(
          tester,
          () => find
              .bySemanticsLabel(RegExp('Mark as done: $source'))
              .evaluate()
              .isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 250));

        await tester.drag(find.text(source).first, const Offset(140, 0));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text(source), findsOneWidget);
        expect(find.text('Block and descendants removed'), findsNothing);

        await tester.drag(find.text(source).first, const Offset(0, -100));
        await tester.pump();
        expect(find.text(source), findsOneWidget);
        expect(find.text('Block and descendants removed'), findsNothing);

        final task = _materialGlyph(0xe504).first;
        await tester.timedDrag(
          task,
          const Offset(-180, 0),
          const Duration(milliseconds: 300),
        );
        await tester.pump(const Duration(milliseconds: 250));
        await _pumpRuntime(tester);
        expect(find.text(source), findsNothing);
        expect(
          find.bySemanticsLabel(RegExp('Mark as done: $source')),
          findsNothing,
        );
        expect(find.text('Block and descendants removed'), findsOneWidget);
        final undo = find.bySemanticsLabel('Undo block deletion');
        expect(undo, findsOneWidget);
        expect(tester.getSize(undo).height, greaterThanOrEqualTo(48));
        final snackbarRect = tester.getRect(
          find.text('Block and descendants removed'),
        );
        final captureRect = tester.getRect(find.bySemanticsLabel('Capture'));
        expect(snackbarRect.bottom, lessThan(captureRect.top));
        expect(snackbarRect.left, greaterThanOrEqualTo(12));
        expect(snackbarRect.right, lessThanOrEqualTo(378));
        await tester.tap(undo);
        await _pumpRuntime(tester);
        await _pumpUntil(tester, () => find.text(source).evaluate().isNotEmpty);
        expect(
          find.bySemanticsLabel(RegExp('Mark as done: $source')),
          findsOneWidget,
        );

        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(
              disableAnimations: true,
              reduceMotion: true,
            );
        harness.setTextDirection(TextDirection.rtl);
        await tester.pump();
        await _pumpRuntime(tester);
        await _pumpUntil(tester, () => find.text(source).evaluate().isNotEmpty);
        await tester.timedDrag(
          find.text(source).first,
          const Offset(180, 0),
          const Duration(milliseconds: 300),
        );
        await tester.pump();
        await _pumpRuntime(tester);
        expect(find.text(source), findsNothing);
        expect(find.text('Block and descendants removed'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.bySemanticsLabel('Undo block deletion'));
        await _pumpRuntime(tester);
      } finally {
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
        semantics.dispose();
        await harness.dispose(tester);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'compiled OCaml runtime replaces iOS child loading with persisted children',
    (tester) async {
      final harness = await _RuntimeHarness.start(tester);
      final semantics = tester.ensureSemantics();
      const parentSource = 'iOS expandable parent';
      const childSource = 'iOS persisted child';
      try {
        await harness.show(tester);
        await _pumpUntil(
          tester,
          () => find.text('No journal entries yet').evaluate().isNotEmpty,
        );
        await _tapSemantics(tester, 'Capture');
        await _pumpUntil(
          tester,
          () => find.text('New block').evaluate().isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.enterText(find.byType(TextField).first, parentSource);
        await _pumpRuntime(tester);
        await tester.tap(find.text('Add child'));
        await _pumpRuntime(tester);
        await _pumpUntil(
          tester,
          () => find.byType(TextField).evaluate().length == 2,
        );
        await tester.enterText(find.byType(TextField).last, childSource);
        await _pumpRuntime(tester);
        await _pumpUntil(
          tester,
          () => _hasAttachedSemanticsTap(tester, 'Save journal block'),
        );
        await _tapSemantics(tester, 'Save journal block');
        await _pumpRuntime(tester);
        await _pumpUntil(
          tester,
          () =>
              find.text(parentSource).evaluate().isNotEmpty &&
              find.text('New block').evaluate().isEmpty,
        );

        final parentPressable = find
            .ancestor(
              of: find.text(parentSource),
              matching: find.byType(PressableHost),
            )
            .first;
        await tester.tap(parentPressable);
        await _pumpUntil(
          tester,
          () => find.text('Loading direct child blocks').evaluate().isNotEmpty,
        );
        await _pumpUntil(
          tester,
          () =>
              find.text(childSource).evaluate().isNotEmpty &&
              find.text('Loading direct child blocks').evaluate().isEmpty,
        );
        expect(find.text('Loading direct child blocks'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await harness.dispose(tester);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'compiled OCaml runtime exposes a truthful startup error',
    (tester) async {
      final config = RuntimeBootstrapConfig(
        entrypoint: 'logseq_journal',
        launchPolicy: RuntimeLaunchPolicy.replaceExisting,
        applicationPayload: Uint8List.fromList([0]),
      ).encode();
      await tester.pumpWidget(
        MaterialApp(home: BonsaiFlutterRoot(config: config)),
      );
      await _pumpUntil(
        tester,
        () => find.textContaining('Bonsai runtime error').evaluate().isNotEmpty,
      );
      expect(find.textContaining('Bonsai runtime error'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpRuntime(tester);
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

double _renderViewWidth(WidgetTester tester) =>
    tester.binding.renderViews.first.size.width;

Size _applicationViewportSize(WidgetTester tester) => Platform.isIOS
    ? tester.view.physicalSize / tester.view.devicePixelRatio
    : tester.binding.renderViews.first.size;

Future<void> _exerciseEnvironmentMatrix(
  WidgetTester tester, {
  required String source,
}) async {
  if (Platform.isIOS) {
    await _pumpRuntime(tester);
    final renderViewSize = tester.binding.renderViews.first.size;
    final applicationViewportSize = _applicationViewportSize(tester);
    expect(
      tester.getCenter(find.text('Today')).dx,
      closeTo(renderViewSize.width / 2, 2),
    );
    expect(
      tester.getCenter(find.bySemanticsLabel('Capture')).dx,
      closeTo(applicationViewportSize.width / 2, 2),
    );
    expect(
      tester.getBottomRight(find.bySemanticsLabel('Capture')).dy,
      lessThanOrEqualTo(applicationViewportSize.height),
    );
    expect(find.text(source), findsOneWidget);
    expect(tester.takeException(), isNull);
    return;
  }

  for (final size in const [Size(320, 720), Size(390, 844), Size(1200, 900)]) {
    tester.view.physicalSize = size;
    await _pumpRuntime(tester);
    await _pumpUntil(tester, () => find.text('Today').evaluate().isNotEmpty);
    expect(
      tester.getCenter(find.text('Today')).dx,
      closeTo(_applicationViewportSize(tester).width / 2, 2),
    );
    expect(tester.takeException(), isNull);
  }

  tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(
        highContrast: true,
        disableAnimations: true,
        reduceMotion: true,
      );
  await _pumpRuntime(tester);
  await _pumpUntil(tester, () => find.text('Today').evaluate().isNotEmpty);
  expect(tester.takeException(), isNull);

  tester.view.physicalSize = const Size(744, 900);
  tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  await _pumpRuntime(tester);
  await _pumpUntil(tester, () => find.text(source).evaluate().isNotEmpty);
  await _pumpUntil(
    tester,
    () =>
        (tester.getTopLeft(find.text(source)).dy -
                tester.getTopLeft(find.text('00:30')).dy)
            .abs() >
        2,
  );
  final sourceTop = tester.getTopLeft(find.text(source)).dy;
  final timeTop = tester.getTopLeft(find.text('00:30')).dy;
  final timelineTop = tester.getTopLeft(find.byType(Scrollable).first).dy;
  expect(
    sourceTop - timelineTop,
    lessThan(30),
    reason:
        'the adaptive timeline must not reapply the 47-point top safe area '
        'below the header',
  );
  expect(
    (sourceTop - timeTop).abs(),
    greaterThan(2),
    reason: 'text scale 2.0 must select the adaptive two-line row',
  );
  expect(
    tester.getBottomRight(find.bySemanticsLabel('Capture')).dy,
    lessThanOrEqualTo(866),
    reason: 'the Capture target must clear the 34-point safe bottom',
  );
  tester.view.resetPadding();
  tester.platformDispatcher.clearTextScaleFactorTestValue();
}

Future<void> _requireMechanicalBudgets(
  WidgetTester tester,
  RuntimeClient runtime,
) async {
  const maximumPatchBytes = 256 * 1024;
  const maximumMountedNodes = 800;
  const maximumResidentBytes = 512 * 1024 * 1024;
  // This suite uses a debug native artifact; release/profile traces remain a
  // physical-device acceptance gate.
  const maximumFrameDuration = Duration(milliseconds: 75);

  await _pumpRuntime(tester);
  final frames = BonsaiFlutterDebug.frameStats();
  expect(frames, isNotEmpty);
  expect(
    frames.map((frame) => frame.patchBytes).reduce((a, b) => a > b ? a : b),
    lessThanOrEqualTo(maximumPatchBytes),
  );
  expect(
    find.byType(NodeHost).evaluate().length,
    lessThanOrEqualTo(maximumMountedNodes),
  );
  expect(ProcessInfo.currentRss, lessThanOrEqualTo(maximumResidentBytes));
  for (final frame in frames) {
    if (frame.flutterBuildDuration case final duration?) {
      expect(
        duration,
        lessThanOrEqualTo(maximumFrameDuration),
        reason:
            'Flutter build exceeded the budget at revision ${frame.revision}',
      );
    }
    if (frame.paintDuration case final duration?) {
      expect(
        duration,
        lessThanOrEqualTo(maximumFrameDuration),
        reason:
            'Flutter paint exceeded the budget at revision ${frame.revision}',
      );
    }
  }
  final snapshot = await tester.runAsync(runtime.debugSnapshot);
  expect(snapshot, isNotNull);
  expect(snapshot!.pumpCount, greaterThan(0));
}

Future<void> _runMacosScrollBenchmark(
  TestWidgetsFlutterBinding binding,
  WidgetTester tester, {
  required String name,
  required double flingDistance,
  required double speed,
  required int flingCount,
}) async {
  const maximumPatchBytes = 256 * 1024;
  const maximumMountedNodes = 800;
  final scrollable = find.byType(Scrollable).first;
  final position = tester.state<ScrollableState>(scrollable).position;
  final initialPixels = position.pixels;
  final frameTimings = <FrameTiming>[];
  final timingsCallback = frameTimings.addAll;
  BonsaiFlutterDebug.reset();
  binding.addTimingsCallback(timingsCallback);
  final stopwatch = Stopwatch()..start();
  try {
    for (var fling = 0; fling < flingCount; fling += 1) {
      if (position.extentAfter <= 1) break;
      await tester.trackpadFling(
        scrollable,
        Offset(0, -flingDistance),
        speed,
        initialOffsetDelay: Duration.zero,
      );
      await _pumpRuntime(tester);
    }
    await tester.pump(const Duration(milliseconds: 32));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1200)),
    );
    await tester.pump();
  } finally {
    stopwatch.stop();
    binding.removeTimingsCallback(timingsCallback);
  }

  final runtimeFrames = BonsaiFlutterDebug.frameStats();
  final patchBytes = runtimeFrames.map((frame) => frame.patchBytes).toList();
  expect(position.pixels, greaterThan(initialPixels));
  expect(frameTimings, isNotEmpty);
  expect(runtimeFrames, isNotEmpty);
  expect(tester.takeException(), isNull);
  expect(
    find.byType(NodeHost).evaluate().length,
    lessThanOrEqualTo(maximumMountedNodes),
  );
  expect(
    patchBytes.reduce((left, right) => left > right ? left : right),
    lessThanOrEqualTo(maximumPatchBytes),
  );

  final report = {
    'schemaVersion': 1,
    'layer': 'compiled-runtime',
    'platform': 'macos',
    'case': name,
    'flingDistance': flingDistance,
    'speed': speed,
    'requestedFlings': flingCount,
    'scrollDistance': position.pixels - initialPixels,
    'wallElapsedUs': stopwatch.elapsedMicroseconds,
    'flutterFrames': frameTimings.length,
    'flutterTotalUs': _numericSummary(
      frameTimings.map((timing) => timing.totalSpan.inMicroseconds),
    ),
    'flutterBuildUs': _numericSummary(
      frameTimings.map((timing) => timing.buildDuration.inMicroseconds),
    ),
    'flutterRasterUs': _numericSummary(
      frameTimings.map((timing) => timing.rasterDuration.inMicroseconds),
    ),
    'framesOver16ms': frameTimings
        .where(
          (timing) => timing.totalSpan > const Duration(microseconds: 16667),
        )
        .length,
    'runtimeFrames': runtimeFrames.length,
    'eventBatchSize': _numericSummary(
      runtimeFrames.map((frame) => frame.eventBatchSize),
    ),
    'coalescedEvents': runtimeFrames.fold<int>(
      0,
      (total, frame) => total + frame.coalescedEventCount,
    ),
    'patchBytes': _numericSummary(patchBytes),
    'dirtyNodes': _numericSummary(
      runtimeFrames.map((frame) => frame.dirtyNodeCount),
    ),
    'bonsaiFlushNs': _numericSummary(
      runtimeFrames
          .map((frame) => frame.bonsaiFlushNanoseconds)
          .whereType<int>(),
    ),
    'reconcileNs': _numericSummary(
      runtimeFrames.map((frame) => frame.reconcileNanoseconds).whereType<int>(),
    ),
    'encodeNs': _numericSummary(
      runtimeFrames.map((frame) => frame.encodeNanoseconds).whereType<int>(),
    ),
    'decodeUs': _numericSummary(
      runtimeFrames
          .map((frame) => frame.decodeDuration)
          .whereType<Duration>()
          .map((duration) => duration.inMicroseconds),
    ),
    'nodeStoreApplyUs': _numericSummary(
      runtimeFrames
          .map((frame) => frame.nodeStoreApplyDuration)
          .whereType<Duration>()
          .map((duration) => duration.inMicroseconds),
    ),
    'mountedNodes': find.byType(NodeHost).evaluate().length,
  };
  debugPrint('SCROLL_BENCHMARK ${jsonEncode(report)}', wrapWidth: 100000);
}

Map<String, int> _numericSummary(Iterable<int> values) {
  final sorted = values.toList()..sort();
  if (sorted.isEmpty) {
    return const {'samples': 0, 'p50': 0, 'p95': 0, 'max': 0};
  }
  int percentile(double value) => sorted[((sorted.length - 1) * value).round()];
  return {
    'samples': sorted.length,
    'p50': percentile(0.50),
    'p95': percentile(0.95),
    'max': sorted.last,
  };
}

final class _RuntimeHarness {
  _RuntimeHarness({
    required this.root,
    required this.ownsRoot,
    required this.config,
    required this.runtime,
    required this.recordingSession,
    required this.adapter,
    required this.frameEligibility,
    required this.textDirectionOverride,
  });

  final Directory root;
  final bool ownsRoot;
  final Uint8List config;
  final RuntimeClient runtime;
  final _RecordingRuntimeSession recordingSession;
  final ApplicationHostAdapter adapter;
  final _ControllableFrameEligibilitySource frameEligibility;
  final ValueNotifier<TextDirection?> textDirectionOverride;

  static Future<_RuntimeHarness> start(
    WidgetTester tester, {
    RuntimeFlowFixtureMode fixtureMode = RuntimeFlowFixtureMode.normal,
  }) async {
    final fixture = await RuntimeFlowFixture.create(tester, mode: fixtureMode);
    final root = fixture.supportRoot;
    var generation = 1;
    Future<JournalCalendarSnapshot> calendar() async => JournalCalendarSnapshot(
      instantUnixMilliseconds: 1786055400000,
      localDay: 20260807,
      locale: 'en_US',
      timeZoneId: 'Europe/Paris',
      utcOffsetSeconds: 7200,
      generation: generation++,
    );
    final adapter = ApplicationHostAdapter(
      applicationSupportDirectory: () async => root,
      graphTarget: () async => LogseqDbTarget.snapshot(fixture.snapshotToken),
      initialCalendarSnapshot: calendar,
      liveCalendarSnapshot: calendar,
    );
    final payload = await tester.runAsync(adapter.createApplicationPayload);
    expect(payload, isNotNull);
    final config = RuntimeBootstrapConfig(
      entrypoint: 'logseq_journal',
      launchPolicy: RuntimeLaunchPolicy.replaceExisting,
      applicationPayload: payload!,
    ).encode();
    final runtime = await tester.runAsync(
      () => RuntimeClient.start(
        config: config,
      ).timeout(const Duration(seconds: 15)),
    );
    expect(runtime, isNotNull);
    final recordingSession = _RecordingRuntimeSession(runtime!);
    final textDirectionOverride = ValueNotifier<TextDirection?>(null);
    return _RuntimeHarness(
      root: root,
      ownsRoot: true,
      config: config,
      runtime: runtime,
      recordingSession: recordingSession,
      adapter: adapter,
      frameEligibility: _ControllableFrameEligibilitySource(),
      textDirectionOverride: textDirectionOverride,
    );
  }

  Future<void> show(
    WidgetTester tester, {
    Locale? locale,
    TextDirection? textDirection,
  }) async {
    textDirectionOverride.value = textDirection;
    BonsaiFlutterDebug.reset();
    if (!Platform.isIOS) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
    }
    final root = BonsaiFlutterRoot(
      config: config,
      runtimeStarter: (_) async => recordingSession,
      applicationPlatform: adapter.createApplicationPlatform(),
      frameEligibilitySource: frameEligibility,
    );
    await tester.pumpWidget(
      ValueListenableBuilder<TextDirection?>(
        valueListenable: textDirectionOverride,
        child: root,
        builder: (context, direction, child) => MaterialApp(
          builder: (context, root) {
            final directed = direction == null
                ? root!
                : Directionality(textDirection: direction, child: root!);
            return locale == null
                ? directed
                : Localizations(
                    locale: locale,
                    delegates: const [_AnyLocaleWidgetsDelegate()],
                    child: directed,
                  );
          },
          home: child,
        ),
      ),
    );
  }

  void setTextDirection(TextDirection direction) {
    textDirectionOverride.value = direction;
  }

  Future<void> dispose(WidgetTester tester) async {
    var settled = await tester.runAsync(runtime.debugSnapshot);
    if (settled?.state == RuntimeWorkerState.awaitingPresentation) {
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
    await tester.runAsync(
      () => runtime.dispose().timeout(const Duration(seconds: 15)),
    );
    textDirectionOverride.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    if (ownsRoot && root.existsSync()) {
      await tester.runAsync(() => root.delete(recursive: true));
    }
  }
}

final class _AnyLocaleWidgetsDelegate
    extends LocalizationsDelegate<WidgetsLocalizations> {
  const _AnyLocaleWidgetsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<WidgetsLocalizations> load(Locale locale) async =>
      const DefaultWidgetsLocalizations();

  @override
  bool shouldReload(_AnyLocaleWidgetsDelegate old) => false;
}

final class _RecordingRuntimeSession implements RuntimeSession {
  _RecordingRuntimeSession(this._inner) {
    updates = _inner.updates.map(_record);
  }

  final RuntimeSession _inner;
  final Set<String> _presentedText = <String>{};
  @override
  late final Stream<RuntimeUpdate> updates;
  String? _targetText;

  void startRecordingText(String text) {
    _targetText = text;
  }

  RuntimeUpdate _record(RuntimeUpdate update) {
    final targetText = _targetText;
    if (targetText == null) return update;
    if (update case CycleReady(
      :final presentationId,
      :final revision,
      :final bytes,
      :final recoverableDiagnostic,
    )) {
      final payload = bytes.materialize().asUint8List();
      final decoded = utf8.decode(payload, allowMalformed: true);
      if (decoded.contains(targetText)) {
        _presentedText.add(targetText);
        _targetText = null;
      }
      return CycleReady(
        presentationId: presentationId,
        revision: revision,
        bytes: TransferableTypedData.fromList([payload]),
        recoverableDiagnostic: recoverableDiagnostic,
      );
    }
    return update;
  }

  bool sawFrameContaining(String text) => _presentedText.contains(text);

  @override
  void grantVsync({required int generation}) =>
      _inner.grantVsync(generation: generation);

  @override
  void setFrameEligibility({required int generation, required bool eligible}) =>
      _inner.setFrameEligibility(generation: generation, eligible: eligible);

  @override
  void presentationSucceeded({
    required int generation,
    required int presentationId,
    required int revision,
    required Uint8List eventBatch,
  }) => _inner.presentationSucceeded(
    generation: generation,
    presentationId: presentationId,
    revision: revision,
    eventBatch: eventBatch,
  );

  @override
  void presentationRejected({
    required int generation,
    required int presentationId,
    required int revision,
    required PresentationRejectionReason reason,
  }) => _inner.presentationRejected(
    generation: generation,
    presentationId: presentationId,
    revision: revision,
    reason: reason,
  );

  @override
  Future<RuntimeDebugSnapshot> debugSnapshot() => _inner.debugSnapshot();

  @override
  Future<void> dispose() => _inner.dispose();
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

Finder _materialGlyph(int codePoint) => find.byWidgetPredicate(
  (widget) =>
      widget is Text &&
      widget.data == String.fromCharCode(codePoint) &&
      widget.style?.fontFamily == 'MaterialIcons',
  description: 'MaterialIcons U+${codePoint.toRadixString(16)}',
);

Future<void> _pumpRuntime(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  await tester.pump();
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!predicate() && stopwatch.elapsed < timeout) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(predicate(), isTrue);
}

Future<void> _tapSemantics(WidgetTester tester, String label) async {
  await _tapSemanticsFinder(tester, find.bySemanticsLabel(label));
}

bool _hasAttachedSemanticsTap(WidgetTester tester, String label) {
  final candidates = find.bySemanticsLabel(label);
  for (var index = candidates.evaluate().length - 1; index >= 0; index -= 1) {
    final semantics = tester.getSemantics(candidates.at(index));
    if (semantics.owner != null &&
        semantics.getSemanticsData().hasAction(SemanticsAction.tap)) {
      return true;
    }
  }
  return false;
}

Future<void> _tapSemanticsFinder(WidgetTester tester, Finder candidates) async {
  final count = candidates.evaluate().length;
  for (var index = count - 1; index >= 0; index -= 1) {
    final semantics = tester.getSemantics(candidates.at(index));
    final owner = semantics.owner;
    if (owner == null) continue;
    owner.performAction(semantics.id, SemanticsAction.tap);
    await tester.pump(const Duration(milliseconds: 80));
    return;
  }
  fail('No attached semantics node was found for $candidates');
}
