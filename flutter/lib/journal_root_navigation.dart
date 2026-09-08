import 'dart:typed_data';

import 'package:bonsai_flutter/bonsai_flutter.dart';
import 'package:material_ui/material_ui.dart';

// Track intent at the position that actually moves. Layout corrections and
// programmatic moves never inherit a previous drag's intent.
class _RootScrollPosition extends ScrollPositionWithSingleContext {
  _RootScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.onSample,
  }) : super(keepScrollOffset: false);
  final void Function(double, double) onSample;
  bool _userMotion = false;
  bool _pointerMotion = false;
  double? _pendingOffset;

  void restoreBeforePaint(double offset) {
    goIdle();
    _pendingOffset = offset;
    // Invalidate the viewport even when the destination has equal dimensions.
    notifyListeners();
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final pending = _pendingOffset;
    if (pending != null) {
      _pendingOffset = null;
      final target = pending.clamp(minScrollExtent, maxScrollExtent);
      if (target != pixels) {
        correctPixels(target);
        return false;
      }
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }

  @override
  void applyUserOffset(double delta) {
    _userMotion = true;
    super.applyUserOffset(delta);
  }

  @override
  void pointerScroll(double delta) {
    _pointerMotion = true;
    try {
      super.pointerScroll(delta);
    } finally {
      _pointerMotion = false;
    }
  }

  @override
  double setPixels(double newPixels) {
    final before = pixels;
    final overscroll = super.setPixels(newPixels);
    if (_userMotion && (pixels != before || pixels <= 0)) {
      onSample(pixels, pixels - before);
    }
    return overscroll;
  }

  @override
  void forcePixels(double value) {
    final before = pixels;
    super.forcePixels(value);
    if (_pointerMotion && pixels != before) onSample(pixels, pixels - before);
  }

  @override
  void goIdle() {
    _userMotion = false;
    super.goIdle();
  }

  @override
  void jumpTo(double value) {
    _userMotion = false;
    super.jumpTo(value);
  }

  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    _userMotion = false;
    return super.animateTo(to, duration: duration, curve: curve);
  }
}

class _RootScrollController extends ScrollController {
  _RootScrollController(this.onSample) : super(keepScrollOffset: false);
  final void Function(double, double) onSample;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _RootScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    onSample: onSample,
  );
}

class _RootNavigationConfiguration extends InheritedWidget {
  const _RootNavigationConfiguration({
    required this.visible,
    required this.duration,
    required super.child,
  });
  final bool visible;
  final Duration duration;
  @override
  bool updateShouldNotify(_RootNavigationConfiguration oldWidget) =>
      visible != oldWidget.visible || duration != oldWidget.duration;
}

/// One graph lifetime owns a retained position and independent saved offsets.
class JournalRootScroll extends StatefulWidget {
  const JournalRootScroll({
    required this.navigationVisible,
    required this.duration,
    required this.active,
    required this.onScroll,
    required this.onNonScrollable,
    required this.destination,
    required this.favoritesRevision,
    required this.favoritesAnchorOffset,
    required this.child,
    super.key,
  });
  final bool navigationVisible, active;
  final Duration duration;
  final void Function(int, double, double) onScroll;
  final ValueChanged<int> onNonScrollable;
  final int destination, favoritesRevision;
  final double favoritesAnchorOffset;
  final Widget child;
  @override
  State<JournalRootScroll> createState() => _JournalRootScrollState();
}

class _JournalRootScrollState extends State<JournalRootScroll> {
  final _offsets = [0.0, 0.0];
  late final _controller = _RootScrollController((pixels, delta) {
    if (mounted && widget.active) {
      widget.onScroll(widget.destination, pixels, delta);
    }
  });

  _RootScrollPosition? get _position => _controller.hasClients
      ? _controller.position as _RootScrollPosition
      : null;

  @override
  void didUpdateWidget(JournalRootScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    final position = _position;
    final changedDestination = oldWidget.destination != widget.destination;
    // Read the outgoing position before assigning any incoming correction.
    if (position != null && position._pendingOffset == null) {
      _offsets[oldWidget.destination] = position.pixels;
    }
    if (oldWidget.active != widget.active || changedDestination) {
      position?.goIdle();
    }
    final changedFavorites =
        oldWidget.favoritesRevision != widget.favoritesRevision;
    if (changedFavorites) {
      _offsets[1] =
          (_offsets[1] +
                  widget.favoritesAnchorOffset -
                  oldWidget.favoritesAnchorOffset)
              .clamp(0.0, double.infinity);
    }
    if (changedDestination || (changedFavorites && widget.destination == 1)) {
      position?.restoreBeforePaint(_offsets[widget.destination]);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _RootNavigationConfiguration(
    visible: widget.navigationVisible,
    duration: widget.duration,
    child: NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (widget.active &&
            notification.depth == 0 &&
            notification.metrics.axis == Axis.vertical &&
            notification.metrics.maxScrollExtent <=
                notification.metrics.minScrollExtent) {
          widget.onNonScrollable(widget.destination);
        }
        return false;
      },
      child: PrimaryScrollController(
        controller: _controller,
        child: widget.child,
      ),
    ),
  );
}

class JournalNavigationBar extends StatelessWidget {
  const JournalNavigationBar({
    required this.selectedIndex,
    required this.destinations,
    required this.onDestinationSelected,
    super.key,
  });
  final int selectedIndex;
  final List<Widget> destinations;
  final ValueChanged<int>? onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final configuration = context
        .dependOnInheritedWidgetOfExactType<_RootNavigationConfiguration>()!;
    final media = MediaQuery.of(context);
    final view = View.of(context);
    final bottomInset = view.viewPadding.bottom / view.devicePixelRatio;
    final visible = configuration.visible;
    final backgroundColor =
        NavigationBarTheme.of(context).backgroundColor ??
        Theme.of(context).colorScheme.surfaceContainer;
    final bar = MediaQuery(
      data: media.copyWith(padding: media.padding.copyWith(bottom: 0)),
      child: NavigationBar(
        backgroundColor: backgroundColor,
        height: 44,
        selectedIndex: selectedIndex,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
        destinations: destinations,
        onDestinationSelected: onDestinationSelected,
      ),
    );
    final control = ExcludeSemantics(
      excluding: !visible,
      child: ExcludeFocus(
        excluding: !visible,
        child: IgnorePointer(ignoring: !visible, child: bar),
      ),
    );
    Widget size(double value, Widget child) => ColoredBox(
      color: value > 0 ? backgroundColor : Colors.transparent,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SizeTransition(
          sizeFactor: AlwaysStoppedAnimation(value),
          alignment: Alignment.bottomCenter,
          child: child,
        ),
      ),
    );
    return media.disableAnimations || configuration.duration == Duration.zero
        ? size(visible ? 1 : 0, control)
        : TweenAnimationBuilder<double>(
            tween: Tween(begin: visible ? 1 : 0, end: visible ? 1 : 0),
            duration: configuration.duration,
            curve: Curves.easeInOut,
            builder: (context, value, child) => size(value, child!),
            child: control,
          );
  }
}

// The renderer supplies font glyphs as Text. Give them native icon color and
// fixed geometry independently of destination-label and tooltip text scaling.
class _NavigationGlyph extends StatelessWidget {
  const _NavigationGlyph(this.child);
  final Widget child;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: MediaQuery.withNoTextScaling(
      child: DefaultTextStyle.merge(
        style: TextStyle(
          color: IconTheme.of(context).color,
          height: 1,
          letterSpacing: 0,
        ),
        child: SizedBox.square(dimension: 24, child: Center(child: child)),
      ),
    ),
  );
}

// Keep native destination semantics and tooltips while hiding persistent labels.
Widget buildJournalNavigationBar(
  BuildContext context,
  UiNode node,
  List<Widget> children,
  RendererEventCallback? onEvent,
) {
  final props = node.props as MaterialNavigationBarProps;
  final binding = node.eventBindings
      .where(
        (value) => value.eventTag == EventTagId.navigationDestinationSelected,
      )
      .firstOrNull;
  var childIndex = 0;
  final destinations = props.destinations.map((destination) {
    final icon = _NavigationGlyph(children[childIndex++]);
    final selectedIcon = destination.hasSelectedIcon
        ? _NavigationGlyph(children[childIndex++])
        : null;
    return NavigationDestination(
      icon: icon,
      selectedIcon: selectedIcon,
      label: destination.label,
    );
  }).toList();
  return JournalNavigationBar(
    selectedIndex: props.selectedIndex,
    destinations: destinations,
    onDestinationSelected: binding == null || onEvent == null
        ? null
        : (index) => onEvent(
            RendererEvent(
              nodeId: node.id,
              eventTag: binding.eventTag,
              handlerId: binding.handlerId,
              payload: Int64EventPayload(index),
            ),
          ),
  );
}

void registerJournalRootNavigation(NativeWidgetRegistry registry) {
  registry.register<(int, int, double, bool, int, bool)>(
    NativeWidgetRegistration(
      kindId: 1003,
      minVersion: 1,
      maxVersion: 1,
      capabilityBits: 0,
      decodeProps: (payload) {
        if (payload.length != 32) {
          throw const FormatException('Invalid root scroll props');
        }
        final data = ByteData.sublistView(payload);
        return (
          data.getUint32(0, Endian.little),
          data.getInt64(8, Endian.little),
          data.getFloat64(16, Endian.little),
          data.getUint32(4, Endian.little) != 0,
          data.getUint32(24, Endian.little),
          data.getUint32(28, Endian.little) != 0,
        );
      },
      factory: (context) {
        final (destination, revision, offset, visible, milliseconds, active) =
            context.props;
        void emit(int event, int destination, double pixels, double delta) {
          final data = ByteData(24)
            ..setUint32(0, destination, Endian.little)
            ..setFloat64(8, pixels, Endian.little)
            ..setFloat64(16, delta, Endian.little);
          context.emit?.call(event, data.buffer.asUint8List());
        }

        return JournalRootScroll(
          navigationVisible: visible,
          duration: Duration(milliseconds: milliseconds),
          active: active,
          onScroll: (destination, pixels, delta) =>
              emit(1, destination, pixels, delta),
          onNonScrollable: (destination) => emit(2, destination, 0, 0),
          destination: destination,
          favoritesRevision: revision,
          favoritesAnchorOffset: offset,
          child: context.children.single,
        );
      },
    ),
  );
}
