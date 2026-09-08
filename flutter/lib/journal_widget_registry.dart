import 'package:bonsai_flutter/bonsai_flutter.dart';

import 'journal_tail_fade.dart';
import 'journal_date_row.dart';
import 'journal_root_navigation.dart';

WidgetRegistry createJournalWidgetRegistry() {
  final nativeWidgets = NativeWidgetRegistry(
    capabilityBits: NativeCapability.core,
  );
  registerMorphingSurface(nativeWidgets);
  registerSlidable(nativeWidgets);
  registerSlidableAutoCloseBehavior(nativeWidgets);
  registerNavigationShell(nativeWidgets);
  registerMessageComposer(nativeWidgets);
  registerExpandableMessageComposer(nativeWidgets);
  registerJournalRootNavigation(nativeWidgets);
  registerJournalTailFade(nativeWidgets);
  registerJournalDateRow(nativeWidgets);
  final standard = WidgetRegistry.standard(nativeWidgets: nativeWidgets);
  return WidgetRegistry({
    for (final kind in NodeKind.values)
      kind: kind == NodeKind.materialNavigationBar
          ? buildJournalNavigationBar
          : standard.build,
  }, nativeWidgets);
}
