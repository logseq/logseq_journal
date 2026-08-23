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
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _parentSource = 'Plan journal redesign';
const _firstChild = 'Increase block row height';
const _secondChild = 'Show parent and child preview';
const _thirdChild = 'Keep bounded virtualization';
const _dividerColor = Color(0xffe8e9ed);

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
    'real runtime matches row, divider, Capture, preview, and swipe contracts',
    (tester) async {
      final harness = await _RuntimeHarness.start(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(MessageComposer), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Wed, Aug 12'), findsOneWidget);
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
      for (final color in const [
        Color(0xff64748b),
        Color(0xff2563eb),
        Color(0xff058e46),
        Color(0xff7c3aed),
      ]) {
        expect(_statusRail(color), findsOneWidget);
      }
      expect(
        find.bySemanticsLabel(
          '$_parentSource, $_firstChild, $_secondChild, $_thirdChild, created at 21:37',
        ),
        findsOneWidget,
      );

      final rowRect = _ancestorRectWithHeight(
        tester,
        find.text(_parentSource),
        96,
      );
      expect(rowRect.width, closeTo(390, 0.5));
      expect(
        tester.getTopLeft(find.text('21:37')).dx,
        greaterThan(tester.getTopRight(find.text(_parentSource)).dx),
      );
      final dividers = _timelineDividers(tester, devicePixelRatio: 1);
      expect(dividers, hasLength(8));
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
      expect(firstChildTop - parentTop, closeTo(36, 0.1));
      expect(secondChildTop - firstChildTop, closeTo(44, 0.1));
      expect(
        tester.getTopLeft(find.text(_parentSource)).dy,
        closeTo(collapsedParentTop, 0.1),
      );
      expect(
        find.bySemanticsLabel('$_parentSource, created at 21:37'),
        findsOneWidget,
      );
      expect(_timelineDividers(tester, devicePixelRatio: 1), hasLength(8));
      await expectLater(
        find.byType(Scaffold).first,
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
        find.byType(Scaffold).first,
        matchesGoldenFile('goldens/journal-swipe-delete-threshold.png'),
      );
      await swipeGesture.up(timeStamp: const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 200));

      for (final dpr in const [2.0, 3.0, 4.0]) {
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(390 * dpr, 844 * dpr);
        tester.view.padding = FakeViewPadding(top: 47 * dpr, bottom: 34 * dpr);
        await harness.pumpUntil(
          () => _timelineDividers(tester, devicePixelRatio: dpr).length == 8,
          reason: 'divider geometry did not settle at ${dpr.toInt()}x',
        );
        final scaledDividers = _timelineDividers(tester, devicePixelRatio: dpr);
        expect(scaledDividers, hasLength(8));
        for (final rect in scaledDividers) {
          expect(rect.height * dpr, closeTo(1, 0.08));
          expect(rect.left, closeTo(0, 0.25));
          expect(rect.right, closeTo(390, 0.25));
        }
      }
      await _expectLastRowAboveComposer(tester, harness);
      tester.platformDispatcher.textScaleFactorTestValue = 3.2;
      await harness.pumpUntil(
        () =>
            MediaQuery.textScalerOf(
              tester.element(find.byType(MessageComposer)),
            ).scale(1) >
            3,
        reason: 'large text scale did not reach the composer',
      );
      await _expectLastRowAboveComposer(tester, harness);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pump();
      await _expectLastRowAboveComposer(tester, harness);
      tester.view.resetViewInsets();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await harness.dispose();
    },
    skip: Platform.environment['RUN_REAL_OCAML_GOLDEN'] != '1',
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

Future<void> _expectLastRowAboveComposer(
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
  final composer = tester.getRect(find.byType(MessageComposer));
  expect(
    row.bottom,
    lessThanOrEqualTo(composer.top + 0.5),
    reason: 'the final journal row is obscured by the persistent composer',
  );
}

Finder _statusRail(Color color) => find.byWidgetPredicate(
  (widget) =>
      widget is DecoratedBox &&
      widget.decoration is BoxDecoration &&
      (widget.decoration as BoxDecoration).color == color,
  description: 'four-point status rail with color $color',
);

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
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
    );
    await tester.pumpWidget(
      BonsaiFlutterRoot(
        config: config,
        runtimeStarter: (_) async => runtime,
        applicationPlatform: platform,
        frameEligibilitySource: frameEligibility,
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
      await tester.pump();
    }
    if (!predicate()) {
      final mountedText = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data)
          .whereType<String>()
          .toList();
      fail('$reason; mounted text: $mountedText');
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
    if (removeRoot && root.existsSync()) {
      await tester.runAsync(() => root.delete(recursive: true));
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

Finder _directChildText(String source) => find.byWidgetPredicate(
  (widget) =>
      widget is Text &&
      widget.data == source &&
      widget.style?.color == const Color(0xff0d142f),
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
