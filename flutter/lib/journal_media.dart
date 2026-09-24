import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lui_flutter_backend/lui_flutter_backend.dart';
import 'package:url_launcher/url_launcher.dart';

import 'journal_ext_utils.dart';

/// Port of `JournalMedia.swift` (`journal-media`).
///
/// Payload:
///   root:     string — graph root, echoed on every event
///   items:    [{id, kind, value, type, width, height}] (<= 32)
///   more:     bool — show "Next attachments"
///   editable: bool — show the actions menu
///   picker?:  {items, more, busy}
///   error?:   string
/// Children: exactly one (the row content the attachment UI anchors to).
/// Events: id 1, payload `{action, root, asset, visible}` with actions
/// retry/replace/reuse/reuse-select/reuse-next/reuse-cancel/next.
Widget buildJournalMedia(
  LUIFlutterExtensionContext context,
  Widget Function(int nodeID) renderChild,
) => _JournalMediaGroup(context: context, renderChild: renderChild);

const _imageTypes = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'heic',
  'heif',
  'tif',
  'tiff',
  'bmp',
  'avif',
};

class _JournalMediaGroup extends StatelessWidget {
  const _JournalMediaGroup({required this.context, required this.renderChild});

  final LUIFlutterExtensionContext context;
  final Widget Function(int nodeID) renderChild;

  void _emit(String action, {String asset = '', bool visible = true}) {
    emitJournalEvent(context, 1, <String, Object?>{
      'action': action,
      'root': _payload['root'],
      'asset': asset,
      'visible': visible,
    });
  }

  Map<String, Object?> get _payload => decodeJournalPayload(context);

  @override
  Widget build(BuildContext context) {
    final payload = _payload;
    final childIDs = this.context.childIDs;
    final items = (payload['items'] as List?) ?? const [];
    final picker = payload['picker'];
    final pickerMap = picker is Map ? picker : const <String, Object?>{};
    final pickerItems = (pickerMap['items'] as List?) ?? const [];
    final pickerBusy = pickerMap['busy'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: childIDs.isEmpty
                  ? const SizedBox.shrink()
                  : renderChild(childIDs.first),
            ),
            const SizedBox(width: 8),
            if (payload['editable'] == true)
              journalTestId(
                'journal-media-actions',
                PopupMenuButton<String>(
                  tooltip: 'Attachment actions',
                  icon: const Icon(Icons.more_horiz, size: 20),
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'replace',
                      child: Text('Replace file…'),
                    ),
                    PopupMenuItem(
                      value: 'reuse',
                      child: Text('Reuse existing…'),
                    ),
                  ],
                  onSelected: (action) => _emit(action),
                ),
              ),
          ],
        ),
        for (final item in items)
          if (item is Map) _MediaItem(item: item, emit: _emit),
        if (picker != null) ...[
          if (pickerBusy && pickerItems.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('Loading attachments', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          for (final item in pickerItems)
            if (item is Map)
              journalTestId(
                'journal-media-candidate:${item['id']}',
                TextButton.icon(
                  onPressed: pickerBusy
                      ? null
                      : () => _emit('reuse-select', asset: '${item['id']}'),
                  icon: const Icon(Icons.insert_drive_file_outlined, size: 16),
                  label: Text(
                    (item['type'] as String?)?.isEmpty ?? true
                        ? 'file'
                        : item['type'] as String,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
          if (pickerMap['more'] == true)
            TextButton(
              onPressed: pickerBusy ? null : () => _emit('reuse-next'),
              child: const Text('More attachments'),
            ),
          TextButton(
            onPressed: () => _emit('reuse-cancel'),
            child: const Text('Cancel', style: TextStyle(fontSize: 12)),
          ),
        ],
        if (payload['error'] is String) ...[
          Text(
            payload['error'] as String,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
          TextButton(
            onPressed: () => _emit('retry'),
            child: const Text('Retry attachments'),
          ),
        ],
        if (payload['more'] == true)
          TextButton(
            onPressed: () => _emit('next'),
            child: const Text('Next attachments'),
          ),
      ],
    );
  }
}

class _MediaItem extends StatefulWidget {
  const _MediaItem({required this.item, required this.emit});

  final Map<Object?, Object?> item;
  final void Function(String action, {String asset, bool visible}) emit;

  @override
  State<_MediaItem> createState() => _MediaItemState();
}

class _MediaItemState extends State<_MediaItem> {
  bool _decodeFailed = false;

  String get _id => '${widget.item['id']}';
  String get _kind => '${widget.item['kind']}';
  String get _value => '${widget.item['value']}';
  String get _type => ('${widget.item['type']}').toLowerCase();
  bool get _isImage => _imageTypes.contains(_type);

  Future<void> _openFile() async {
    final uri = Uri.file(_value);
    await launchUrl(uri);
  }

  Future<void> _openExternal() async {
    final uri = Uri.tryParse(_value);
    if (uri != null) await launchUrl(uri);
  }

  void _previewImage() {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: InteractiveViewer(
          child: Image.file(
            File(_value),
            errorBuilder: (context, error, stack) => const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Unable to preview image'),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = (widget.item['width'] as num?)?.toInt() ?? 1;
    final height = (widget.item['height'] as num?)?.toInt() ?? 1;
    final body = _buildContent();
    return journalTestId(
      'journal-media:$_id',
      _isImage
          ? ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: AspectRatio(
                aspectRatio: width <= 0 || height <= 0 ? 1 : width / height,
                child: body,
              ),
            )
          : ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: body,
            ),
    );
  }

  Widget _buildContent() {
    if (_kind == 'file' && _isImage) {
      if (_decodeFailed) {
        return TextButton(
          onPressed: _previewImage,
          child: const Text('Open image'),
        );
      }
      return GestureDetector(
        onTap: _previewImage,
        child: Image.file(
          File(_value),
          fit: BoxFit.contain,
          cacheWidth: 1024,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
              frame == null
              ? const Center(child: Text('Opening image'))
              : child,
          errorBuilder: (context, error, stack) {
            _decodeFailed = true;
            return const Center(child: Text('Open image'));
          },
        ),
      );
    }
    if (_kind == 'file') {
      return TextButton.icon(
        onPressed: _openFile,
        icon: const Icon(Icons.insert_drive_file_outlined, size: 18),
        label: const Text('Open attachment'),
      );
    }
    if (_kind == 'external') {
      final uri = Uri.tryParse(_value);
      if (uri != null && ['https', 'http'].contains(uri.scheme.toLowerCase())) {
        return TextButton.icon(
          onPressed: _openExternal,
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Open external attachment'),
        );
      }
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.image_outlined, size: 16),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  _value,
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          TextButton(
            onPressed: () => widget.emit('retry', asset: _id),
            child: const Text('Retry', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
