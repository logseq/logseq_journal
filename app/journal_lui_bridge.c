#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/printexc.h>
#include <caml/signals.h>
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

static void report_ocaml_exception(const char *where, value result) {
  char *message = caml_format_exception(Extract_exception(result));
  fprintf(stderr, "journal_lui_bridge: OCaml exception in %s: %s\n",
          where, message);
  caml_stat_free(message);
}

typedef struct {
  int accepted;
  char *json;
  lui_patch_callback callback;
} patch_response;

/* Called with the runtime held. Never hand an OCaml heap pointer to the host:
   applying a patch can synchronously dispatch another event and trigger GC. */
static patch_response copy_patch(const char *where, value result) {
  patch_response response = {0, NULL, patch_callback};
  if (Is_exception_result(result)) {
    report_ocaml_exception(where, result);
    return response;
  }
  size_t length = caml_string_length(result);
  if (response.callback != NULL && length != 0) {
    response.json = malloc(length + 1);
    if (response.json == NULL) {
      fprintf(stderr, "journal_lui_bridge: cannot copy patch in %s\n", where);
      return response;
    }
    memcpy(response.json, String_val(result), length);
    response.json[length] = '\0';
  }
  response.accepted = 1;
  return response;
}

/* Call only after dropping the entry's local roots. Each stack frame owns its
   response until the callback returns, including during nested host events.
   The backend finishes a batch before delivering its deferred events, so a
   nested response follows the outer batch without overwriting its bytes. */
static int release_and_deliver(patch_response response) {
  caml_enter_blocking_section();
  if (response.json != NULL) {
    response.callback(response.json);
    free(response.json);
  }
  return response.accepted;
}

static value copy_bytes(const char *data, int32_t length) {
  value text = caml_alloc_string((mlsize_t)length);
  memcpy(Bytes_val(text), data, (size_t)length);
  return text;
}

LUI_EXPORT int32_t lui_ocaml_start(
    lui_patch_callback callback,
    int32_t platform_code,
    int32_t host_code,
    const char *payload_data,
    int32_t payload_length) {
  patch_response response;
  patch_callback = callback;
  if (!runtime_started) {
    char *arguments[] = {"journal_lui_ocaml", NULL};
    caml_startup(arguments);
    runtime_started = 1;
  } else {
    caml_leave_blocking_section();
  }

  const value *initialize = caml_named_value("lui_ocaml_init");
  if (initialize == NULL) {
    caml_enter_blocking_section();
    return 0;
  }
  CAMLparam0();
  CAMLlocal2(payload_value, result);
  payload_value = copy_bytes(payload_data, payload_length);
  result = caml_callback3_exn(
      *initialize,
      Val_long(platform_code),
      Val_long(host_code),
      payload_value);
  response = copy_patch("lui_ocaml_init", result);
  CAMLdrop;
  return release_and_deliver(response);
}

static int dispatch_long(const char *name, int64_t node) {
  patch_response response = {0, NULL, NULL};
  caml_leave_blocking_section();
  const value *dispatch = caml_named_value(name);
  if (dispatch != NULL) {
    response = copy_patch(name, caml_callback_exn(*dispatch, Val_long(node)));
  }
  return release_and_deliver(response);
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

static int dispatch_string(const char *name, int64_t node, const char *text) {
  patch_response response = {0, NULL, NULL};
  caml_leave_blocking_section();
  const value *dispatch = caml_named_value(name);
  if (dispatch != NULL && text != NULL) {
    CAMLparam0();
    CAMLlocal2(text_value, callback_result);
    text_value = caml_copy_string(text);
    callback_result = caml_callback2_exn(*dispatch, Val_long(node), text_value);
    response = copy_patch(name, callback_result);
    CAMLdrop;
  }
  return release_and_deliver(response);
}

LUI_EXPORT int32_t lui_ocaml_text_changed(int64_t node, const char *text) {
  return dispatch_string("lui_ocaml_text_changed", node, text);
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
  patch_response response = {0, NULL, NULL};
  caml_leave_blocking_section();
  const value *dispatch = caml_named_value("lui_ocaml_toggle_changed");
  if (dispatch != NULL) {
    response = copy_patch("lui_ocaml_toggle_changed", caml_callback2_exn(
        *dispatch, Val_long(node), Val_bool(checked)));
  }
  return release_and_deliver(response);
}

LUI_EXPORT int32_t lui_ocaml_radio_changed(int64_t node) {
  return dispatch_long("lui_ocaml_radio_changed", node);
}

LUI_EXPORT int32_t lui_ocaml_slider_changed(int64_t node, double fraction) {
  patch_response response = {0, NULL, NULL};
  caml_leave_blocking_section();
  const value *dispatch = caml_named_value("lui_ocaml_slider_changed");
  if (dispatch != NULL) {
    response = copy_patch("lui_ocaml_slider_changed", caml_callback2_exn(
        *dispatch, Val_long(node), caml_copy_double(fraction)));
  }
  return release_and_deliver(response);
}

LUI_EXPORT int32_t lui_ocaml_scroll_completed(int64_t node, int64_t token,
                                            const char *outcome) {
  patch_response response = {0, NULL, NULL};
  caml_leave_blocking_section();
  const value *dispatch = caml_named_value("lui_ocaml_scroll_completed");
  if (dispatch != NULL && outcome != NULL) {
    CAMLparam0();
    CAMLlocal2(outcome_value, callback_result);
    outcome_value = caml_copy_string(outcome);
    callback_result = caml_callback3_exn(
        *dispatch, Val_long(node), Val_long(token), outcome_value);
    response = copy_patch("lui_ocaml_scroll_completed", callback_result);
    CAMLdrop;
  }
  return release_and_deliver(response);
}

LUI_EXPORT int32_t lui_ocaml_visible_range(int64_t node, int64_t first,
                                         int64_t last) {
  patch_response response = {0, NULL, NULL};
  caml_leave_blocking_section();
  const value *dispatch = caml_named_value("lui_ocaml_visible_range");
  if (dispatch != NULL) {
    response = copy_patch("lui_ocaml_visible_range", caml_callback3_exn(
        *dispatch, Val_long(node), Val_long(first), Val_long(last)));
  }
  return release_and_deliver(response);
}

LUI_EXPORT int32_t lui_ocaml_picked(int64_t node, const char *payload) {
  return dispatch_string("lui_ocaml_picked", node, payload);
}

LUI_EXPORT int32_t lui_ocaml_stop(void) {
  patch_response response = {0, NULL, NULL};
  caml_leave_blocking_section();
  const value *dispose = caml_named_value("lui_ocaml_dispose");
  if (dispose != NULL) {
    response = copy_patch("lui_ocaml_dispose",
                        caml_callback_exn(*dispose, Val_unit));
  }
  return release_and_deliver(response);
}

LUI_EXPORT int64_t lui_ocaml_root_node(void) {
  int64_t node = 0;
  caml_leave_blocking_section();
  const value *root = caml_named_value("lui_ocaml_root_node");
  if (root != NULL) {
    value result = caml_callback_exn(*root, Val_unit);
    if (Is_exception_result(result)) {
      report_ocaml_exception("lui_ocaml_root_node", result);
    } else {
      node = (int64_t)Long_val(result);
    }
  }
  caml_enter_blocking_section();
  return node;
}

/* ---- Journal-specific entries ---- */

/* Forwards a journal extension event: node id, extension event name, and a
   JSON object of wire values decoded by the OCaml side. */
LUI_EXPORT int32_t journal_ocaml_extension_event(
    int64_t node,
    const char *name,
    const char *payload) {
  patch_response response = {0, NULL, NULL};
  caml_leave_blocking_section();
  const value *dispatch = caml_named_value("journal_ocaml_extension_event");
  if (dispatch != NULL && name != NULL && payload != NULL) {
    CAMLparam0();
    CAMLlocal3(name_value, payload_value, callback_result);
    name_value = caml_copy_string(name);
    payload_value = caml_copy_string(payload);
    callback_result = caml_callback3_exn(
        *dispatch, Val_long(node), name_value, payload_value);
    response = copy_patch("journal_ocaml_extension_event", callback_result);
    CAMLdrop;
  }
  return release_and_deliver(response);
}

/* Drains the cross-thread work queue on the app thread and flushes pending
   patches. The host schedules this on the UI thread when the wakeup callback
   fires. */
LUI_EXPORT int32_t journal_ocaml_pump(void) {
  patch_response response = {0, NULL, NULL};
  caml_leave_blocking_section();
  const value *pump = caml_named_value("journal_ocaml_pump");
  if (pump != NULL) {
    response = copy_patch("journal_ocaml_pump",
                        caml_callback_exn(*pump, Val_unit));
  }
  return release_and_deliver(response);
}

/* Host -> OCaml LJP2 envelopes (binary safe). */
static void deliver_platform(const char *name, const char *data,
                             int32_t length) {
  caml_leave_blocking_section();
  const value *handler = caml_named_value(name);
  if (handler != NULL) {
    value payload = copy_bytes(data, length);
    value result = caml_callback_exn(*handler, payload);
    if (Is_exception_result(result)) {
      report_ocaml_exception(name, result);
    }
  }
  caml_enter_blocking_section();
}

LUI_EXPORT void journal_ocaml_platform_event(const char *data,
                                             int32_t length) {
  deliver_platform("journal_ocaml_platform_event", data, length);
}

LUI_EXPORT void journal_ocaml_platform_response(const char *data,
                                                int32_t length) {
  deliver_platform("journal_ocaml_platform_response", data, length);
}

/* The host reports a failed platform request by passing the original
   request envelope; OCaml resolves the pending continuation with an
   error instead of leaving it parked forever. */
LUI_EXPORT void journal_ocaml_platform_failure(const char *data,
                                               int32_t length) {
  deliver_platform("journal_ocaml_platform_failure", data, length);
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
