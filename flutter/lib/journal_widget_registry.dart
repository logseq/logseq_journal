import 'package:bonsai_flutter/bonsai_flutter.dart';

import 'journal_tail_fade.dart';

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
  registerJournalTailFade(nativeWidgets);
  return WidgetRegistry.standard(nativeWidgets: nativeWidgets);
}
