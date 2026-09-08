import 'package:bonsai_flutter_logseq_journal_host/journal_widget_registry.dart';
import 'package:bonsai_flutter/bonsai_flutter.dart';
import 'dart:ui' show SemanticsAction, Tristate;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bonsai_flutter_logseq_journal_host/journal_root_navigation.dart';

Widget captureWidget({Key? key, ValueChanged<String>? onChanged}) =>
    ExpandableMessageComposer(
      key: key,
      fabPresentation: ExpandableMessageComposerFabPresentation.extended,
      fabLabel: 'Capture',
      fabTooltip: 'Open Capture',
      fabIcon: const Icon(Icons.add),
      buttons: const [],
      animationDuration: Duration.zero,
      onChanged: onChanged,
    );

void main() {
  testWidgets('Application registry renders Capture native kind 7', (
    tester,
  ) async {
    final resources = RendererResourceStore();
    addTearDown(resources.dispose);
    final registry = createJournalWidgetRegistry();
    final node = UiNode(
      id: 1,
      kind: NodeKind.nativeWidget,
      props: NativeWidgetProps(
        kindId: NativeWidgetKind.expandableMessageComposer,
        version: 2,
        capabilityBits: NativeCapability.stateful | NativeCapability.semantics,
        payload: const ExpandableMessageComposerProps(
          enabled: true,
          fabPresentation: ExpandableMessageComposerFabPresentation.extended,
          fabLabel: 'Capture',
          fabTooltip: 'Open Capture',
          animationDurationMilliseconds: 0,
          animationCurve: AnimationCurveValue.easeOut,
          maxLines: 5,
          hintText: 'Capture a thought',
          buttons: [],
        ).encode(),
      ),
      eventBindings: const [],
      parentData: const NoParentData(),
      children: const [2],
      localRevision: 1,
      deliveryGeneration: 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RendererResourceScope(
          resources: resources,
          child: Scaffold(
            floatingActionButton: Builder(
              builder: (context) =>
                  registry.build(context, node, [const Icon(Icons.add)], null),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(UnsupportedNativeWidget), findsNothing);
    expect(find.byTooltip('Open Capture'), findsOneWidget);
    await tester.tap(find.byTooltip('Open Capture'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final checkSurface in [false, true]) {
      testWidgets(
        'Capture sheet ${checkSurface ? "surface" : "FAB visibility"} $brightness',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: Scaffold(floatingActionButton: captureWidget()),
            ),
          );
          await tester.tap(find.byTooltip('Open Capture'));
          await tester.pumpAndSettle();
          if (checkSurface) {
            final editorMaterial = tester
                .widgetList<Material>(
                  find.ancestor(
                    of: find.byType(TextField),
                    matching: find.byType(Material),
                  ),
                )
                .firstWhere(
                  (material) => material.type != MaterialType.transparency,
                );
            final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
            final sheetContext = tester.element(find.byType(BottomSheet));
            final sheetColor =
                sheet.backgroundColor ??
                Theme.of(sheetContext).bottomSheetTheme.backgroundColor ??
                Theme.of(sheetContext).colorScheme.surfaceContainerLow;
            expect(editorMaterial.color, sheetColor);
          } else {
            expect(find.byTooltip('Open Capture'), findsNothing);
          }
        },
      );
    }
  }

  compactNavigationTests();
  retainedRootScrollTests();
  for (final enlarged in [false, true]) {
    testWidgets(
      'Capture modal dismissal, destination removal, and save reset enlarged=$enlarged',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(enlarged ? 320 : 390, 900);
        tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
        tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewInsets);
        var active = true;
        var visible = true;
        var draft = '';
        var captureKey = 0;
        late StateSetter update;
        Widget app() => MaterialApp(
          theme: ThemeData(
            brightness: enlarged ? Brightness.dark : Brightness.light,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(enlarged ? 3.2 : 1),
              highContrast: enlarged,
              disableAnimations: true,
            ),
            child: Directionality(
              textDirection: enlarged ? TextDirection.rtl : TextDirection.ltr,
              child: child!,
            ),
          ),
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return JournalRootScroll(
                destination: active ? 0 : 1,
                favoritesRevision: 0,
                favoritesAnchorOffset: 0,
                navigationVisible: visible,
                duration: Duration.zero,
                active: true,
                onScroll: (_, _, _) {},
                onNonScrollable: (_) {},
                child: Scaffold(
                  body: const Text('Root'),
                  bottomNavigationBar: JournalNavigationBar(
                    selectedIndex: active ? 0 : 1,
                    onDestinationSelected: (index) =>
                        setState(() => active = index == 0),
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.view_day_outlined),
                        label: 'Journals',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.star),
                        label: 'Favorites',
                      ),
                    ],
                  ),
                  floatingActionButton: active
                      ? captureWidget(
                          key: ValueKey(captureKey),
                          onChanged: (value) => draft = value,
                        )
                      : null,
                ),
              );
            },
          ),
        );
        await tester.pumpWidget(app());
        await tester.tap(find.byTooltip('Open Capture'));
        await tester.pumpAndSettle();
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        tester.view.padding = const FakeViewPadding(top: 47);
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byType(TextField)).bottom,
          lessThanOrEqualTo(600),
        );
        expect(tester.takeException(), isNull);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        await tester.enterText(find.byType(TextField), 'Edited draft');
        update(() => visible = false);
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byType(JournalNavigationBar)).height, 34);
        expect(
          tester.getRect(find.byType(TextField)).bottom,
          lessThanOrEqualTo(600),
        );
        update(() => visible = true);
        await tester.pumpAndSettle();
        Navigator.of(tester.element(find.byType(TextField))).pop();
        tester.view.viewInsets = const FakeViewPadding();
        await tester.pumpAndSettle();
        expect(find.byTooltip('Open Capture'), findsOneWidget);
        await tester.tap(destinationTooltip('Favorites'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        expect(find.byTooltip('Open Capture'), findsNothing);
        expect(draft, 'Edited draft');
        update(() => visible = false);
        tester.view.viewInsets = const FakeViewPadding();
        tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Open Capture'), findsNothing);
        expect(tester.getSize(find.byType(JournalNavigationBar)).height, 34);
        update(() => active = true);
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        await tester.tap(find.byTooltip('Open Capture'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        await tester.enterText(find.byType(TextField), 'Saved draft');
        update(() => captureKey++);
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        await tester.tap(find.byTooltip('Open Capture'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'Root retains independent scroll offsets and applies refreshed anchor delta',
    (tester) async {
      var destination = 0;
      var revision = 1;
      var anchorOffset = 0.0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return JournalRootScroll(
                navigationVisible: true,
                duration: Duration.zero,
                active: true,
                onScroll: (_, _, _) {},
                onNonScrollable: (_) {},
                destination: destination,
                favoritesRevision: revision,
                favoritesAnchorOffset: anchorOffset,
                child: Builder(
                  builder: (context) => Scaffold(
                    body: ListView.builder(
                      key: const ValueKey("root-scroll"),
                      controller: PrimaryScrollController.of(context),
                      itemExtent: 60,
                      itemCount: 100,
                      itemBuilder: (_, i) => Text('Row $i'),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      double offset() => tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .pixels;
      final journals = offset();
      update(() => destination = 1);
      await tester.pumpAndSettle();
      expect(offset(), 0);
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      final favorites = offset();
      update(() => destination = 0);
      await tester.pumpAndSettle();
      expect(offset(), closeTo(journals, 1));
      update(() => destination = 1);
      await tester.pumpAndSettle();
      expect(offset(), closeTo(favorites, 1));
      update(() {
        revision++;
        anchorOffset = 120;
      });
      await tester.pumpAndSettle();
      expect(offset(), closeTo(favorites + 120, 1));
      expect(tester.takeException(), isNull);
    },
  );
}

Finder destinationTooltip(String label) => find.byWidgetPredicate(
  (widget) => widget is Tooltip && widget.message == label,
);

void compactNavigationTests() {
  for (final wide in [false, true]) {
    for (final dark in [false, true]) {
      for (final inset in [0.0, 34.0]) {
        testWidgets(
          'Compact navigation geometry and access wide=$wide dark=$dark inset=$inset',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(wide ? 900 : 320, 900);
            tester.view.viewPadding = FakeViewPadding(bottom: inset);
            tester.view.padding = FakeViewPadding(bottom: inset);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetViewPadding);
            addTearDown(tester.view.resetPadding);
            var visible = true;
            var selected = 0;
            late StateSetter update;
            final semantics = tester.ensureSemantics();
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: const Color(0xff00262f),
                    brightness: dark ? Brightness.dark : Brightness.light,
                    contrastLevel: 1,
                  ),
                ),
                home: StatefulBuilder(
                  builder: (context, setState) {
                    update = setState;
                    return MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        textScaler: TextScaler.linear(3.2),
                        highContrast: true,
                        disableAnimations: wide,
                      ),
                      child: Directionality(
                        textDirection: wide
                            ? TextDirection.rtl
                            : TextDirection.ltr,
                        child: JournalRootScroll(
                          destination: selected,
                          favoritesRevision: 0,
                          favoritesAnchorOffset: 0,
                          navigationVisible: visible,
                          duration: const Duration(milliseconds: 200),
                          active: true,
                          onScroll: (_, _, _) {},
                          onNonScrollable: (_) {},
                          child: Scaffold(
                            body: const SizedBox.expand(key: ValueKey('body')),
                            bottomNavigationBar: JournalNavigationBar(
                              selectedIndex: selected,
                              onDestinationSelected: (index) =>
                                  update(() => selected = index),
                              destinations: const [
                                NavigationDestination(
                                  icon: Icon(Icons.view_day_outlined, size: 24),
                                  label: 'Journals',
                                ),
                                NavigationDestination(
                                  icon: Icon(Icons.star, size: 24),
                                  label: 'Favorites',
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
            await tester.pumpAndSettle();
            final bar = find.byType(NavigationBar);
            expect(
              tester.getSize(find.byType(JournalNavigationBar)).height,
              44 + inset,
            );
            expect(
              tester.widget<NavigationBar>(bar).labelBehavior,
              NavigationDestinationLabelBehavior.alwaysHide,
            );
            for (final label in ['Journals', 'Favorites']) {
              final target = destinationTooltip(label);
              final bounds = tester.getRect(target);
              expect(bounds.height, greaterThanOrEqualTo(44));
              expect(bounds.width, (wide ? 900 : 320) / 2);
              final data = tester.getSemantics(target).getSemanticsData();
              expect(data.label, contains(label));
              expect(data.hasAction(SemanticsAction.tap), isTrue);
            }
            final tooltip = tester.widget<Tooltip>(
              destinationTooltip('Favorites'),
            );
            expect(tooltip.message, 'Favorites');
            expect(
              MediaQuery.textScalerOf(
                tester.element(destinationTooltip('Favorites')),
              ).scale(10),
              32,
            );
            final indicator = tester.getRect(
              find.byType(NavigationIndicator).first,
            );
            final bounds = tester.getRect(bar);
            expect(indicator.top, greaterThanOrEqualTo(bounds.top));
            expect(indicator.bottom, lessThanOrEqualTo(bounds.bottom));
            final selectedData = tester
                .getSemantics(destinationTooltip('Journals'))
                .getSemanticsData();
            expect(selectedData.flagsCollection.isSelected, Tristate.isTrue);
            final unselectedData = tester
                .getSemantics(destinationTooltip('Favorites'))
                .getSemanticsData();
            expect(unselectedData.flagsCollection.isSelected, Tristate.isFalse);
            for (final glyph in [Icons.view_day_outlined, Icons.star]) {
              final icon = find.byIcon(glyph);
              expect(tester.getSize(icon), const Size(24, 24));
              final foreground =
                  (tester.widget<Icon>(icon).color ??
                          IconTheme.of(tester.element(icon)).color)!
                      .computeLuminance();
              final theme = Theme.of(tester.element(icon));
              final background =
                  (glyph == Icons.view_day_outlined
                          ? (tester
                                    .widget<NavigationIndicator>(
                                      find.byType(NavigationIndicator).first,
                                    )
                                    .color ??
                                theme.colorScheme.secondary)
                          : theme.colorScheme.surfaceContainer)
                      .computeLuminance();
              final ratio = foreground > background
                  ? (foreground + 0.05) / (background + 0.05)
                  : (background + 0.05) / (foreground + 0.05);
              expect(ratio, greaterThanOrEqualTo(3));
            }
            await tester.tapAt(
              tester.getRect(destinationTooltip('Favorites')).topLeft +
                  const Offset(2, 2),
            );
            await tester.pumpAndSettle();
            expect(selected, 1);
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(
              selected,
              0,
              reason: "keyboard traversal activates Journals",
            );
            expect(tester.takeException(), isNull);
            update(() => visible = false);
            await tester.pump();
            expect(destinationTooltip('Favorites').hitTestable(), findsNothing);
            expect(find.semantics.byLabel(RegExp('Favorites')), findsNothing);
            await tester.pumpAndSettle();
            expect(
              tester.getRect(find.byKey(const ValueKey('body'))).bottom,
              900 - inset,
            );
            final hiddenSelection = selected;
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            expect(selected, hiddenSelection);
            update(() => visible = true);
            await tester.pumpAndSettle();
            expect(
              tester.getSize(find.byType(JournalNavigationBar)).height,
              44 + inset,
            );
            expect(tester.takeException(), isNull);
            semantics.dispose();
          },
        );
      }
    }
  }

  testWidgets(
    'Native root accepts touch, wheel and fling but excludes restoration and layout',
    (tester) async {
      var destination = 0;
      var revision = 0;
      var anchor = 0.0;
      var visible = true;
      var active = true;
      var count = 100;
      late StateSetter update;
      final samples = <(int, double, double)>[];
      final empty = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return JournalRootScroll(
                destination: destination,
                favoritesRevision: revision,
                favoritesAnchorOffset: anchor,
                navigationVisible: visible,
                duration: const Duration(milliseconds: 200),
                active: active,
                onScroll: (tab, pixels, delta) =>
                    samples.add((tab, pixels, delta)),
                onNonScrollable: empty.add,
                child: Builder(
                  builder: (context) => Scaffold(
                    body: ListView.builder(
                      key: const ValueKey("root-scroll"),
                      controller: PrimaryScrollController.of(context),
                      itemExtent: 60,
                      itemCount: count,
                      itemBuilder: (_, i) => Text('Row $i'),
                    ),
                    bottomNavigationBar: JournalNavigationBar(
                      selectedIndex: destination,
                      onDestinationSelected: (_) {},
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.view_day_outlined),
                          label: 'Journals',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.star),
                          label: 'Favorites',
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      ScrollPosition position() =>
          tester.state<ScrollableState>(find.byType(Scrollable)).position;
      await tester.drag(find.byType(ListView), const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(samples, isNotEmpty);
      expect(samples.every((s) => s.$1 == 0), isTrue);
      samples.clear();
      position().jumpTo(900);
      await tester.pumpAndSettle();
      expect(samples, isEmpty);
      final animation = position().animateTo(
        1000,
        duration: const Duration(milliseconds: 100),
        curve: Curves.linear,
      );
      await tester.pumpAndSettle();
      await animation;
      expect(samples, isEmpty);
      final offset = position().pixels;
      update(() => visible = false);
      await tester.pump(const Duration(milliseconds: 80));
      update(() => visible = true);
      await tester.pump(const Duration(milliseconds: 60));
      update(() => visible = false);
      await tester.pumpAndSettle();
      expect(position().pixels, offset);
      expect(samples, isEmpty);
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpAndSettle();
      expect(position().pixels, offset);
      expect(samples, isEmpty, reason: 'window resizing is not scroll intent');
      update(() => destination = 1);
      await tester.pumpAndSettle();
      expect(position().pixels, 0);
      expect(samples, isEmpty);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(ListView)),
          scrollDelta: const Offset(0, 80),
        ),
      );
      await tester.pumpAndSettle();
      expect(samples, isNotEmpty);
      expect(samples.every((s) => s.$1 == 1), isTrue);
      samples.clear();
      final favorite = position().pixels;
      update(() {
        revision++;
        anchor = 120;
      });
      await tester.pumpAndSettle();
      expect(position().pixels, favorite + 120);
      expect(samples, isEmpty);
      await tester.fling(find.byType(ListView), const Offset(0, -150), 1800);
      final beforeFling = samples.length;
      await tester.pumpAndSettle();
      expect(samples.length, greaterThan(beforeFling));
      samples.clear();
      final trackpad = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      final center = tester.getCenter(find.byType(ListView));
      await trackpad.panZoomStart(center);
      await trackpad.panZoomUpdate(
        center,
        pan: const Offset(0, -80),
        timeStamp: const Duration(milliseconds: 20),
      );
      await trackpad.panZoomUpdate(
        center,
        pan: const Offset(0, -160),
        timeStamp: const Duration(milliseconds: 40),
      );
      await trackpad.panZoomEnd(timeStamp: const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(samples, isNotEmpty);
      samples.clear();
      position().jumpTo(0);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 180));
      await tester.pumpAndSettle();
      expect(position().pixels, 0);
      expect(
        samples.any((sample) => sample.$2 <= 0),
        isTrue,
        reason: 'user overscroll still reports the top on clamping platforms',
      );
      samples.clear();
      position().jumpTo(20);
      await tester.pumpAndSettle();
      expect(samples, isEmpty);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(ListView)),
          scrollDelta: const Offset(0, -40),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        samples.any((sample) => sample.$2 <= 0),
        isTrue,
        reason: 'wheel movement reaching the top remains observable',
      );
      samples.clear();
      update(() => active = false);
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(samples, isEmpty);
      await tester.fling(find.byType(ListView), const Offset(0, -120), 1600);
      update(() => active = true);
      await tester.pumpAndSettle();
      expect(
        samples,
        isEmpty,
        reason: 'return does not resume covered scroll intent',
      );
      update(() {
        count = 0;
      });
      await tester.pumpAndSettle();
      expect(empty, contains(1));
      expect(samples, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

class _PaintOffset extends SingleChildRenderObjectWidget {
  const _PaintOffset({required this.record, required super.child});
  final VoidCallback record;
  @override
  RenderObject createRenderObject(BuildContext context) => _Recorder(record);
  @override
  void updateRenderObject(BuildContext context, _Recorder renderObject) {
    renderObject.record = record;
    renderObject.markNeedsPaint();
  }
}

class _Recorder extends RenderProxyBox {
  _Recorder(this.record);
  VoidCallback record;
  @override
  void paint(PaintingContext context, Offset offset) {
    record();
    super.paint(context, offset);
  }
}

class _Session {
  int destination = 0, revision = 0, graph = 0;
  double anchor = 0;
  bool active = true;
  final lengths = [3000.0, 3000.0];
  final samples = <(int, double, double)>[];
  final paints = <double>[];
  late StateSetter update;
  late ScrollController controller;
  ScrollPosition get position => controller.position;

  Widget app() => MaterialApp(
    home: StatefulBuilder(
      builder: (context, setState) {
        update = setState;
        return JournalRootScroll(
          key: ValueKey(graph),
          navigationVisible: true,
          duration: Duration.zero,
          active: active,
          destination: destination,
          favoritesRevision: revision,
          favoritesAnchorOffset: anchor,
          onScroll: (d, p, delta) => samples.add((d, p, delta)),
          onNonScrollable: (_) {},
          child: Builder(
            builder: (context) {
              controller = PrimaryScrollController.of(context);
              return Scaffold(
                body: _PaintOffset(
                  record: () => paints.add(position.pixels),
                  child: CustomScrollView(
                    key: const ValueKey('root-scroll'),
                    controller: controller,
                    slivers: [
                      SliverAppBar(
                        key: const ValueKey('header'),
                        pinned: true,
                        title: Text(
                          destination == 0 ? 'Journals' : 'Favorites',
                        ),
                        actions: [
                          IconButton(
                            onPressed: () {},
                            icon: const Icon(Icons.person),
                          ),
                        ],
                      ),
                      SliverToBoxAdapter(
                        child: SizedBox(height: lengths[destination]),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    ),
  );

  Future<void> change(WidgetTester tester, VoidCallback action) async {
    paints.clear();
    samples.clear();
    update(action);
    await tester.pump();
  }

  void paintedAt(double offset) {
    expect(paints, isNotEmpty);
    expect(paints, everyElement(closeTo(offset, 0.01)));
    expect(position.pixels, closeTo(offset, 0.01));
    expect(samples, isEmpty, reason: 'Restoration is not user scroll intent');
  }
}

void retainedRootScrollTests() {
  testWidgets(
    'One native position restores equal-size destinations before paint',
    (tester) async {
      final session = _Session();
      await tester.pumpWidget(session.app());
      final position = session.position;
      final header = tester.state(find.byType(SliverAppBar));
      final account = tester.element(find.byType(IconButton));
      session.position.jumpTo(700);
      await tester.pump();
      await session.change(tester, () => session.destination = 1);
      session.paintedAt(0);
      expect(session.position, same(position));
      expect(tester.state(find.byType(SliverAppBar)), same(header));
      expect(tester.element(find.byType(IconButton)), same(account));
      session.position.jumpTo(350);
      await tester.pump();
      await session.change(tester, () => session.destination = 0);
      session.paintedAt(700);
      await session.change(tester, () => session.destination = 1);
      session.paintedAt(350);
    },
  );

  for (final length in [0.0, 200.0, 1000.0, 5000.0]) {
    testWidgets('Restoration clamps against target content length $length', (
      tester,
    ) async {
      final session = _Session();
      await tester.pumpWidget(session.app());
      session.position.jumpTo(1800);
      await tester.pump();
      await session.change(tester, () => session.destination = 1);
      session.position.jumpTo(900);
      await tester.pump();
      await session.change(tester, () {
        session.destination = 0;
        session.lengths[0] = length;
      });
      session.paintedAt(1800.0.clamp(0, session.position.maxScrollExtent));
      await session.change(tester, () => session.destination = 1);
      session.paintedAt(900);
    });
  }

  testWidgets(
    'Favorites revisions correct active and inactive offsets before paint',
    (tester) async {
      final session = _Session();
      await tester.pumpWidget(session.app());
      session.position.jumpTo(700);
      await tester.pump();
      await session.change(tester, () => session.destination = 1);
      session.position.jumpTo(300);
      await tester.pump();
      await session.change(tester, () {
        session.revision++;
        session.anchor = 120;
      });
      session.paintedAt(420);
      await session.change(tester, () => session.destination = 0);
      session.paintedAt(700);
      await session.change(tester, () {
        session.revision++;
        session.anchor = 200;
      });
      expect(session.position.pixels, 700);
      expect(session.samples, isEmpty);
      await session.change(tester, () => session.destination = 1);
      session.paintedAt(500);
      await session.change(tester, () {
        session.revision++;
        session.anchor = -1000;
      });
      session.paintedAt(0);
    },
  );

  testWidgets(
    'Rapid selection replaces pending correction and graph resets both offsets',
    (tester) async {
      final session = _Session();
      await tester.pumpWidget(session.app());
      session.position.jumpTo(700);
      await tester.pump();
      await session.change(tester, () => session.destination = 1);
      session.position.jumpTo(300);
      await tester.pump();
      session.update(() => session.destination = 0);
      await tester.pump(Duration.zero, EnginePhase.build);
      session.update(() => session.destination = 1);
      await tester.pump(Duration.zero, EnginePhase.build);
      await session.change(tester, () => session.destination = 0);
      session.paintedAt(700);
      await session.change(tester, () => session.destination = 1);
      session.paintedAt(300);
      final oldPosition = session.position;
      await session.change(tester, () => session.graph++);
      session.paintedAt(0);
      expect(session.position, isNot(same(oldPosition)));
      await session.change(tester, () => session.destination = 0);
      session.paintedAt(0);
    },
  );

  testWidgets(
    'Switching during a fling cancels outgoing motion and user samples',
    (tester) async {
      final session = _Session();
      await tester.pumpWidget(session.app());
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, -400),
        1800,
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(session.position.isScrollingNotifier.value, isTrue);
      final outgoing = session.position.pixels;
      await session.change(tester, () => session.destination = 1);
      session.paintedAt(0);
      await tester.pump(const Duration(milliseconds: 80));
      expect(session.position.pixels, 0);
      expect(session.position.isScrollingNotifier.value, isFalse);
      expect(session.samples, isEmpty);
      await session.change(tester, () => session.destination = 0);
      session.paintedAt(outgoing);
    },
  );
}
