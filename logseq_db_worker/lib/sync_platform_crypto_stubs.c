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
