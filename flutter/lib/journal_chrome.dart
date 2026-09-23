import 'package:flutter/material.dart';
import 'package:lui_flutter_backend/lui_flutter_backend.dart';

import 'journal_ext_utils.dart';

/// Width of the header controls cluster, shared between the `journal` chrome
/// (which draws the controls) and `header` chromes (which pad their text so
/// controls don't overlap). Mirrors the SwiftUI `journalControlsSize`
/// environment key from `JournalChrome.swift`.
final ValueNotifier<double> journalChromeControlsWidth = ValueNotifier(0);

/// Port of `JournalChrome.swift` (`journal-chrome`).
///
/// Payload contract (matches `~encode_props` output):
///   mode:    'journal' | 'header' | 'feedback'
///   title?:  string        (header)
///   visible?: bool         (header, default true)
///   top?:    'leading' | 'trailing'  (header alignment, default trailing)
///   connecting?: bool      (journal mode spinner)
///   account?:  string      (journal mode, button -> event {account:'press'})
///   error?:    string      (journal mode, red dot, tap -> {account:'error'})
///
/// Children (by position, standard nodes):
///   feedback: 0 body, 1 compact footer, 2 expanded footer
///   journal:  0 content, 1 account, 2 error, 3 progress
///   header:   none
///
/// [renderChild] renders a child node id (LUIFlutterExtensionContext exposes
/// no per-child widget accessor — see `content(for:)` on the Apple backend).
Widget buildJournalChrome(
  LUIFlutterExtensionContext context,
  Widget Function(int nodeID) renderChild,
) {
  final payload = decodeJournalPayload(context);
  switch (payload['mode']) {
    case 'header':
      return JournalHeaderChrome(payload: payload);
    case 'feedback':
      return JournalFeedbackChrome(context: context, renderChild: renderChild);
    case 'journal':
      return JournalJournalChrome(
        context: context,
        payload: payload,
        renderChild: renderChild,
      );
    default:
      throw FormatException('journal-chrome unknown mode: ${payload['mode']}');
  }
}

class JournalHeaderChrome extends StatelessWidget {
  const JournalHeaderChrome({super.key, required this.payload});

  final Map<String, Object?> payload;

  @override
  Widget build(BuildContext context) {
    if (payload['visible'] == false) {
      return const SizedBox.shrink();
    }
    final title = payload['title'];
    final topLeading = payload['top'] == 'leading';
    return ValueListenableBuilder<double>(
      valueListenable: journalChromeControlsWidth,
      builder: (context, controlsWidth, child) => Padding(
        padding: EdgeInsetsDirectional.only(
          start: topLeading ? 0 : controlsWidth,
          end: topLeading ? controlsWidth : 0,
        ),
        child: child,
      ),
      child: Container(
        color: const Color(0xff111827),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        alignment: topLeading ? Alignment.centerLeft : Alignment.centerRight,
        child: title is String && title.isNotEmpty
            ? Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: topLeading ? TextAlign.left : TextAlign.right,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              )
            : null,
      ),
    );
  }
}

class JournalJournalChrome extends StatefulWidget {
  const JournalJournalChrome({
    super.key,
    required this.context,
    required this.payload,
    required this.renderChild,
  });

  final LUIFlutterExtensionContext context;
  final Map<String, Object?> payload;
  final Widget Function(int nodeID) renderChild;

  @override
  State<JournalJournalChrome> createState() => _JournalJournalChromeState();
}

class _JournalJournalChromeState extends State<JournalJournalChrome> {
  final GlobalKey _controlsKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureControls());
  }

  void _measureControls() {
    final box = _controlsKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      journalChromeControlsWidth.value = box.size.width + 8;
    }
  }

  @override
  Widget build(BuildContext context) {
    final childIDs = widget.context.childIDs;
    final content = childIDs.isEmpty
        ? const SizedBox.shrink()
        : widget.renderChild(childIDs.first);
    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        Positioned(
          top: 4,
          right: 8,
          child: SafeArea(
            child: _ChromeControls(
              key: _controlsKey,
              context: widget.context,
              payload: widget.payload,
              renderChild: widget.renderChild,
              onMeasured: _measureControls,
            ),
          ),
        ),
      ],
    );
  }
}

class _ChromeControls extends StatelessWidget {
  const _ChromeControls({
    super.key,
    required this.context,
    required this.payload,
    required this.renderChild,
    required this.onMeasured,
  });

  final LUIFlutterExtensionContext context;
  final Map<String, Object?> payload;
  final Widget Function(int nodeID) renderChild;
  final VoidCallback onMeasured;

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => onMeasured());
    final childIDs = this.context.childIDs;
    final connecting = payload['connecting'] == true;
    final account = payload['account'];
    final error = payload['error'];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (childIDs.length > 3) renderChild(childIDs[3]),
        if (connecting)
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else ...[
          if (error is String && error.isNotEmpty)
            _ControlSlot(
              onTap: () =>
                  emitJournalEvent(this.context, 0, const {'account': 'error'}),
              child: childIDs.length > 2
                  ? renderChild(childIDs[2])
                  : const _ErrorDot(),
            ),
          if (account is String && account.isNotEmpty)
            _ControlSlot(
              onTap: () =>
                  emitJournalEvent(this.context, 0, const {'account': 'press'}),
              child: childIDs.length > 1
                  ? renderChild(childIDs[1])
                  : const Icon(Icons.account_circle),
            ),
        ],
      ],
    );
  }
}

class _ErrorDot extends StatelessWidget {
  const _ErrorDot();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(color: Colors.red, shape: BoxShape.circle),
    child: SizedBox(width: 8, height: 8),
  );
}

class _ControlSlot extends StatelessWidget {
  const _ControlSlot({required this.child, required this.onTap});

  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(start: 8),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(padding: const EdgeInsets.all(4), child: child),
    ),
  );
}

class JournalFeedbackChrome extends StatelessWidget {
  const JournalFeedbackChrome({
    super.key,
    required this.context,
    required this.renderChild,
  });

  final LUIFlutterExtensionContext context;
  final Widget Function(int nodeID) renderChild;

  @override
  Widget build(BuildContext context) {
    final childIDs = this.context.childIDs;
    final body = childIDs.isEmpty
        ? const SizedBox.shrink()
        : renderChild(childIDs.first);
    return LayoutBuilder(
      builder: (context, constraints) {
        // ViewThatFits equivalent: prefer the expanded footer when the
        // available width is comfortable, else the compact one.
        final useExpanded = constraints.maxWidth >= 560;
        Widget? footer;
        if (useExpanded && childIDs.length > 2) {
          footer = renderChild(childIDs[2]);
        }
        footer ??= childIDs.length > 1 ? renderChild(childIDs[1]) : null;
        return Stack(
          fit: StackFit.expand,
          children: [
            body,
            if (footer != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Material(
                    color: const Color(0xcc111827),
                    child: footer,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
