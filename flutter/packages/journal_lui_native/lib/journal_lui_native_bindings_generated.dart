// ignore_for_file: camel_case_types, non_constant_identifier_names

// Hand-maintained FFI surface for app/journal_lui_bridge.c.
//
// Symbols link through the `journal_lui_native` code asset built by
// hook/build.dart (the OCaml complete object already contains the bridge C
// stubs, so the hook only needs the artifact, the iOS process stubs and the
// export list). Names and signatures must stay in lockstep with the C file.

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' show Utf8;

typedef JL_PATCH_CALLBACK = ffi.Void Function(ffi.Pointer<Utf8>);
typedef JL_WAKEUP_CALLBACK = ffi.Void Function();
typedef JL_PLATFORM_REQUEST_CALLBACK =
    ffi.Void Function(ffi.Pointer<ffi.Uint8>, ffi.Int32);

@ffi.Native<
  ffi.Int32 Function(
    ffi.Pointer<ffi.NativeFunction<JL_PATCH_CALLBACK>>,
    ffi.Int32,
    ffi.Int32,
    ffi.Pointer<ffi.Uint8>,
    ffi.Int32,
  )
>()
external int lui_ocaml_start(
  ffi.Pointer<ffi.NativeFunction<JL_PATCH_CALLBACK>> callback,
  int platform,
  int host,
  ffi.Pointer<ffi.Uint8> payloadData,
  int payloadLength,
);

@ffi.Native<ffi.Int32 Function()>()
external int lui_ocaml_stop();

@ffi.Native<ffi.Int32 Function(ffi.Int64)>()
external int lui_ocaml_appear(int node);

@ffi.Native<ffi.Int32 Function(ffi.Int64)>()
external int lui_ocaml_press(int node);

@ffi.Native<ffi.Int32 Function(ffi.Int64)>()
external int lui_ocaml_long_press(int node);

@ffi.Native<ffi.Int32 Function(ffi.Int64, ffi.Pointer<Utf8>)>()
external int lui_ocaml_text_changed(int node, ffi.Pointer<Utf8> text);

@ffi.Native<ffi.Int32 Function(ffi.Int64)>()
external int lui_ocaml_submit(int node);

@ffi.Native<ffi.Int32 Function(ffi.Int64)>()
external int lui_ocaml_dismiss(int node);

@ffi.Native<ffi.Int32 Function(ffi.Int64)>()
external int lui_ocaml_double_press(int node);

@ffi.Native<ffi.Int32 Function(ffi.Int64, ffi.Int32)>()
external int lui_ocaml_toggle_changed(int node, int checked);

@ffi.Native<ffi.Int32 Function(ffi.Int64)>()
external int lui_ocaml_radio_changed(int node);

@ffi.Native<ffi.Int32 Function(ffi.Int64, ffi.Double)>()
external int lui_ocaml_slider_changed(int node, double fraction);

@ffi.Native<ffi.Int64 Function()>()
external int lui_ocaml_root_node();

@ffi.Native<
  ffi.Int32 Function(ffi.Int64, ffi.Pointer<Utf8>, ffi.Pointer<Utf8>)
>()
external int journal_ocaml_extension_event(
  int node,
  ffi.Pointer<Utf8> name,
  ffi.Pointer<Utf8> payload,
);

@ffi.Native<ffi.Int32 Function()>()
external int journal_ocaml_pump();

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Uint8>, ffi.Int32)>()
external void journal_ocaml_platform_event(
  ffi.Pointer<ffi.Uint8> data,
  int length,
);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Uint8>, ffi.Int32)>()
external void journal_ocaml_platform_response(
  ffi.Pointer<ffi.Uint8> data,
  int length,
);

@ffi.Native<
  ffi.Void Function(
    ffi.Pointer<ffi.NativeFunction<JL_WAKEUP_CALLBACK>>,
  )
>()
external void journal_ocaml_set_wakeup_callback(
  ffi.Pointer<ffi.NativeFunction<JL_WAKEUP_CALLBACK>> callback,
);

@ffi.Native<
  ffi.Void Function(
    ffi.Pointer<ffi.NativeFunction<JL_PLATFORM_REQUEST_CALLBACK>>,
  )
>()
external void journal_ocaml_set_platform_request_callback(
  ffi.Pointer<ffi.NativeFunction<JL_PLATFORM_REQUEST_CALLBACK>> callback,
);
