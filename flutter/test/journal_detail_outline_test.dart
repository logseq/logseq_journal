import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import '../lib/journal_detail_outline.dart';
import '../lib/journal_widget_registry.dart';

void main() {
  test('all application native widgets register without a kind collision', () {
    expect(createJournalWidgetRegistry, returnsNormally);
  });
  Widget page(List<String> keys, List<String> actions, {bool rtl = false}) =>
      MaterialApp(
        home: Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: JournalDetailOutline(
            props: JournalDetailProps(
              keys: keys,
              actions: const {},
              firstIndex: 0,
              revealId: '',
            ),
            header: Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  onPressed: () => actions.add('back'),
                  icon: const Icon(Icons.chevron_left),
                ),
                const Text('Block'),
              ],
            ),
            composer: const SizedBox(key: ValueKey('append-slot')),
            notice: const SizedBox.shrink(),
            items: keys
                .take(40)
                .map(
                  (id) => Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('$id\nSecond line'),
                  ),
                )
                .toList(),
            onAction: actions.add,
          ),
        ),
      );

  testWidgets('bounded supplied rows and physical left header under RTL', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(
      page(List.generate(1000, (i) => 'block-$i'), actions, rtl: true),
    );
    await tester.pumpAndSettle();
    expect(find.text('block-1\nSecond line'), findsOneWidget);
    expect(tester.getCenter(find.byTooltip('Back')).dx, lessThan(70));
    expect(find.byKey(const ValueKey('append-slot')), findsOneWidget);
    expect(find.textContaining('Second line').evaluate().length, lessThan(40));
    expect(
      actions.any((action) => action.startsWith('detail-visible:')),
      isTrue,
    );
  });

  testWidgets('content taps emit no navigation and Back remains operable', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(
      page(List.generate(10, (i) => 'block-$i'), actions),
    );
    await tester.pumpAndSettle();
    actions.clear();
    await tester.tap(find.text('block-1\nSecond line'));
    expect(actions, isEmpty);
    await tester.tap(find.byTooltip('Back'));
    expect(actions, ['back']);
  });

  testWidgets('insertion above the viewport preserves a stable row anchor', (
    tester,
  ) async {
    final actions = <String>[];
    final keys = List.generate(40, (i) => 'block-$i');
    await tester.pumpWidget(page(keys, actions));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.text('block-10\nSecond line')).dy;
    await tester.pumpWidget(page(['inserted', ...keys], actions));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('block-10\nSecond line')).dy,
      closeTo(before, 1),
    );
  });
}
