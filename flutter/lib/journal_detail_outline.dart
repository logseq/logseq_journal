import 'dart:convert';
import 'dart:typed_data';

import 'package:bonsai_flutter/bonsai_flutter.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:material_ui/material_ui.dart';

// A mechanical viewport adapter. OCaml supplies every product widget, action,
// logical identity and materialized window; native state owns only geometry.
class JournalDetailProps {
  const JournalDetailProps({
    required this.keys,
    required this.actions,
    required this.firstIndex,
    required this.revealId,
  });
  final List<String> keys;
  final Map<String, (String, String)> actions;
  final int firstIndex;
  final String revealId;
  static JournalDetailProps decode(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    var offset = 0;
    int integer() {
      final n = data.getUint32(offset, Endian.little);
      offset += 4;
      return n;
    }

    String string() {
      final n = integer();
      final s = utf8.decode(bytes.sublist(offset, offset + n));
      offset += n;
      return s;
    }

    final first = integer(), reveal = string(), count = integer();
    final keys = <String>[], actions = <String, (String, String)>{};
    for (var i = 0; i < count; i++) {
      final key = string(), label = string(), action = string();
      keys.add(key);
      if (label.isNotEmpty) actions[key] = (label, action);
    }
    if (offset != bytes.length)
      throw const FormatException('Invalid outline viewport payload');
    return JournalDetailProps(
      keys: keys,
      actions: actions,
      firstIndex: first,
      revealId: reveal,
    );
  }
}

void registerJournalDetailOutline(NativeWidgetRegistry registry) {
  registry.register<JournalDetailProps>(
    NativeWidgetRegistration(
      kindId: 1005,
      minVersion: 1,
      maxVersion: 1,
      capabilityBits: 0,
      decodeProps: JournalDetailProps.decode,
      factory: (context) => JournalDetailOutline(
        props: context.props,
        header: context.children[0],
        composer: context.children[1],
        notice: context.children[2],
        items: context.children.sublist(3),
        onAction: (action) =>
            context.emit?.call(1, Uint8List.fromList(utf8.encode(action))),
      ),
    ),
  );
}

class JournalDetailOutline extends StatefulWidget {
  const JournalDetailOutline({
    required this.props,
    required this.header,
    required this.composer,
    required this.notice,
    required this.items,
    required this.onAction,
    super.key,
  });
  final JournalDetailProps props;
  final Widget header, composer, notice;
  final List<Widget> items;
  final ValueChanged<String> onAction;
  @override
  State<JournalDetailOutline> createState() => _JournalDetailOutlineState();
}

class _JournalDetailOutlineState extends State<JournalDetailOutline> {
  final _scroll = ScrollController();
  final _viewport = GlobalKey();
  final _rendered = <String, GlobalKey>{};
  final _heights = <String, double>{};
  bool _scheduled = false;
  String? _anchor;
  double _anchorY = 0;
  String _revealed = '';
  String _range = '';
  bool _restoreAnchor = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_schedule);
  }

  @override
  void didUpdateWidget(JournalDetailOutline oldWidget) {
    super.didUpdateWidget(oldWidget);
    _restoreAnchor = true;
    _rendered.removeWhere((key, _) => !widget.props.keys.contains(key));
    _heights.removeWhere((key, _) => !widget.props.keys.contains(key));
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      final viewport =
          _viewport.currentContext?.findRenderObject() as RenderBox?;
      if (viewport == null || !viewport.hasSize) return;
      final reveal = widget.props.revealId;
      if (reveal.isNotEmpty && reveal != _revealed) {
        final target = _rendered[reveal]?.currentContext;
        if (target != null) {
          _revealed = reveal;
          Scrollable.ensureVisible(target, alignment: 0.7);
        } else {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      } else if (_restoreAnchor && _anchor != null) {
        final box =
            _rendered[_anchor]?.currentContext?.findRenderObject()
                as RenderBox?;
        if (box != null && box.hasSize) {
          final delta =
              box.localToGlobal(Offset.zero, ancestor: viewport).dy - _anchorY;
          if (delta.abs() > 0.5)
            _scroll.jumpTo(
              (_scroll.offset + delta).clamp(
                0,
                _scroll.position.maxScrollExtent,
              ),
            );
        }
      }
      _restoreAnchor = false;
      var first = widget.props.keys.length, last = 0;
      String? anchor;
      var anchorY = 0.0;
      for (final entry in _rendered.entries) {
        final box =
            entry.value.currentContext?.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) continue;
        final y = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
        if (y + box.size.height > 0 && y < viewport.size.height) {
          final index = widget.props.keys.indexOf(entry.key);
          if (index < 0) continue;
          if (index < first) {
            first = index;
            anchor = entry.key;
            anchorY = y;
          }
          if (index + 1 > last) last = index + 1;
        }
      }
      _anchor = anchor;
      _anchorY = anchorY;
      final range = '$first:$last';
      if (first < last && range != _range) {
        _range = range;
        widget.onAction('detail-visible:$range');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _schedule();
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        title: Directionality(
          textDirection: TextDirection.ltr,
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            child: widget.header,
          ),
        ),
      ),
      floatingActionButton: widget.composer,
      body: Column(
        children: [
          widget.notice,
          Expanded(
            child: SlidableAutoCloseBehavior(
              child: ListView.builder(
                key: _viewport,
                controller: _scroll,
                padding: EdgeInsets.only(
                  bottom: 96 + MediaQuery.paddingOf(context).bottom,
                ),
                itemCount: widget.props.keys.length,
                findChildIndexCallback: (key) {
                  final index = key is ValueKey<String>
                      ? widget.props.keys.indexOf(key.value)
                      : -1;
                  return index < 0 ? null : index;
                },
                itemBuilder: (context, index) {
                  final key = widget.props.keys[index];
                  final local = index - widget.props.firstIndex;
                  final supplied = local >= 0 && local < widget.items.length;
                  Widget child = supplied
                      ? widget.items[local]
                      : SizedBox(height: _heights[key] ?? 72);
                  final action = widget.props.actions[key];
                  if (action != null)
                    child = Semantics(
                      customSemanticsActions: {
                        CustomSemanticsAction(label: action.$1): () =>
                            widget.onAction(action.$2),
                      },
                      child: child,
                    );
                  return KeyedSubtree(
                    key: ValueKey(key),
                    child: _Measure(
                      key: _rendered.putIfAbsent(key, GlobalKey.new),
                      onSize: (height) {
                        if (supplied) _heights[key] = height;
                        _schedule();
                      },
                      child: child,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}

class _Measure extends SingleChildRenderObjectWidget {
  const _Measure({required this.onSize, required super.child, super.key});
  final ValueChanged<double> onSize;
  @override
  RenderObject createRenderObject(BuildContext context) => _MeasuredBox(onSize);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _MeasuredBox renderObject,
  ) {
    renderObject.onSize = onSize;
  }
}

class _MeasuredBox extends RenderProxyBox {
  _MeasuredBox(this.onSize);
  ValueChanged<double> onSize;
  @override
  void performLayout() {
    super.performLayout();
    onSize(size.height);
  }
}
