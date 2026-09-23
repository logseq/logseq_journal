import 'package:flutter/material.dart';
import 'package:lui_flutter_backend/lui_flutter_backend.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'journal_ext_utils.dart';

/// Port of `JournalAssetSettings.swift` (`journal-asset-settings`) plus the
/// `JournalAssetPreferences` UserDefaults shim (shared_preferences).
///
/// Payload: `{presented, recent, favorites, uploads:[{id,title,message,busy,
/// retry}]}`. Children: exactly one (the button/row that presents the sheet).
/// Events are emitted with `id: 1` and a plain string payload:
/// `days:N` (recent-day setting), `dismissed`, `retry:<uploadId>`.
Widget buildJournalAssetSettings(
  LUIFlutterExtensionContext context,
  Widget Function(int nodeID) renderChild,
) => _JournalAssetSettingsHost(context: context, renderChild: renderChild);

const _recentDaysKey = 'assetRecentDays';
const _defaultRecentDays = 7;
const _maxRecentDays = 3660;

class _JournalAssetSettingsHost extends StatefulWidget {
  const _JournalAssetSettingsHost({
    required this.context,
    required this.renderChild,
  });

  final LUIFlutterExtensionContext context;
  final Widget Function(int nodeID) renderChild;

  @override
  State<_JournalAssetSettingsHost> createState() =>
      _JournalAssetSettingsHostState();
}

class _JournalAssetSettingsHostState extends State<_JournalAssetSettingsHost> {
  int _days = _defaultRecentDays;
  int? _deliveredDays;
  bool _sheetOpen = false;
  void Function(VoidCallback)? _sheetUpdater;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      final stored = prefs.getInt(_recentDaysKey);
      if (!mounted) return;
      setState(() {
        _days = stored != null && stored >= 0 && stored <= _maxRecentDays
            ? stored
            : _defaultRecentDays;
      });
      // Matches the Swift `task(id: isPresented)` initial delivery.
      _deliverDays();
    });
  }

  void _emit(String value) {
    emitJournalEvent(widget.context, 1, value);
  }

  void _deliverDays() {
    if (_deliveredDays != _days) {
      _emit('days:$_days');
      _deliveredDays = _days;
    }
  }

  Future<void> _setDays(int value) async {
    if (value < 0 || value > _maxRecentDays) return;
    setState(() => _days = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_recentDaysKey, value);
    _deliverDays();
  }

  void _openSheet() {
    if (_sheetOpen) return;
    _sheetOpen = true;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          _sheetUpdater = setSheetState;
          return _AssetSettingsSheet(
            days: _days,
            onDaysChanged: _setDays,
            payload: decodeJournalPayload(widget.context),
            onRetry: (id) => _emit('retry:$id'),
            onDone: () => Navigator.of(sheetContext).pop(),
          );
        },
      ),
    ).whenComplete(() {
      _sheetOpen = false;
      _sheetUpdater = null;
      _emit('dismissed');
    });
  }

  @override
  Widget build(BuildContext context) {
    final payload = decodeJournalPayload(widget.context);
    if (payload['presented'] == true && !_sheetOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            decodeJournalPayload(widget.context)['presented'] == true) {
          _openSheet();
        }
      });
    }
    if (_sheetOpen) {
      // Keep the sheet's payload/day state in sync with extension rebuilds.
      final updater = _sheetUpdater;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) updater?.call(() {});
      });
    }
    final childIDs = widget.context.childIDs;
    return childIDs.isEmpty
        ? const SizedBox.shrink()
        : widget.renderChild(childIDs.first);
  }
}

class _AssetSettingsSheet extends StatelessWidget {
  const _AssetSettingsSheet({
    required this.days,
    required this.onDaysChanged,
    required this.payload,
    required this.onRetry,
    required this.onDone,
  });

  final int days;
  final ValueChanged<int> onDaysChanged;
  final Map<String, Object?> payload;
  final ValueChanged<String> onRetry;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final uploads = (payload['uploads'] as List?) ?? const [];
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Attachment settings',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                TextButton(onPressed: onDone, child: const Text('Done')),
              ],
            ),
            const SizedBox(height: 8),
            Text('Offline attachments', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: Text('Recent journal days: $days')),
                IconButton(
                  icon: const Icon(Icons.remove),
                  onPressed: days > 0 ? () => onDaysChanged(days - 1) : null,
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: days < _maxRecentDays
                      ? () => onDaysChanged(days + 1)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Recent journals: ${payload['recent'] ?? ''}',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              'Favorites: ${payload['favorites'] ?? ''}',
              style: theme.textTheme.bodySmall,
            ),
            if (uploads.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Uploads', style: theme.textTheme.titleSmall),
              for (final upload in uploads)
                if (upload is Map)
                  _UploadTile(upload: upload, onRetry: onRetry),
            ],
            const SizedBox(height: 12),
            Text(
              'Downloads attachments from today and the preceding days. '
              'Set to 0 to disable recent-journal downloads.',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              'Favorites include their complete subtrees, regardless of '
              'this setting.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _UploadTile extends StatelessWidget {
  const _UploadTile({required this.upload, required this.onRetry});

  final Map<Object?, Object?> upload;
  final ValueChanged<String> onRetry;

  @override
  Widget build(BuildContext context) {
    final id = '${upload['id']}';
    return journalTestId(
      'journal-upload:$id',
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (upload['busy'] == true)
              const Padding(
                padding: EdgeInsets.only(right: 12, top: 4),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${upload['title']}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${upload['message']}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (upload['retry'] == true)
              journalTestId(
                'journal-upload-retry:$id',
                TextButton(
                  onPressed: () => onRetry(id),
                  child: const Text('Retry'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
