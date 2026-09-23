#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/mlvalues.h>
#include <caml/startup.h>

#if defined(_WIN32)
#define LUI_EXPORT __declspec(dllexport)
#else
#define LUI_EXPORT __attribute__((visibility("default")))
#endif

typedef void (*lui_patch_callback)(const char *json);
typedef void (*journal_wakeup_callback)(void);
typedef void (*journal_platform_request_callback)(const char *data,
                                                  int32_t length);

static int runtime_started = 0;
static lui_patch_callback patch_callback = NULL;
static journal_wakeup_callback wakeup_callback = NULL;
static journal_platform_request_callback platform_request_callback = NULL;

static int emit_patch(value result) {
  if (Is_exception_result(result)) {
    return 0;
  }
  const char *json = String_val(result);
  if (patch_callback != NULL && json[0] != '\0') {
    patch_callback(json);
  }
  return 1;
}

static value copy_bytes(const char *data, int32_t length) {
  value text = caml_alloc_string((mlsize_t)length);
  memcpy(Bytes_val(text), data, (size_t)length);
  return text;
}

LUI_EXPORT int32_t lui_ocaml_start(
    lui_patch_callback callback,
    int32_t platform_code,
    int32_t host_code) {
  patch_callback = callback;
  if (!runtime_started) {
    char *arguments[] = {"journal_lui_ocaml", NULL};
    caml_startup(arguments);
    runtime_started = 1;
  }

  const value *initialize = caml_named_value("lui_ocaml_init");
  if (initialize == NULL) {
    return 0;
  }
  return emit_patch(caml_callback2_exn(
      *initialize,
      Val_long(platform_code),
      Val_long(host_code)));
}

static int dispatch_long(const char *name, int64_t node) {
  const value *dispatch = caml_named_value(name);
  if (dispatch == NULL) {
    return 0;
  }
  return emit_patch(caml_callback_exn(*dispatch, Val_long(node)));
}

LUI_EXPORT int32_t lui_ocaml_appear(int64_t node) {
  return dispatch_long("lui_ocaml_appear", node);
}

LUI_EXPORT int32_t lui_ocaml_press(int64_t node) {
  return dispatch_long("lui_ocaml_press", node);
}

LUI_EXPORT int32_t lui_ocaml_long_press(int64_t node) {
  return dispatch_long("lui_ocaml_long_press", node);
}

LUI_EXPORT int32_t lui_ocaml_text_changed(int64_t node, const char *text) {
  const value *dispatch = caml_named_value("lui_ocaml_text_changed");
  if (dispatch == NULL) {
    return 0;
  }
  return emit_patch(caml_callback2_exn(
      *dispatch, Val_long(node), caml_copy_string(text)));
}

LUI_EXPORT int32_t lui_ocaml_submit(int64_t node) {
  return dispatch_long("lui_ocaml_submit", node);
}

LUI_EXPORT int32_t lui_ocaml_dismiss(int64_t node) {
  return dispatch_long("lui_ocaml_dismiss", node);
}

LUI_EXPORT int32_t lui_ocaml_double_press(int64_t node) {
  return dispatch_long("lui_ocaml_double_press", node);
}

LUI_EXPORT int32_t lui_ocaml_toggle_changed(int64_t node, int32_t checked) {
  const value *dispatch = caml_named_value("lui_ocaml_toggle_changed");
  if (dispatch == NULL) {
    return 0;
  }
  return emit_patch(caml_callback2_exn(
      *dispatch, Val_long(node), Val_bool(checked)));
}

LUI_EXPORT int32_t lui_ocaml_radio_changed(int64_t node) {
  return dispatch_long("lui_ocaml_radio_changed", node);
}

LUI_EXPORT int32_t lui_ocaml_slider_changed(int64_t node, double fraction) {
  const value *dispatch = caml_named_value("lui_ocaml_slider_changed");
  if (dispatch == NULL) {
    return 0;
  }
  return emit_patch(caml_callback2_exn(
      *dispatch, Val_long(node), caml_copy_double(fraction)));
}

LUI_EXPORT int32_t lui_ocaml_stop(void) {
  const value *dispose = caml_named_value("lui_ocaml_dispose");
  if (dispose == NULL) {
    return 0;
  }
  return emit_patch(caml_callback_exn(*dispose, Val_unit));
}

LUI_EXPORT int64_t lui_ocaml_root_node(void) {
  const value *root = caml_named_value("lui_ocaml_root_node");
  if (root == NULL) {
    return 0;
  }
  value result = caml_callback_exn(*root, Val_unit);
  if (Is_exception_result(result)) {
    return 0;
  }
  return (int64_t)Long_val(result);
}

/* ---- Journal-specific entries ---- */

/* Forwards a journal extension event: node id, extension event name, and a
   JSON object of wire values decoded by the OCaml side. */
LUI_EXPORT int32_t journal_ocaml_extension_event(
    int64_t node,
    const char *name,
    const char *payload) {
  const value *dispatch = caml_named_value("journal_ocaml_extension_event");
  if (dispatch == NULL) {
    return 0;
  }
  return emit_patch(caml_callback3_exn(
      *dispatch,
      Val_long(node),
      caml_copy_string(name),
      caml_copy_string(payload)));
}

/* Drains the cross-thread work queue on the app thread and flushes pending
   patches. The host schedules this on the UI thread when the wakeup callback
   fires. */
LUI_EXPORT int32_t journal_ocaml_pump(void) {
  const value *pump = caml_named_value("journal_ocaml_pump");
  if (pump == NULL) {
    return 0;
  }
  return emit_patch(caml_callback_exn(*pump, Val_unit));
}

/* Host -> OCaml LJP2 envelopes (binary safe). */
static void deliver_platform(const char *name, const char *data,
                             int32_t length) {
  const value *handler = caml_named_value(name);
  if (handler == NULL) {
    return;
  }
  value payload = copy_bytes(data, length);
  caml_callback_exn(*handler, payload);
}

LUI_EXPORT void journal_ocaml_platform_event(const char *data,
                                             int32_t length) {
  deliver_platform("journal_ocaml_platform_event", data, length);
}

LUI_EXPORT void journal_ocaml_platform_response(const char *data,
                                                int32_t length) {
  deliver_platform("journal_ocaml_platform_response", data, length);
}

/* Host-installed callbacks for OCaml -> host delivery. */
LUI_EXPORT void journal_ocaml_set_wakeup_callback(
    journal_wakeup_callback callback) {
  wakeup_callback = callback;
}

LUI_EXPORT void journal_ocaml_set_platform_request_callback(
    journal_platform_request_callback callback) {
  platform_request_callback = callback;
}

CAMLprim value journal_ml_wakeup(value unit) {
  (void)unit;
  if (wakeup_callback != NULL) {
    wakeup_callback();
  }
  return Val_unit;
}

CAMLprim value journal_ml_platform_request(value payload) {
  if (platform_request_callback != NULL) {
    platform_request_callback(
        (const char *)Bytes_val(payload),
        (int32_t)caml_string_length(payload));
  }
  return Val_unit;
}
