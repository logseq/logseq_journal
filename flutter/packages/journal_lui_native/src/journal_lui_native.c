#include <stdint.h>

/*
 * Non-Apple stub: the LUI OCaml runtime is only embedded when the
 * native_artifact_root complete object resolves (macOS / iPhoneOS builds).
 * Every journal bridge export still resolves so the code asset links cleanly;
 * calls report failure exactly like the real bridge does on error.
 */

#if defined(_WIN32)
#define JL_EXPORT __declspec(dllexport)
#else
#define JL_EXPORT __attribute__((visibility("default")))
#endif

typedef void (*jl_patch_callback)(const char *json);
typedef void (*jl_wakeup_callback)(void);
typedef void (*jl_platform_request_callback)(const char *data, int32_t length);

JL_EXPORT int32_t lui_ocaml_start(
    jl_patch_callback callback, int32_t platform_code, int32_t host_code) {
  (void)callback;
  (void)platform_code;
  (void)host_code;
  return 0;
}

JL_EXPORT int32_t lui_ocaml_stop(void) { return 0; }
JL_EXPORT int32_t lui_ocaml_appear(int64_t node) { (void)node; return 0; }
JL_EXPORT int32_t lui_ocaml_press(int64_t node) { (void)node; return 0; }
JL_EXPORT int32_t lui_ocaml_long_press(int64_t node) { (void)node; return 0; }
JL_EXPORT int32_t lui_ocaml_text_changed(int64_t node, const char *text) {
  (void)node;
  (void)text;
  return 0;
}
JL_EXPORT int32_t lui_ocaml_submit(int64_t node) { (void)node; return 0; }
JL_EXPORT int32_t lui_ocaml_dismiss(int64_t node) { (void)node; return 0; }
JL_EXPORT int32_t lui_ocaml_double_press(int64_t node) { (void)node; return 0; }
JL_EXPORT int32_t lui_ocaml_toggle_changed(int64_t node, int32_t checked) {
  (void)node;
  (void)checked;
  return 0;
}
JL_EXPORT int32_t lui_ocaml_radio_changed(int64_t node) { (void)node; return 0; }
JL_EXPORT int32_t lui_ocaml_slider_changed(int64_t node, double fraction) {
  (void)node;
  (void)fraction;
  return 0;
}
JL_EXPORT int64_t lui_ocaml_root_node(void) { return -1; }

JL_EXPORT int32_t journal_ocaml_extension_event(
    int64_t node, const char *name, const char *payload) {
  (void)node;
  (void)name;
  (void)payload;
  return 0;
}
JL_EXPORT int32_t journal_ocaml_pump(void) { return 0; }
JL_EXPORT void journal_ocaml_platform_event(const char *data, int32_t length) {
  (void)data;
  (void)length;
}
JL_EXPORT void journal_ocaml_platform_response(const char *data, int32_t length) {
  (void)data;
  (void)length;
}
JL_EXPORT void journal_ocaml_set_wakeup_callback(jl_wakeup_callback callback) {
  (void)callback;
}
JL_EXPORT void journal_ocaml_set_platform_request_callback(
    jl_platform_request_callback callback) {
  (void)callback;
}
