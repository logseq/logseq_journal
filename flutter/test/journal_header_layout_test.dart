import 'dart:io';
import 'dart:ui' show Tristate, ImageByteFormat, SemanticsAction;

import 'package:bonsai_flutter/bonsai_flutter.dart';
import 'package:bonsai_flutter_logseq_journal_host/journal_widget_registry.dart';
// ignore: depend_on_referenced_packages
import 'package:material_ui/material_ui.dart';
// ignore: depend_on_referenced_packages
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory frames;
  favoritesVisualTests(() => frames);
  retainedApplicationHeaderTests(() => frames);
  setUpAll(() async {
    var directory = File(Platform.resolvedExecutable).parent;
    while (!Directory(
      '${directory.path}/bin/cache/artifacts/material_fonts',
    ).existsSync()) {
      if (directory.parent.path == directory.path) {
        throw StateError('Flutter material fonts are unavailable');
      }
      directory = directory.parent;
    }
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            Future.value(
              ByteData.sublistView(
                File(
                  '${directory.path}/bin/cache/artifacts/material_fonts/${font.value}',
                ).readAsBytesSync(),
              ),
            ),
          ))
          .load();
    }
    frames = await Directory.systemTemp.createTemp('journal-header-frames-');
    final result = await Process.run(
      'dune',
      ['exec', 'test/journal_semantics_test.exe'],
      workingDirectory: '..',
      environment: {
        'JOURNAL_HEADER_FRAME_DIR': frames.path,
        'JOURNAL_FAVORITES_FRAME_DIR': frames.path,
      },
    );
    final rootResult = await Process.run(
      'python3',
      ['tool/test_macos_regressions.py', '--case', 'application_dispatch'],
      workingDirectory: '..',
      environment: {'JOURNAL_ROOT_FRAME_DIR': frames.path},
    );
    expect(
      rootResult.exitCode,
      0,
      reason: '${rootResult.stdout}\n${rootResult.stderr}',
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
  tearDownAll(() => frames.delete(recursive: true));

  for (final brightness in Brightness.values) {
    for (final highContrast in [false, true]) {
      for (final layout in [
        (width: 390.0, scale: 1.0, direction: TextDirection.ltr),
        (width: 320.0, scale: 1.0, direction: TextDirection.ltr),
        (width: 320.0, scale: 3.2, direction: TextDirection.ltr),
        (width: 320.0, scale: 3.2, direction: TextDirection.rtl),
        (width: 390.0, scale: 3.2, direction: TextDirection.ltr),
        (width: 720.0, scale: 3.2, direction: TextDirection.rtl),
      ]) {
        for (final withError in [false, true]) {
          testWidgets('OCaml header edge $brightness contrast=$highContrast '
              '$layout error=$withError', (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(layout.width, 600);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetPhysicalSize);
            final store = NodeStore();
            final events = <RendererEvent>[];
            final scheme = ColorScheme.fromSeed(
              seedColor: const Color(0xff00262f),
              brightness: brightness,
              contrastLevel: highContrast ? 1 : 0,
            );
            final scope = withError ? 'error' : 'account';
            Future<void> applyPhase(int phase) async {
              store.apply(
                FrameCodec.decode(
                  File(
                    '${frames.path}/header-${layout.width.toInt()}-${layout.scale.toString().replaceAll(RegExp(r'\.0$'), '')}-$highContrast-$scope-$phase.bin',
                  ).readAsBytesSync(),
                ),
              );
              await tester.pump();
            }

            await applyPhase(0);
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(colorScheme: scheme, useMaterial3: true),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: Size(layout.width, 600),
                    padding: const EdgeInsets.only(top: 47),
                    textScaler: TextScaler.linear(layout.scale),
                    highContrast: highContrast,
                  ),
                  child: Directionality(
                    textDirection: layout.direction,
                    child: RepaintBoundary(
                      key: const ValueKey('header-screen'),
                      child: Scaffold(
                        body: BonsaiFlutterView(
                          store: store,
                          registry: createJournalWidgetRegistry(),
                          onEvent: events.add,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            final scrollable = tester.state<ScrollableState>(
              find.byType(Scrollable).first,
            );
            final position = scrollable.position;
            final maxScrollExtent = position.maxScrollExtent;
            final anchorPositions = <double, double>{};
            Uint8List? inactivePixels;
            Rect? initialTitle;
            Rect? initialAccount;
            for (var phase = 0; phase < 5; phase++) {
              final beforeOffset = position.pixels;
              if (phase > 0) await applyPhase(phase);
              expect(scrollable.position, same(position));
              expect(position.pixels, beforeOffset);
              expect(position.maxScrollExtent, maxScrollExtent);
              final connecting = phase == 1 || phase == 3;
              for (final offset in [0.0, 80.0, 1200.0]) {
                position.jumpTo(offset);
                await tester.pump();
                final appBarFinder = find.byType(SliverAppBar);
                final appBar = tester.widget<SliverAppBar>(appBarFinder);
                expect(appBar.pinned, isTrue);
                expect(appBar.floating, isFalse);
                expect(appBar.snap, isFalse);
                expect(appBar.centerTitle, isTrue);
                expect(appBar.actions, hasLength(withError ? 2 : 1));
                expect(appBar.flexibleSpace, isNull);
                expect(appBar.backgroundColor, isNull);
                expect(appBar.foregroundColor, isNull);
                expect(
                  tester
                      .widgetList<M3ETooltip>(find.byType(M3ETooltip))
                      .map((tooltip) => tooltip.message),
                  unorderedEquals([
                    "Account menu",
                    if (withError) "Error info",
                  ]),
                );
                final toolbar = tester.renderObject<RenderSliver>(appBarFinder);
                final headerBottom = appBar.toolbarHeight + 55;
                expect(
                  toolbar.geometry!.paintExtent,
                  closeTo(headerBottom, 0.01),
                );
                final title = find.text('2026.08.09');
                expect(title, findsOneWidget);
                expect(find.text('SUN'), findsOneWidget);
                final weekdayRect = tester.getRect(find.text('SUN'));
                expect(
                  weekdayRect.center.dy,
                  closeTo(tester.getRect(title).center.dy, 0.1),
                );
                expect(find.textContaining('Today'), findsNothing);
                expect(tester.widget<Text>(title).maxLines, 1);
                final titleRect = tester.getRect(title);
                final account = find.bySemanticsLabel('Account menu');
                final accountRect = tester.getRect(account);
                initialTitle ??= titleRect;
                initialAccount ??= accountRect;
                expect(titleRect, initialTitle);
                expect(accountRect, initialAccount);
                expect(titleRect.overlaps(accountRect), isFalse);
                expect(accountRect.width, greaterThanOrEqualTo(44));
                expect(accountRect.height, greaterThanOrEqualTo(44));
                if (withError) {
                  final errorRect = tester.getRect(
                    find.bySemanticsLabel('Error info'),
                  );
                  expect(titleRect.overlaps(errorRect), isFalse);
                  expect(errorRect.overlaps(accountRect), isFalse);
                  expect(errorRect.width, greaterThanOrEqualTo(44));
                  expect(errorRect.height, greaterThanOrEqualTo(44));
                }
                if (layout.width == 390 && layout.scale == 1) {
                  expect(
                    titleRect.expandToInclude(weekdayRect).center.dx,
                    closeTo(layout.width / 2, 0.5),
                  );
                }
                final spoken = tester.getSemantics(title).getSemanticsData();
                expect(spoken.label, contains('2026.08.09'));
                expect(spoken.label, contains('SUN'));
                expect('2026.08.09'.allMatches(spoken.label), hasLength(1));
                expect('SUN'.allMatches(spoken.label), hasLength(1));
                expect(spoken.label, isNot(contains('Today')));
                expect(spoken.hasAction(SemanticsAction.tap), isFalse);
                expect(spoken.flagsCollection.isFocused, Tristate.none);
                final indicator = find.byType(M3EProgressIndicator);
                expect(indicator, connecting ? findsOneWidget : findsNothing);
                if (connecting) {
                  final progress = tester.widget<M3EProgressIndicator>(
                    indicator,
                  );
                  expect(progress.value, isNull);
                  final rect = tester.getRect(indicator);
                  expect(rect.left, 0);
                  expect(rect.right, layout.width);
                  expect(rect.top, closeTo(headerBottom, 0.01));
                  expect(rect.height, 2);
                  expect(rect.top, greaterThan(titleRect.bottom));
                  expect(
                    find.ancestor(of: indicator, matching: find.byType(AppBar)),
                    findsNothing,
                  );
                }
                final anchorY = tester
                    .getTopLeft(
                      find.text('Timeline anchor', skipOffstage: false),
                    )
                    .dy;
                anchorPositions.putIfAbsent(offset, () => anchorY);
                expect(anchorY, anchorPositions[offset]);
                if (offset == 0) {
                  expect(anchorY, closeTo(headerBottom + 2, 0.01));
                }
                if (layout.width == 390 &&
                    layout.scale == 1 &&
                    !withError &&
                    offset == 0 &&
                    phase < 2) {
                  await tester.pump(const Duration(milliseconds: 500));
                  final pixels = (await tester.runAsync(() async {
                    final boundary = tester.renderObject<RenderRepaintBoundary>(
                      find.byKey(const ValueKey('header-screen')),
                    );
                    final image = await boundary.toImage();
                    final outputDirectory =
                        Platform.environment['JOURNAL_DATE_VISUAL_DIR'];
                    if (outputDirectory != null) {
                      final png = await image.toByteData(
                        format: ImageByteFormat.png,
                      );
                      await File(
                        '$outputDirectory/header-${brightness.name}-$highContrast-$phase.png',
                      ).writeAsBytes(png!.buffer.asUint8List());
                    }
                    final data = await image.toByteData();
                    image.dispose();
                    return data!.buffer.asUint8List();
                  }))!;
                  if (phase == 0) {
                    inactivePixels = pixels;
                  } else {
                    final changedRows = <int>{};
                    for (var y = 100; y < 125; y++) {
                      for (var x = 0; x < 390; x++) {
                        final index = (y * 390 + x) * 4;
                        if (pixels[index] != inactivePixels![index] ||
                            pixels[index + 1] != inactivePixels[index + 1] ||
                            pixels[index + 2] != inactivePixels[index + 2]) {
                          changedRows.add(y);
                        }
                      }
                    }
                    expect(
                      changedRows,
                      {111, 112},
                      reason:
                          'progress must paint only inside its two-pixel bottom region',
                    );
                  }
                }
                final visualDirectory =
                    Platform.environment['JOURNAL_DATE_VISUAL_DIR'];
                if (visualDirectory != null &&
                    withError &&
                    phase == 1 &&
                    offset == 0) {
                  await tester.runAsync(() async {
                    final boundary = tester.renderObject<RenderRepaintBoundary>(
                      find.byKey(const ValueKey('header-screen')),
                    );
                    final image = await boundary.toImage();
                    final png = await image.toByteData(
                      format: ImageByteFormat.png,
                    );
                    await File(
                      '$visualDirectory/actions-${brightness.name}-$highContrast-${layout.width.toInt()}-${layout.scale}-${layout.direction.name}.png',
                    ).writeAsBytes(png!.buffer.asUint8List());
                    image.dispose();
                  });
                }
                expect(find.byType(Divider), findsNothing);
                expect(tester.takeException(), isNull);
              }
            }
            events.clear();
            await tester.tap(find.bySemanticsLabel('Account menu'));
            expect(events, hasLength(1));
            expect(events.single.handlerId, isPositive);
            if (withError) {
              events.clear();
              await tester.tap(find.bySemanticsLabel('Error info'));
              expect(events, hasLength(1));
            }
          });
        }
      }
    }
  }
  for (final dark in [false, true]) {
    for (final highContrast in [false, true]) {
      for (final layout in [
        (390.0, 1.0, false),
        (320.0, 3.2, true),
        (390.0, 3.2, false),
        (720.0, 3.2, true),
      ]) {
        final (width, scale, rtl) = layout;
        final large = scale > 1;
        for (final preset in ['dense', 'balanced', 'comfortable']) {
          testWidgets(
            'date and rail preview dark=$dark contrast=$highContrast layout=$layout $preset',
            (tester) async {
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(width, 844);
              addTearDown(tester.view.resetDevicePixelRatio);
              addTearDown(tester.view.resetPhysicalSize);
              final store = NodeStore();
              store.apply(
                FrameCodec.decode(
                  File(
                    '${frames.path}/timeline-${width.toInt()}-${large ? '3.2' : '1'}-$highContrast-$dark-$rtl-$preset.bin',
                  ).readAsBytesSync(),
                ),
              );
              await tester.pumpWidget(
                MaterialApp(
                  theme: ThemeData(
                    colorScheme: ColorScheme.fromSeed(
                      seedColor: const Color(0xff00262f),
                      brightness: dark ? Brightness.dark : Brightness.light,
                      contrastLevel: highContrast ? 1 : 0,
                    ),
                    useMaterial3: true,
                  ),
                  home: MediaQuery(
                    data: MediaQueryData(
                      size: Size(width, 844),
                      padding: const EdgeInsets.only(top: 47),
                      textScaler: TextScaler.linear(scale),
                      highContrast: highContrast,
                    ),
                    child: Directionality(
                      textDirection: rtl
                          ? TextDirection.rtl
                          : TextDirection.ltr,
                      child: RepaintBoundary(
                        key: const ValueKey('date-preview'),
                        child: Scaffold(
                          body: BonsaiFlutterView(
                            store: store,
                            registry: createJournalWidgetRegistry(),
                            onEvent: (_) {},
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pump();
              expect(find.text('2026.09.06'), findsOneWidget);
              expect(find.text('SUN'), findsOneWidget);
              final headerDate = tester.renderObject<RenderParagraph>(
                find.text('2026.09.06'),
              );
              final historyDate = tester.renderObject<RenderParagraph>(
                find.text('2026.09.05'),
              );
              final headerWeekday = tester.renderObject<RenderParagraph>(
                find.text('SUN'),
              );
              final historyWeekday = tester.renderObject<RenderParagraph>(
                find.text('SAT'),
              );
              double renderedSize(RenderParagraph paragraph) =>
                  paragraph.textScaler.scale(paragraph.text.style!.fontSize!);
              expect(
                renderedSize(headerDate),
                closeTo(renderedSize(historyDate), 0.01),
              );
              expect(
                renderedSize(headerWeekday),
                closeTo(renderedSize(historyWeekday), 0.01),
              );
              expect(
                headerDate.text.style!.fontWeight,
                historyDate.text.style!.fontWeight,
              );
              expect(
                headerWeekday.text.style!.fontWeight,
                historyWeekday.text.style!.fontWeight,
              );
              expect(
                headerDate.text.style!.color,
                historyDate.text.style!.color,
              );
              expect(
                headerDate.size.height,
                closeTo(historyDate.size.height, 0.1),
              );
              expect(
                headerWeekday.size.height,
                closeTo(historyWeekday.size.height, 0.1),
              );
              for (final labels in [
                ('2026.09.06', 'SUN'),
                ('2026.09.05', 'SAT'),
              ]) {
                final dateRect = tester.getRect(find.text(labels.$1));
                final weekdayRect = tester.getRect(find.text(labels.$2));
                final gap = rtl
                    ? dateRect.left - weekdayRect.right
                    : weekdayRect.left - dateRect.right;
                expect(gap, closeTo(14, 0.1));
                final opacity = tester.widget<Opacity>(
                  find
                      .ancestor(
                        of: find.text(labels.$2),
                        matching: find.byType(Opacity),
                      )
                      .first,
                );
                expect(opacity.opacity, highContrast ? 0.85 : 0.50);
              }
              expect(headerDate.didExceedMaxLines, isFalse);
              expect(historyDate.didExceedMaxLines, isFalse);
              expect(
                tester.getRect(find.text('SUN')).center.dy,
                closeTo(tester.getRect(find.text('2026.09.06')).center.dy, 0.1),
              );
              expect(tester.takeException(), isNull);
              final scrollable = tester.state<ScrollableState>(
                find.byType(Scrollable).first,
              );
              for (final fraction in [0.0, 1.0]) {
                scrollable.position.jumpTo(
                  scrollable.position.maxScrollExtent * fraction,
                );
                await tester.pump();
                expect(tester.takeException(), isNull);
                final outputDirectory =
                    Platform.environment['JOURNAL_DATE_VISUAL_DIR'];
                if (outputDirectory != null) {
                  await tester.runAsync(() async {
                    final boundary = tester.renderObject<RenderRepaintBoundary>(
                      find.byKey(const ValueKey('date-preview')),
                    );
                    final image = await boundary.toImage();
                    final data = await image.toByteData(
                      format: ImageByteFormat.png,
                    );
                    image.dispose();
                    await File(
                      '$outputDirectory/timeline-$dark-$highContrast-$large-${width.toInt()}-$preset-${fraction.toInt()}.png',
                    ).writeAsBytes(data!.buffer.asUint8List());
                  });
                }
              }
            },
          );
        }
      }
    }
  }
}

void favoritesVisualTests(Directory Function() getFrames) {
  for (final layout in [
    (390.0, 1.0, false),
    (320.0, 1.0, false),
    (320.0, 3.2, false),
    (320.0, 3.2, true),
    (720.0, 1.0, false),
  ]) {
    for (final dark in [false, true]) {
      for (final contrast in [false, true]) {
        testWidgets(
          'Favorites native layout $layout dark=$dark contrast=$contrast',
          (tester) async {
            final (width, scale, rtl) = layout;
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 700);
            tester.view.viewPadding = const FakeViewPadding(
              top: 47,
              bottom: 34,
            );
            tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
            addTearDown(tester.view.resetViewPadding);
            addTearDown(tester.view.resetPadding);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetPhysicalSize);
            final store = NodeStore();
            final scaleName = scale.toString().replaceAll(RegExp(r'\.0$'), '');
            store.apply(
              FrameCodec.decode(
                File(
                  '${getFrames().path}/favorites-${width.toInt()}-$scaleName-$rtl-$dark-$contrast.bin',
                ).readAsBytesSync(),
              ),
            );
            final events = <RendererEvent>[];
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(
                  useMaterial3: true,
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: const Color(0xff00262f),
                    brightness: dark ? Brightness.dark : Brightness.light,
                    contrastLevel: contrast ? 1 : 0,
                  ),
                ),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 700),
                    padding: const EdgeInsets.only(top: 47, bottom: 34),
                    textScaler: TextScaler.linear(scale),
                    highContrast: contrast,
                    disableAnimations: true,
                  ),
                  child: Directionality(
                    textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                    child: RepaintBoundary(
                      key: const ValueKey('favorites-screen'),
                      child: BonsaiFlutterView(
                        store: store,
                        registry: createJournalWidgetRegistry(),
                        onEvent: events.add,
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 500));
            expect(tester.takeException(), isNull);
            expect(find.text('Design notes'), findsOneWidget);
            expect(find.text('Favorites'), findsNWidgets(2));
            expect(find.text('Journals'), findsOneWidget);
            expect(find.byTooltip('Open Capture'), findsNothing);
            expect(find.byType(TextField), findsNothing);
            final source = tester.renderObject<RenderParagraph>(
              find.text('Design notes'),
            );
            expect(
              source.constraints.maxWidth,
              greaterThanOrEqualTo(width.clamp(0, 720) - 80),
            );
            final bar = tester.widget<NavigationBar>(
              find.byType(NavigationBar),
            );
            expect(bar.height, 44);
            expect(
              bar.labelBehavior,
              NavigationDestinationLabelBehavior.alwaysHide,
            );
            expect(find.text(String.fromCharCode(0xf495)), findsOneWidget);
            for (final codePoint in [0xf495, 0xe5f9]) {
              final glyph = find.text(String.fromCharCode(codePoint));
              expect(tester.getSize(glyph), const Size(24, 24));
              final paragraph = tester.renderObject<RenderParagraph>(glyph);
              final foreground = paragraph.text.style!.color!
                  .computeLuminance();
              final theme = Theme.of(tester.element(glyph));
              final background =
                  (codePoint == 0xe5f9
                          ? (tester
                                    .widgetList<NavigationIndicator>(
                                      find.byType(NavigationIndicator),
                                    )
                                    .last
                                    .color ??
                                theme.colorScheme.secondary)
                          : theme.colorScheme.surfaceContainer)
                      .computeLuminance();
              final ratio = foreground > background
                  ? (foreground + 0.05) / (background + 0.05)
                  : (background + 0.05) / (foreground + 0.05);
              expect(ratio, greaterThanOrEqualTo(3));
            }
            final navigation = tester.getRect(find.byType(NavigationBar));
            expect(navigation.bottom, lessThanOrEqualTo(700 - 34));
            final semantics = tester.ensureSemantics();
            expect(
              tester
                  .getSemantics(find.text('Design notes'))
                  .getSemanticsData()
                  .hasAction(SemanticsAction.tap),
              isFalse,
            );
            events.clear();
            await tester.tap(find.text('Design notes'));
            await tester.pump();
            expect(
              events.where(
                (event) =>
                    event.eventTag != EventTagId.scrollNotification &&
                    event.eventTag != EventTagId.visibleRangeChanged,
              ),
              isEmpty,
              reason: events
                  .map(
                    (event) => "${event.eventTag}:${event.payload.runtimeType}",
                  )
                  .join(","),
            );
            final position = tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position;
            final before = position.pixels;
            await tester.drag(find.text('Design notes'), const Offset(-160, 0));
            await tester.pump();
            expect(position.pixels, before);
            expect(tester.takeException(), isNull);
            semantics.dispose();
            events.clear();
            await tester.tap(find.text(String.fromCharCode(0xf495)));
            await tester.pump();
            final selections = events
                .where(
                  (event) =>
                      event.eventTag ==
                      EventTagId.navigationDestinationSelected,
                )
                .toList();
            expect(selections, hasLength(1));
            expect((selections.single.payload as Int64EventPayload).value, 0);
            final output = Platform.environment['JOURNAL_FAVORITES_VISUAL_DIR'];
            if (output != null) {
              await tester.runAsync(() async {
                final boundary = tester.renderObject<RenderRepaintBoundary>(
                  find.byKey(const ValueKey('favorites-screen')),
                );
                final image = await boundary.toImage();
                final png = await image.toByteData(format: ImageByteFormat.png);
                await File(
                  '$output/favorites-${width.toInt()}-$scaleName-$rtl-$dark-$contrast.png',
                ).writeAsBytes(png!.buffer.asUint8List());
                image.dispose();
              });
            }
          },
        );
      }
    }
  }
}

void retainedApplicationHeaderTests(Directory Function() getFrames) {
  testWidgets('Consecutive application destinations retain header at the top', (
    tester,
  ) async {
    final store = NodeStore();
    final files =
        getFrames()
            .listSync()
            .whereType<File>()
            .where((file) => RegExp(r'/[0-9]{4}-').hasMatch(file.path))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    expect(files, isNotEmpty);
    State? header;
    Element? account;
    Element? progress;
    ScrollPosition? position;
    final observations = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: const ValueKey('retained-header-screen'),
          child: BonsaiFlutterView(
            store: store,
            registry: createJournalWidgetRegistry(),
            onEvent: (_) {},
          ),
        ),
      ),
    );
    for (final file in files) {
      store.apply(FrameCodec.decode(file.readAsBytesSync()));
      await tester.pump();
      if (find.byType(SliverAppBar).evaluate().isEmpty) continue;
      if (file.path.contains('-startup')) {
        await tester.pump(const Duration(milliseconds: 300));
        continue;
      }
      final currentHeader = tester.state(find.byType(SliverAppBar));
      final currentAccount = tester.element(
        find
            .descendant(
              of: find.byType(SliverAppBar),
              matching: find.byType(IconButton),
            )
            .last,
      );
      final currentPosition = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      header ??= currentHeader;
      account ??= currentAccount;
      position ??= currentPosition;
      expect(currentHeader, same(header), reason: file.path);
      expect(currentAccount, same(account), reason: file.path);
      expect(currentPosition, same(position), reason: file.path);
      expect(currentPosition.pixels, 0);
      if (file.path.contains('-sync')) {
        final currentProgress = tester.element(
          find.byType(M3EProgressIndicator),
        );
        progress ??= currentProgress;
        expect(currentProgress, same(progress));
      }
      final favorites = file.path.contains('-favorites');
      expect(
        find.descendant(
          of: find.byType(SliverAppBar),
          matching: find.text('Favorites'),
        ),
        favorites ? findsOneWidget : findsNothing,
      );
      Future<List<int>> headerPixels() async {
        return (await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('retained-header-screen')),
          );
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ImageByteFormat.rawRgba);
          final rows = bytes!.buffer
              .asUint8List()
              .take(image.width * 56 * 4)
              .toList();
          image.dispose();
          return rows;
        }))!;
      }

      final firstPaint = await headerPixels();
      for (final elapsed in [16, 16, 168]) {
        await tester.pump(Duration(milliseconds: elapsed));
        expect(
          await headerPixels(),
          firstPaint,
          reason: 'Header changed after its first painted frame: ${file.path}',
        );
      }
      observations.add(file.path);
      expect(tester.takeException(), isNull);
    }
    expect(observations.any((path) => path.contains('-favorites')), isTrue);
    expect(observations.any((path) => path.contains('-returned')), isTrue);
    expect(progress, isNotNull);
  });
}
