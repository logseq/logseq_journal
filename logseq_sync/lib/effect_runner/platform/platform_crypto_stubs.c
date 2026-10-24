#ifdef __linux__
#  define _GNU_SOURCE
#endif

#include <stdint.h>
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
    CAMLreturn(caml_copy_string("{\"ok\":false,\"error\":\"cryptoAllocationFailed\"}"));
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
    CAMLreturn(caml_copy_string(crypto == NULL
        ? "{\"ok\":false,\"error\":\"cryptoNativeUnavailable\"}"
        : "{\"ok\":false,\"error\":\"cryptoNativeResponseUnavailable\"}"));
  }
  result = caml_copy_string(response);
  free(response);
  CAMLreturn(result);
}

/* Buffers owned by this stub remain stable while the OCaml runtime is released.
   The Swift callee returns malloc-owned bytes; NULL denotes failure. */
typedef unsigned char *(*logseq_journal_binary_fn)(
    int, const unsigned char *, size_t, const unsigned char *, size_t,
    const unsigned char *, size_t, intptr_t *);

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
  intptr_t response_length = 0;
  const char *failure = "platform binary crypto invalid request";
  if (key_length == 32 && iv_length == (sealing ? 0 : 12) &&
      input_length <= limit + (sealing ? 0 : 16) &&
      (sealing || input_length >= 16)) {
    unsigned char *copy = malloc(key_length + iv_length + input_length);
    failure = "platform binary crypto allocation failed";
    if (copy != NULL) {
      memcpy(copy, String_val(key), key_length);
      memcpy(copy + key_length, String_val(iv), iv_length);
      memcpy(copy + key_length + iv_length, String_val(input), input_length);
      caml_enter_blocking_section();
      logseq_journal_binary_fn crypto = (logseq_journal_binary_fn)
          dlsym(RTLD_DEFAULT, "logseq_journal_crypto_binary");
      failure = "platform binary crypto unavailable";
      if (crypto != NULL) {
        response = crypto(sealing, copy, key_length, copy + key_length,
                          iv_length, copy + key_length + iv_length,
                          input_length, &response_length);
        failure = "platform binary crypto operation failed";
        if (response == NULL) {
          switch (response_length) {
          case -1: failure = "platform binary crypto invalid request"; break;
          case -2: failure = "platform binary crypto authentication failed"; break;
          case -3: failure = "platform binary crypto allocation failed"; break;
          default: break; /* Includes older native implementations returning zero. */
          }
        }
      }
      caml_leave_blocking_section();
      memset(copy, 0, key_length);
      free(copy);
    }
  }
  /* Check signed sentinels before converting lengths or touching native bytes. */
  if (response == NULL) {
    payload = caml_copy_string(failure);
    result = caml_alloc(1, 1); /* Error */
  } else if (response_length < 0 ||
             (size_t)response_length != (sealing ? input_length + 28 : input_length - 16)) {
    free(response);
    payload = caml_copy_string("platform binary crypto invalid response");
    result = caml_alloc(1, 1);
  } else {
    payload = caml_alloc_initialized_string((size_t)response_length, (const char *)response);
    free(response);
    result = caml_alloc(1, 0); /* Ok */
  }
  Store_field(result, 0, payload);
  CAMLreturn(result);
}

#include "transport_dns_stubs.h"

/* Restore a retired directory without overwriting a concurrently created copy. */
#include <errno.h>
#include <stdio.h>
#include <fcntl.h>
#ifdef __linux__
#include <unistd.h>
#include <sys/syscall.h>
#endif
CAMLprim value logseq_journal_rename_exclusive(value source, value target) {
  CAMLparam2(source, target);
  int rc;
#ifdef __APPLE__
  rc = renameatx_np(AT_FDCWD, String_val(source), AT_FDCWD, String_val(target), RENAME_EXCL);
#elif defined(__linux__) && defined(SYS_renameat2)
  rc = syscall(SYS_renameat2, AT_FDCWD, String_val(source), AT_FDCWD, String_val(target), 1);
#else
  errno = ENOTSUP;
  rc = -1;
#endif
  CAMLreturn(Val_int(rc == 0 ? 0 : errno));
}
