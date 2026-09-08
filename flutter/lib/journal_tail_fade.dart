import 'dart:typed_data';

import 'package:bonsai_flutter/bonsai_flutter.dart';
import 'package:material_ui/material_ui.dart';

const int journalTailFadeKindId = 1001;

@immutable
final class JournalTailFadeProps {
  const JournalTailFadeProps({
    required this.lineHeight,
    required this.fadeWidth,
  });

  final double lineHeight;
  final double fadeWidth;

  static JournalTailFadeProps decode(Uint8List payload) {
    if (payload.length != 16) {
      throw const FormatException(
        'Journal tail fade props must contain exactly 16 bytes',
      );
    }
    final data = ByteData.sublistView(payload);
    final lineHeight = data.getFloat64(0, Endian.little);
    final fadeWidth = data.getFloat64(8, Endian.little);
    if (!lineHeight.isFinite ||
        lineHeight <= 0 ||
        !fadeWidth.isFinite ||
        fadeWidth <= 0) {
      throw const FormatException(
        'Journal tail fade geometry must be finite and positive',
      );
    }
    return JournalTailFadeProps(lineHeight: lineHeight, fadeWidth: fadeWidth);
  }
}

void registerJournalTailFade(NativeWidgetRegistry registry) {
  registry.register<JournalTailFadeProps>(
    NativeWidgetRegistration(
      kindId: journalTailFadeKindId,
      minVersion: 1,
      maxVersion: 1,
      capabilityBits: 0,
      decodeProps: JournalTailFadeProps.decode,
      factory: (context) {
        if (context.children.length != 1) {
          throw ArgumentError('Journal tail fade requires exactly one child');
        }
        return JournalTailFade(
          props: context.props,
          child: context.children.single,
        );
      },
    ),
  );
}

final class JournalTailFade extends StatelessWidget {
  const JournalTailFade({required this.props, required this.child, super.key});

  final JournalTailFadeProps props;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).scaffoldBackgroundColor;
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        child,
        PositionedDirectional(
          end: 0,
          bottom: 0,
          width: props.fadeWidth,
          height: props.lineHeight,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: AlignmentDirectional.centerStart,
                  end: AlignmentDirectional.centerEnd,
                  colors: [surface.withAlpha(0), surface],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
