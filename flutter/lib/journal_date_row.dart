import 'package:bonsai_flutter/bonsai_flutter.dart';
import 'package:material_ui/material_ui.dart';

// Use the native shrinking Row for both centered and content-leading dates.
void registerJournalDateRow(NativeWidgetRegistry registry) {
  registry.register<Object>(
    NativeWidgetRegistration(
      kindId: 1004,
      minVersion: 1,
      maxVersion: 1,
      capabilityBits: 0,
      decodeProps: (payload) {
        if (payload.isNotEmpty) {
          throw const FormatException('Date rows have no properties');
        }
        return const Object();
      },
      factory: (context) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: context.children,
      ),
    ),
  );
}
