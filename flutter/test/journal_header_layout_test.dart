import 'dart:io';
import 'dart:ui' show Tristate, ImageByteFormat;

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
      environment: {'JOURNAL_HEADER_FRAME_DIR': frames.path},
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
                  weekdayRect.top,
                  greaterThanOrEqualTo(tester.getRect(title).bottom),
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
                  expect(titleRect.center.dx, closeTo(layout.width / 2, 0.5));
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
      for (final large in [false, true]) {
        for (final preset in ['dense', 'balanced', 'comfortable']) {
          testWidgets(
            'date and rail preview dark=$dark contrast=$highContrast large=$large $preset',
            (tester) async {
              final width = large ? 320.0 : 390.0;
              final scale = large ? 3.2 : 1.0;
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(width, 844);
              addTearDown(tester.view.resetDevicePixelRatio);
              addTearDown(tester.view.resetPhysicalSize);
              final store = NodeStore();
              store.apply(
                FrameCodec.decode(
                  File(
                    '${frames.path}/timeline-${width.toInt()}-${large ? '3.2' : '1'}-$highContrast-$dark-$large-$preset.bin',
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
                      textDirection: large
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
                      '$outputDirectory/timeline-$dark-$highContrast-$large-$preset-${fraction.toInt()}.png',
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
