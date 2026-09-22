#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

typedef char *(*logseq_journal_crypto_fn)(const char *request);

CAMLprim value logseq_journal_crypto_call(value request) {
  CAMLparam1(request);
  CAMLlocal1(result);
  char *request_copy = strdup(String_val(request));
  char *response = NULL;
  if (request_copy == NULL) {
    CAMLreturn(caml_copy_string("{\"ok\":false,\"error\":\"platform crypto unavailable\"}"));
  }
  caml_enter_blocking_section();
  logseq_journal_crypto_fn crypto =
      (logseq_journal_crypto_fn)dlsym(RTLD_DEFAULT, "logseq_journal_crypto_json");
  if (crypto != NULL) {
    response = crypto(request_copy);
  }
  caml_leave_blocking_section();
  free(request_copy);
  if (response == NULL) {
    CAMLreturn(caml_copy_string("{\"ok\":false,\"error\":\"platform crypto unavailable\"}"));
  }
  result = caml_copy_string(response);
  free(response);
  CAMLreturn(result);
}

/* Buffers owned by this stub remain stable while the OCaml runtime is released.
   The Swift callee returns malloc-owned bytes; NULL denotes failure. */
typedef unsigned char *(*logseq_journal_binary_fn)(
    int, const unsigned char *, size_t, const unsigned char *, size_t,
    const unsigned char *, size_t, size_t *);

CAMLprim value logseq_journal_crypto_binary_call(
    value encrypt, value key, value iv, value input) {
  CAMLparam4(encrypt, key, iv, input);
  CAMLlocal2(result, payload);
  const size_t limit = 8 * 1024 * 1024;
  const int sealing = Bool_val(encrypt);
  const size_t key_length = caml_string_length(key);
  const size_t iv_length = caml_string_length(iv);
  const size_t input_length = caml_string_length(input);
  unsigned char *response = NULL;
  size_t response_length = 0;
  if (key_length == 32 && iv_length == (sealing ? 0 : 12) &&
      input_length <= limit + (sealing ? 0 : 16) &&
      (sealing || input_length >= 16)) {
    unsigned char *copy = malloc(key_length + iv_length + input_length);
    if (copy != NULL) {
      memcpy(copy, String_val(key), key_length);
      memcpy(copy + key_length, String_val(iv), iv_length);
      memcpy(copy + key_length + iv_length, String_val(input), input_length);
      caml_enter_blocking_section();
      logseq_journal_binary_fn crypto = (logseq_journal_binary_fn)
          dlsym(RTLD_DEFAULT, "logseq_journal_crypto_binary");
      if (crypto != NULL) {
        response = crypto(sealing, copy, key_length, copy + key_length,
                          iv_length, copy + key_length + iv_length,
                          input_length, &response_length);
      }
      caml_leave_blocking_section();
      memset(copy, 0, key_length);
      free(copy);
    }
  }
  const size_t expected = sealing ? input_length + 28 : input_length - 16;
  if (response == NULL || response_length != expected) {
    free(response);
    payload = caml_copy_string("platform binary crypto failed");
    result = caml_alloc(1, 1); /* Error */
  } else {
    payload = caml_alloc_initialized_string(response_length, (const char *)response);
    free(response);
    result = caml_alloc(1, 0); /* Ok */
  }
  Store_field(result, 0, payload);
  CAMLreturn(result);
}

#include "transport_dns_stubs.h"
