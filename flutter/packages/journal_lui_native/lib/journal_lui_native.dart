import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'journal_lui_native_bindings_generated.dart' as bindings;

typedef _NativePatchCallback = Void Function(Pointer<Utf8>);
typedef _NativeWakeupCallback = Void Function();
typedef _NativePlatformRequestCallback =
    Void Function(Pointer<Uint8>, Int32);

/// Journal counterpart to `LUIOcamlBridge`: binds the `lui_ocaml_*` entries
/// plus the journal-specific exports (`journal_ocaml_*`) declared in
/// `app/journal_lui_bridge.c`. Symbols resolve through the `journal_lui_native`
/// code asset, not `DynamicLibrary`, so calls work wherever the asset is
/// linked (macOS / iPhoneOS Runner targets).
final class JournalOcamlBridge {
  JournalOcamlBridge({required this.onPatch});

  final void Function(String json) onPatch;
  NativeCallable<_NativePatchCallback>? _patchCallback;
  NativeCallable<_NativeWakeupCallback>? _wakeupCallback;
  NativeCallable<_NativePlatformRequestCallback>? _platformRequestCallback;
  bool _started = false;

  /// Boots the OCaml runtime and performs the initial patch flush. Platform
  /// and host codes match `lui` (`platform/flutter/lib/lui_ocaml_bridge.dart`):
  /// macOS 1, iOS 2, android 3, linux 4, windows 5; Flutter host 3.
  ///
  /// [payload] is the LDB1 startup envelope OCaml decodes via
  /// `Journal_startup.decode` — it must arrive at init because the worker
  /// session starts inside init.
  void start({
    required int platform,
    int host = 3,
    Uint8List? payload,
  }) {
    if (_started) {
      throw StateError('OCaml bridge is already started');
    }
    final callback = NativeCallable<_NativePatchCallback>.isolateLocal(
      (Pointer<Utf8> json) => onPatch(json.toDartString()),
    );
    _patchCallback = callback;
    final payloadBytes = payload ?? Uint8List(0);
    final payloadData = malloc<Uint8>(payloadBytes.length);
    try {
      if (payloadBytes.isNotEmpty) {
        payloadData.asTypedList(payloadBytes.length).setAll(0, payloadBytes);
      }
      if (bindings.lui_ocaml_start(
            callback.nativeFunction,
            platform,
            host,
            payloadData,
            payloadBytes.length,
          ) !=
          1) {
        callback.close();
        _patchCallback = null;
        throw StateError('OCaml runtime initialization failed');
      }
    } finally {
      malloc.free(payloadData);
    }
    _started = true;
  }

  /// OCaml -> host: schedule `wakeup()` on the UI isolate. `journal_ml_wakeup`
  /// can fire from non-UI threads, so a `.listener` callable is required;
  /// the delivered callback itself stays on this isolate.
  void installWakeupCallback(void Function() wakeup) {
    _wakeupCallback ??= NativeCallable<_NativeWakeupCallback>.listener(
      wakeup,
    );
    bindings.journal_ocaml_set_wakeup_callback(
      _wakeupCallback!.nativeFunction,
    );
  }

  /// OCaml -> host: LJP2 platform requests. Requests originate on the app
  /// thread during dispatches/pumps, so a synchronous `isolateLocal` callable
  /// is correct and lets the bytes be copied while the pointer is valid.
  void installPlatformRequestCallback(void Function(Uint8List bytes) request) {
    _platformRequestCallback ??=
        NativeCallable<_NativePlatformRequestCallback>.isolateLocal(
      (Pointer<Uint8> data, int length) {
        final bytes = data == nullptr || length <= 0
            ? Uint8List(0)
            : Uint8List.fromList(data.asTypedList(length));
        request(bytes);
      },
    );
    bindings.journal_ocaml_set_platform_request_callback(
      _platformRequestCallback!.nativeFunction,
    );
  }

  void appear(int node) {
    if (bindings.lui_ocaml_appear(node) != 1) {
      throw StateError('OCaml appear dispatch failed');
    }
  }

  void press(int node) {
    if (bindings.lui_ocaml_press(node) != 1) {
      throw StateError('OCaml press dispatch failed');
    }
  }

  void longPress(int node) {
    if (bindings.lui_ocaml_long_press(node) != 1) {
      throw StateError('OCaml long-press dispatch failed');
    }
  }

  void doublePress(int node) {
    if (bindings.lui_ocaml_double_press(node) != 1) {
      throw StateError('OCaml double-press dispatch failed');
    }
  }

  void textChanged(int node, String text) {
    final nativeText = text.toNativeUtf8();
    try {
      if (bindings.lui_ocaml_text_changed(node, nativeText) != 1) {
        throw StateError('OCaml text dispatch failed');
      }
    } finally {
      malloc.free(nativeText);
    }
  }

  void submit(int node) {
    if (bindings.lui_ocaml_submit(node) != 1) {
      throw StateError('OCaml submit dispatch failed');
    }
  }

  void dismiss(int node) {
    if (bindings.lui_ocaml_dismiss(node) != 1) {
      throw StateError('OCaml dismiss dispatch failed');
    }
  }

  void toggleChanged(int node, bool checked) {
    if (bindings.lui_ocaml_toggle_changed(node, checked ? 1 : 0) != 1) {
      throw StateError('OCaml toggle dispatch failed');
    }
  }

  void radioChanged(int node) {
    if (bindings.lui_ocaml_radio_changed(node) != 1) {
      throw StateError('OCaml radio dispatch failed');
    }
  }

  void sliderChanged(int node, double value) {
    if (bindings.lui_ocaml_slider_changed(node, value) != 1) {
      throw StateError('OCaml slider dispatch failed');
    }
  }

  int get rootNode => _requiredNode(bindings.lui_ocaml_root_node(), 'root');

  int _requiredNode(int node, String name) {
    if (node < 0) throw StateError('OCaml $name node lookup failed');
    return node;
  }

  /// Forwards a journal extension event. `payload` is the JSON object of the
  /// event's wire values, e.g. `{"id":1,"payload":"{...}"}` — see
  /// `journal_lui_bridge.c` and `journal_lui_native.decode_event`.
  void extensionEvent(int node, String name, String payloadJson) {
    final nativeName = name.toNativeUtf8();
    final nativePayload = payloadJson.toNativeUtf8();
    try {
      if (bindings.journal_ocaml_extension_event(
            node,
            nativeName,
            nativePayload,
          ) !=
          1) {
        throw StateError('OCaml extension-event dispatch failed');
      }
    } finally {
      malloc.free(nativeName);
      malloc.free(nativePayload);
    }
  }

  /// Drains the cross-thread work queue; invoked on the UI isolate when the
  /// wakeup callback fires. May emit patches via the patch callback.
  void pump() {
    if (bindings.journal_ocaml_pump() != 1) {
      throw StateError('OCaml pump dispatch failed');
    }
  }

  void platformEvent(Uint8List bytes) =>
      _deliverPlatform(bytes, bindings.journal_ocaml_platform_event);

  void platformResponse(Uint8List bytes) =>
      _deliverPlatform(bytes, bindings.journal_ocaml_platform_response);

  void _deliverPlatform(
    Uint8List bytes,
    void Function(Pointer<Uint8>, int) entry,
  ) {
    if (bytes.isEmpty) {
      entry(nullptr, 0);
      return;
    }
    final data = malloc<Uint8>(bytes.length);
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      entry(data, bytes.length);
    } finally {
      malloc.free(data);
    }
  }

  void close() {
    if (!_started) return;
    if (bindings.lui_ocaml_stop() != 1) {
      throw StateError('OCaml runtime disposal failed');
    }
    bindings.journal_ocaml_set_wakeup_callback(nullptr);
    bindings.journal_ocaml_set_platform_request_callback(nullptr);
    _wakeupCallback?.close();
    _platformRequestCallback?.close();
    _wakeupCallback = null;
    _platformRequestCallback = null;
    _patchCallback?.close();
    _patchCallback = null;
    _started = false;
  }
}
