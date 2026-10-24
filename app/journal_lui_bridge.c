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

/* Main-thread entries may synchronously reenter through a patch callback.
   Each frame commits its own result AFTER callback delivery. The getter is
   immediate and operation-matched; success clears a previous failure. */
static _Thread_local int32_t failure_operation;
static _Thread_local int32_t failure_reason;
static int operation_for(const char *name) {
  if (strcmp(name,"lui_ocaml_init")==0) return 1;
  if (strcmp(name,"lui_ocaml_dispose")==0) return 2;
  if (strcmp(name,"journal_ocaml_pump")==0) return 3;
  if (strcmp(name,"journal_ocaml_platform_event")==0) return 4;
  if (strcmp(name,"journal_ocaml_platform_response")==0) return 5;
  if (strcmp(name,"journal_ocaml_platform_failure")==0) return 6;
  if (strcmp(name,"lui_ocaml_root_node")==0) return 8;
  return 7;
}
static void completed(int operation,int reason) {
  failure_operation=operation; failure_reason=reason;
}
LUI_EXPORT int32_t journal_ocaml_failure_reason(int32_t operation) {
  return operation == failure_operation ? failure_reason : 0;
}

static int runtime_started = 0;
static lui_patch_callback patch_callback = NULL;
static journal_wakeup_callback wakeup_callback = NULL;
static journal_platform_request_callback platform_request_callback = NULL;

static void report_ocaml_exception(const char *where, value result) {
  (void)result;
  /* Exception text may contain credentials, paths or graph content. The return
     code reaches the native host, which can report failure without a patch. */
  fprintf(stderr, "journal_lui_bridge: operation=%s code=ocamlCallbackFailed\n", where);
}

/* Only the OCaml owner's exact allowlist is queried. Never format an exception
   or copy its body into the diagnostic channel. Classification itself may fail. */
static int classify_exception(value result) {
  const value *classify = caml_named_value("journal_ocaml_classify_exception");
  if (classify == NULL) return 2;
  CAMLparam0();
  CAMLlocal2(exception, classified);
  exception = Extract_exception(result);
  classified = caml_callback_exn(*classify,exception);
  int reason = 2;
  if (!Is_exception_result(classified) && Is_long(classified)) {
    int candidate = Int_val(classified);
    if (candidate >= 5 && candidate <= 7) reason = candidate;
  }
  CAMLreturnT(int,reason);
}

typedef struct {
  int accepted;
  char *json;
  lui_patch_callback callback;
  int operation;
  int reason;
} patch_response;

static patch_response pending_response(const char *name, int invalid_input) {
  patch_response response = {0,NULL,NULL,operation_for(name),invalid_input ? 4 : 1};
  return response;
}

/* Called with the runtime held. Never hand an OCaml heap pointer to the host:
   applying a patch can synchronously dispatch another event and trigger GC. */
static patch_response copy_patch(const char *where, value result) {
  patch_response response = pending_response(where,0);
  response.callback = patch_callback;
  if (Is_exception_result(result)) {
    report_ocaml_exception(where, result);
    response.reason = classify_exception(result);
    return response;
  }
  size_t length = caml_string_length(result);
  if (response.callback != NULL && length != 0) {
    response.json = malloc(length + 1);
    if (response.json == NULL) {
      fprintf(stderr, "journal_lui_bridge: cannot copy patch in %s\n", where);
      response.reason = 3;
      return response;
    }
    memcpy(response.json, String_val(result), length);
    response.json[length] = '\0';
  }
  response.accepted = 1;
  response.reason = 0;
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
  completed(response.operation,response.reason);
  return response.accepted;
}

static value copy_bytes(const char *data, int32_t length) {
  value text = caml_alloc_string((mlsize_t)length);
  if (length > 0) memcpy(Bytes_val(text), data, (size_t)length);
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
    completed(1,1);
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
  patch_response response = pending_response(name,0);
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

/* Root every allocated pointer argument before subsequent allocations. The
   patch callback executes only after dropping these roots and the runtime. */
static int dispatch_pointer(const char *name, int64_t node, double x, double y,
                            int32_t modifiers, int32_t button,
                            const char *target_class) {
  patch_response response = pending_response(name,target_class == NULL);
  caml_leave_blocking_section();
  const value *dispatch = caml_named_value(name);
  if (dispatch != NULL && target_class != NULL) {
    CAMLparam0();
    CAMLlocalN(arguments, 6);
    CAMLlocal1(result);
    arguments[0] = Val_long(node);
    arguments[1] = caml_copy_double(x);
    arguments[2] = caml_copy_double(y);
    arguments[3] = Val_long(modifiers);
    arguments[4] = Val_long(button);
    arguments[5] = caml_copy_string(target_class);
    result = caml_callbackN_exn(*dispatch, 6, arguments);
    response = copy_patch(name, result);
    CAMLdrop;
  }
  return release_and_deliver(response);
}

#define JOURNAL_POINTER_ENTRY(entry) \
  LUI_EXPORT int32_t entry(int64_t node, double x, double y, \
                           int32_t modifiers, int32_t button, \
                           const char *target_class) { \
    return dispatch_pointer(#entry, node, x, y, modifiers, button, target_class); \
  }

JOURNAL_POINTER_ENTRY(lui_ocaml_press_detail)
JOURNAL_POINTER_ENTRY(lui_ocaml_pointer_down)
JOURNAL_POINTER_ENTRY(lui_ocaml_pointer_up)
JOURNAL_POINTER_ENTRY(lui_ocaml_context_menu_press)

LUI_EXPORT int32_t lui_ocaml_pointer_enter(int64_t node) {
  return dispatch_long("lui_ocaml_pointer_enter", node);
}

LUI_EXPORT int32_t lui_ocaml_pointer_leave(int64_t node) {
  return dispatch_long("lui_ocaml_pointer_leave", node);
}

static int dispatch_string(const char *name, int64_t node, const char *text) {
  patch_response response = pending_response(name,text == NULL);
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
  patch_response response = pending_response("lui_ocaml_toggle_changed",0);
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
  patch_response response = pending_response("lui_ocaml_slider_changed",0);
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
  patch_response response = pending_response("lui_ocaml_scroll_completed",outcome == NULL);
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
  patch_response response = pending_response("lui_ocaml_visible_range",0);
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
  patch_response response = pending_response("lui_ocaml_dispose",0);
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
  patch_response response = pending_response("journal_ocaml_extension_event",name == NULL || payload == NULL);
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
  patch_response response = pending_response("journal_ocaml_pump",0);
  caml_leave_blocking_section();
  const value *pump = caml_named_value("journal_ocaml_pump");
  if (pump != NULL) {
    response = copy_patch("journal_ocaml_pump",
                        caml_callback_exn(*pump, Val_unit));
  }
  return release_and_deliver(response);
}

/* Host -> OCaml LJP2/LJF1 envelopes (binary safe). */
static int32_t deliver_platform(const char *name, const char *data,
                                int32_t length) {
  if (length < 0 || (length > 0 && data == NULL)) { completed(operation_for(name),4); return 0; }
  int32_t accepted = 0, reason = 1;
  caml_leave_blocking_section();
  const value *handler = caml_named_value(name);
  if (handler != NULL) {
    value payload = copy_bytes(data, length);
    value result = caml_callback_exn(*handler, payload);
    if (Is_exception_result(result)) {
      report_ocaml_exception(name, result);
      reason = classify_exception(result);
    } else {
      accepted = 1; reason = 0;
    }
  }
  caml_enter_blocking_section();
  completed(operation_for(name),reason);
  return accepted;
}

LUI_EXPORT int32_t journal_ocaml_platform_event(const char *data,
                                               int32_t length) {
  return deliver_platform("journal_ocaml_platform_event", data, length);
}

LUI_EXPORT int32_t journal_ocaml_platform_response(const char *data,
                                                  int32_t length) {
  return deliver_platform("journal_ocaml_platform_response", data, length);
}

/* The host reports a failed platform request with a finite LJF1 envelope.
   The legacy original-request form remains supported by the OCaml decoder. */
LUI_EXPORT int32_t journal_ocaml_platform_failure(const char *data,
                                                 int32_t length) {
  return deliver_platform("journal_ocaml_platform_failure", data, length);
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
