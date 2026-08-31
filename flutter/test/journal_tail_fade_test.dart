import 'dart:typed_data';

import 'package:bonsai_flutter_logseq_journal_host/journal_tail_fade.dart';
import 'package:bonsai_flutter_logseq_journal_host/journal_widget_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tail fade props decode finite little-endian geometry', () {
    final payload = Uint8List(16);
    final data = ByteData.sublistView(payload)
      ..setFloat64(0, 22, Endian.little)
      ..setFloat64(8, 24, Endian.little);

    final props = JournalTailFadeProps.decode(payload);
    expect(props.lineHeight, 22);
    expect(props.fadeWidth, 24);
    expect(createJournalWidgetRegistry(), isNotNull);

    expect(
      () => JournalTailFadeProps.decode(Uint8List(15)),
      throwsFormatException,
    );
    data.setFloat64(0, double.nan, Endian.little);
    expect(() => JournalTailFadeProps.decode(payload), throwsFormatException);
  });

  for (final direction in TextDirection.values) {
    testWidgets('tail fade covers only the final $direction line end', (
      tester,
    ) async {
      const surface = Color(0xff112233);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(scaffoldBackgroundColor: surface),
          home: Scaffold(
            body: Center(
              child: Directionality(
                textDirection: direction,
                child: const SizedBox(
                  width: 120,
                  child: JournalTailFade(
                    props: JournalTailFadeProps(lineHeight: 22, fadeWidth: 24),
                    child: SizedBox(
                      width: 120,
                      height: 66,
                      child: Text(
                        'A long title that occupies more than three lines',
                        maxLines: 3,
                        overflow: TextOverflow.clip,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final host = find.byType(JournalTailFade);
      final gradient = find.descendant(
        of: host,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).gradient != null,
        ),
      );
      expect(gradient, findsOneWidget);
      final hostRect = tester.getRect(host);
      final fadeRect = tester.getRect(gradient);
      expect(fadeRect.width, 24);
      expect(fadeRect.height, 22);
      expect(fadeRect.bottom, hostRect.bottom);
      if (direction == TextDirection.ltr) {
        expect(fadeRect.right, hostRect.right);
      } else {
        expect(fadeRect.left, hostRect.left);
      }

      final decoration =
          tester.widget<DecoratedBox>(gradient).decoration as BoxDecoration;
      final colors = (decoration.gradient! as LinearGradient).colors;
      expect(colors.first.a, 0);
      expect(colors.last, surface);
    });
  }
}
