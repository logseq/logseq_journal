import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lui_flutter_backend/lui_flutter_backend.dart';

import 'journal_ext_utils.dart';

/// Port of `JournalAssetImport.swift` (`journal-asset-import`).
///
/// Payload: `{enabled, completion?, error?, replace?, request}`.
/// `request` is a counter; when it changes while `replace` is armed the file
/// picker re-opens. `completion` carries the finished operation id so the
/// renderer can release its selection. Events are emitted with `id: 1` and a
/// JSON payload: a pick sends
/// `{operation, asset, localMutation, metadataMutation, path, title,
///   replaceReference?, type}` and cancelling an armed picker sends
/// `{"action": "dismissed"}`.
Widget buildJournalAssetImport(LUIFlutterExtensionContext context) =>
    _JournalAssetImportView(context: context);

class _JournalAssetImportView extends StatefulWidget {
  const _JournalAssetImportView({required this.context});

  final LUIFlutterExtensionContext context;

  @override
  State<_JournalAssetImportView> createState() =>
      _JournalAssetImportViewState();
}

class _JournalAssetImportViewState extends State<_JournalAssetImportView> {
  String? _operation;
  bool _pickerOpen = false;
  bool _handled = false;
  String? _error;
  int _lastRequest = -1;
  String? _lastCompletion;

  Map<String, Object?> get _payload => decodeJournalPayload(widget.context);

  void _emitDismissed() {
    if (_handled) return;
    _handled = true;
    emitJournalEvent(widget.context, 1, const {'action': 'dismissed'});
  }

  Future<void> _pick() async {
    setState(() {
      _pickerOpen = true;
      _handled = false;
    });
    PlatformFile? file;
    String? pickError;
    try {
      file = await FilePicker.pickFile();
    } catch (_) {
      pickError = 'Unable to access the selected file. Please try again.';
    }
    if (!mounted) return;
    final replace = _payload['replace'];
    setState(() => _pickerOpen = false);
    if (file == null || file.path == null) {
      // Cancelled (or errored) with an armed replace request counts as a
      // dismissal, matching the iOS fileImporter behaviour.
      setState(() => _error = pickError);
      if (replace != null) _emitDismissed();
      return;
    }
    _handled = true;
    final operation = newJournalUuid();
    final extension = file.extension?.toLowerCase() ?? '';
    emitJournalEvent(widget.context, 1, <String, Object?>{
      'operation': operation,
      'asset': newJournalUuid(),
      'localMutation': newJournalUuid(),
      'metadataMutation': newJournalUuid(),
      'path': file.path,
      'title': file.name,
      'replaceReference': replace,
      'type': extension.isEmpty ? 'bin' : extension,
    });
    setState(() => _operation = operation);
  }

  @override
  Widget build(BuildContext context) {
    final payload = _payload;
    final request = payload['request'];
    final requestNumber = request is int ? request : 0;
    final replace = payload['replace'];
    if (replace != null &&
        requestNumber != _lastRequest &&
        _lastRequest >= 0 &&
        !_pickerOpen) {
      _lastRequest = requestNumber;
      WidgetsBinding.instance.addPostFrameCallback((_) => _pick());
    } else {
      _lastRequest = requestNumber;
    }
    final completion = payload['completion'];
    if (completion is String &&
        completion == _operation &&
        completion != _lastCompletion) {
      _operation = null;
      _error = payload['error'] is String ? payload['error'] as String : null;
    }
    _lastCompletion = completion is String ? completion : _lastCompletion;

    final enabled = payload['enabled'] != false && _operation == null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        journalTestId(
          'journal-asset-import',
          FilledButton.icon(
            onPressed: enabled ? _pick : null,
            icon: _operation == null
                ? const Icon(Icons.attach_file, size: 18)
                : const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
            label: Text(_operation == null ? 'Attach file' : 'Importing file'),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _error!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}
