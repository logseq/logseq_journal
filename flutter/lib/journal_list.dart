import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:lui_flutter_backend/lui_flutter_backend.dart';

import 'journal_ext_utils.dart';

/// Port of the grouped native list (`V.Native_list` / `journal-list`).
///
/// Payload (produced by `Journal_view.Native_list.build`):
///   style:    'plain' | 'inset' | 'inset_grouped'
///   sections: [{
///     key, separator: 'automatic'|'hidden'|'visible',
///     header_index: int|null, footer_index: int|null,   // into childIDs
///     rows: [{
///       type: 'row' | 'disclosure',
///       key, content_index: int, separator, test_id?,
///       swipe?:        {actions: [{key, enabled, role, symbol, side, title, background}]},
///       context_menu?: {actions: [{key, enabled, role, symbol, title}]},
///       expanded?: bool,        // disclosure only
///       children?: [row...]     // disclosure only
///     }]
///   }],
///   scroll_request: null | {
///     token: string, target: {section, row_path: [string]},
///     anchor: 'top'|'center'|'bottom'|null, animated: bool|null
///   },
///   track_visible_range: bool,
///   track_scroll_completion: bool
///
/// Emitted events (id 1, payload JSON):
///   {type:'visible_range', first:int, last:int}          — flat row ordinals
///   {type:'scroll_completed', token:string, outcome:string}
///   {type:'expanded', key:string, expanded:bool}
///   {type:'row_event', payload:string}                   — swipe / context-menu
///     presses. Inner payload: {"kind":"swipe"|"context_menu","key":actionKey,
///     "row":rowKey}. NOTE: OCaml-side routing for row_action presses is still
///     being wired (journal_view.ml `on_event` / `on_row_event`); the channel
///     and shape are the proposed contract.
Widget buildJournalList(
  LUIFlutterExtensionContext context,
  Widget Function(int nodeID) renderChild,
) => _JournalListView(context: context, renderChild: renderChild);

class _RowEntry {
  _RowEntry({required this.section, required this.map, required this.depth});

  final Map<String, Object?> section;
  final Map<String, Object?> map;
  final int depth;
}

class _JournalListView extends StatefulWidget {
  const _JournalListView({required this.context, required this.renderChild});

  final LUIFlutterExtensionContext context;
  final Widget Function(int nodeID) renderChild;

  @override
  State<_JournalListView> createState() => _JournalListViewState();
}

class _JournalListViewState extends State<_JournalListView> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  final Map<String, GlobalKey> _rowKeys = {};
  bool _scheduled = false;
  String _range = '';
  String _completedScrollToken = '';

  Map<String, Object?> get _payload => decodeJournalPayload(widget.context);

  List<Object?> get _childIDs => widget.context.childIDs;

  void _emit(String type, Map<String, Object?> fields) {
    emitJournalEvent(widget.context, 1, {'type': type, ...fields});
  }

  void _emitRowEvent(Map<String, Object?> inner) {
    emitJournalEvent(widget.context, 1, {
      'type': 'row_event',
      'payload': jsonEncode(inner),
    });
  }

  Widget _childAt(Object? index) {
    if (index is! int) return const SizedBox.shrink();
    final ids = _childIDs;
    if (index < 0 || index >= ids.length) return const SizedBox.shrink();
    return widget.renderChild(ids[index] as int);
  }

  /// Flattened visible entries: expanded disclosure rows contribute their
  /// children inline, matching the grouped-list layout.
  List<Object?> _entries(Map<String, Object?> payload) {
    final entries = <Object?>[]; // header/footer maps or _RowEntry
    final sections = (payload['sections'] as List?) ?? const [];
    for (final section in sections) {
      if (section is! Map<String, Object?>) continue;
      if (section['header_index'] is int) {
        entries.add({'__kind__': 'header', 'index': section['header_index']});
      }
      void addRows(List rows, int depth, Map<String, Object?> section) {
        for (final row in rows) {
          if (row is! Map<String, Object?>) continue;
          entries.add(_RowEntry(section: section, map: row, depth: depth));
          if (row['type'] == 'disclosure' && row['expanded'] == true) {
            final children = (row['children'] as List?) ?? const [];
            addRows(children, depth + 1, section);
          }
        }
      }

      addRows((section['rows'] as List?) ?? const [], 0, section);
      if (section['footer_index'] is int) {
        entries.add({'__kind__': 'footer', 'index': section['footer_index']});
      }
    }
    return entries;
  }

  String _entryKey(Object? entry) => switch (entry) {
    _RowEntry e => e.map['key'] as String? ?? '',
    Map<String, Object?> m => '${m['__kind__']}:${m['index']}',
    _ => '',
  };

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_schedule);
  }

  @override
  void didUpdateWidget(_JournalListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _handleScrollRequest();
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      _emitVisibleRange();
    });
  }

  void _emitVisibleRange() {
    if (_payload['track_visible_range'] != true || !_scroll.hasClients) {
      return;
    }
    final viewport =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.hasSize) return;
    // Row ordinals only — headers/footers do not count.
    final entries = _entries(_payload);
    var rowOrdinal = -1;
    var first = -1;
    var last = -1;
    for (final entry in entries) {
      if (entry is! _RowEntry) continue;
      rowOrdinal += 1;
      final box =
          _rowKeys[entry.map['key']]?.currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final y = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      if (y + box.size.height > 0 && y < viewport.size.height) {
        if (first < 0) first = rowOrdinal;
        last = rowOrdinal + 1;
      }
    }
    if (first < 0) return;
    final range = '$first:$last';
    if (range != _range) {
      _range = range;
      _emit('visible_range', {'first': first, 'last': last});
    }
  }

  void _handleScrollRequest() {
    final request = _payload['scroll_request'];
    if (request is! Map<String, Object?>) return;
    final token = request['token'];
    if (token == null || '$token' == _completedScrollToken) return;
    _completedScrollToken = '$token';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = request['target'];
      final rowPath = target is Map ? (target['row_path'] as List?) : null;
      String outcome;
      if (rowPath == null || rowPath.isEmpty) {
        outcome = 'missing_target';
      } else {
        final key = rowPath.last;
        final rowContext = _rowKeys['$key']?.currentContext;
        if (rowContext == null) {
          outcome = 'missing_target';
        } else {
          final alignment = switch (request['anchor']) {
            'top' => 0.0,
            'center' => 0.5,
            'bottom' => 1.0,
            _ => 0.7,
          };
          Scrollable.ensureVisible(
            rowContext,
            alignment: alignment,
            duration: request['animated'] == true
                ? const Duration(milliseconds: 250)
                : Duration.zero,
          );
          outcome = 'succeeded';
        }
      }
      if (_payload['track_scroll_completion'] == true) {
        _emit('scroll_completed', {'token': '$token', 'outcome': outcome});
      }
    });
  }

  Widget _buildSectionChrome(Object? entry, Map<String, Object?> section) {
    final separator = section['separator'];
    final child = _buildEntry(entry);
    if (separator == 'hidden') return child;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [child, const Divider(height: 1, indent: 16)],
    );
  }

  Widget _buildEntry(Object? entry) {
    if (entry is Map<String, Object?>) {
      return _childAt(entry['index']);
    }
    if (entry is! _RowEntry) return const SizedBox.shrink();
    final row = entry.map;
    final key = row['key'] as String? ?? '';
    final content = Padding(
      padding: EdgeInsetsDirectional.only(start: 16.0 + entry.depth * 16.0),
      child: _childAt(row['content_index']),
    );
    Widget child = row['type'] == 'disclosure'
        ? Row(
            children: [
              Icon(
                row['expanded'] == true
                    ? Icons.expand_more
                    : Icons.chevron_right,
                size: 18,
              ),
              Expanded(child: content),
            ],
          )
        : content;
    if (row['type'] == 'disclosure') {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _emit('expanded', {
          'key': key,
          'expanded': row['expanded'] != true,
        }),
        child: child,
      );
    }
    final swipe = row['swipe'];
    if (swipe is Map) {
      child = _buildSwipe(key, swipe, child);
    }
    final menu = row['context_menu'];
    if (menu is Map) {
      child = _buildContextMenu(key, menu, child);
    }
    if (row['separator'] == 'visible') {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [child, const Divider(height: 1, indent: 16)],
      );
    }
    child = KeyedSubtree(
      key: _rowKeys.putIfAbsent(key, () => GlobalKey()),
      child: child,
    );
    return journalTestId(row['test_id'] as String?, child);
  }

  Widget _buildSwipe(String rowKey, Map swipe, Widget child) {
    final actions = (swipe['actions'] as List?) ?? const [];
    List<Widget> pane(String side) => [
      for (final action in actions)
        if (action is Map && action['side'] == side)
          SlidableAction(
            onPressed: action['enabled'] == false
                ? null
                : (_) => _emitRowEvent({
                    'kind': 'swipe',
                    'key': action['key'],
                    'row': rowKey,
                  }),
            backgroundColor:
                journalColor(action['background']) ??
                Theme.of(context).colorScheme.surfaceContainerHighest,
            foregroundColor: Colors.white,
            icon: journalSymbolIcon(action['symbol'] as String?),
            label: '${action['title'] ?? ''}',
          ),
    ];
    final start = pane('start');
    final end = pane('end');
    return Slidable(
      groupTag: 'journal-list',
      startActionPane: start.isEmpty
          ? null
          : ActionPane(motion: const ScrollMotion(), children: start),
      endActionPane: end.isEmpty
          ? null
          : ActionPane(motion: const ScrollMotion(), children: end),
      child: child,
    );
  }

  Widget _buildContextMenu(String rowKey, Map menu, Widget child) {
    final actions = (menu['actions'] as List?) ?? const [];
    if (actions.isEmpty) return child;
    return GestureDetector(
      onSecondaryTapUp: (details) => _showMenu(details, actions, rowKey),
      onLongPressStart: (details) => _showMenu(details, actions, rowKey),
      child: child,
    );
  }

  void _showMenu(dynamic details, List<Object?> actions, String rowKey) {
    final position = RelativeRect.fromLTRB(
      details.globalPosition.dx,
      details.globalPosition.dy,
      details.globalPosition.dx,
      details.globalPosition.dy,
    );
    showMenu<String>(
      context: context,
      position: position,
      items: [
        for (final action in actions)
          if (action is Map)
            PopupMenuItem(
              value: '${action['key']}',
              enabled: action['enabled'] != false,
              child: Row(
                children: [
                  if (action['symbol'] is String) ...[
                    Icon(
                      journalSymbolIcon(action['symbol'] as String?),
                      size: 18,
                      color: action['role'] == 'destructive'
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    '${action['title'] ?? ''}',
                    style: TextStyle(
                      color: action['role'] == 'destructive'
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                  ),
                ],
              ),
            ),
      ],
    ).then((selected) {
      if (selected != null) {
        _emitRowEvent({'kind': 'context_menu', 'key': selected, 'row': rowKey});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final payload = _payload;
    final entries = _entries(payload);
    _handleScrollRequest();
    WidgetsBinding.instance.addPostFrameCallback((_) => _emitVisibleRange());
    final grouped = payload['style'] == 'inset_grouped';
    return SlidableAutoCloseBehavior(
      child: ListView.builder(
        key: _viewportKey,
        controller: _scroll,
        itemCount: entries.length,
        findChildIndexCallback: (key) {
          if (key is! ValueKey<String>) return -1;
          return entries.indexWhere((e) => 'k:${_entryKey(e)}' == key.value);
        },
        itemBuilder: (context, index) {
          final entry = entries[index];
          final built = entry is _RowEntry
              ? _buildSectionChrome(entry, entry.section)
              : _buildEntry(entry);
          return KeyedSubtree(
            key: ValueKey('k:${_entryKey(entry)}'),
            child: grouped
                ? Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 1,
                    ),
                    child: built,
                  )
                : built,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}
