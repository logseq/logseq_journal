/* Cancellable Apple DNS-SD queries. All callbacks run synchronously from process;
   neither OCaml callbacks nor background resolver threads retain this owner. */
#include <caml/custom.h>
#include <caml/fail.h>
#ifdef __APPLE__
#include <dns_sd.h>
#include <netinet/in.h>

struct logseq_dns_query {
  DNSServiceRef service;
  int done;
  int error;
  int count;
  unsigned char lengths[8];
  unsigned char addresses[8][16];
};

static void logseq_dns_release(value handle) {
  struct logseq_dns_query *query = *(struct logseq_dns_query **)Data_custom_val(handle);
  if (query != NULL) {
    if (query->service != NULL) DNSServiceRefDeallocate(query->service);
    free(query);
    *(struct logseq_dns_query **)Data_custom_val(handle) = NULL;
  }
}

static struct custom_operations logseq_dns_operations = {
  "logseq.transport.dns", logseq_dns_release, custom_compare_default,
  custom_hash_default, custom_serialize_default, custom_deserialize_default,
  custom_compare_ext_default, custom_fixed_length_default
};

static struct logseq_dns_query *logseq_dns_get(value handle) {
  struct logseq_dns_query *query = *(struct logseq_dns_query **)Data_custom_val(handle);
  if (query == NULL) caml_invalid_argument("closed DNS query");
  return query;
}

static void logseq_dns_reply(DNSServiceRef service, DNSServiceFlags flags,
    uint32_t interface_index, DNSServiceErrorType error, const char *hostname,
    const struct sockaddr *address, uint32_t ttl, void *context) {
  (void)service; (void)interface_index; (void)hostname; (void)ttl;
  struct logseq_dns_query *query = context;
  if (error != kDNSServiceErr_NoError) {
    query->error = error == kDNSServiceErr_NoSuchRecord ? 0 : error;
    query->done = 1;
    return;
  }
  if ((flags & kDNSServiceFlagsAdd) && query->count < 8) {
    const void *bytes = NULL;
    int length = 0;
    if (address->sa_family == AF_INET) {
      bytes = &((const struct sockaddr_in *)address)->sin_addr; length = 4;
    } else if (address->sa_family == AF_INET6) {
      const struct sockaddr_in6 *ipv6 = (const struct sockaddr_in6 *)address;
      /* Eio's TCP address has no interface scope field. Do not erase a required
         link-local scope and accidentally connect through another interface. */
      if (ipv6->sin6_scope_id == 0) { bytes = &ipv6->sin6_addr; length = 16; }
    }
    if (bytes != NULL) {
      query->lengths[query->count] = length;
      memcpy(query->addresses[query->count++], bytes, length);
    }
  }
  if (!(flags & kDNSServiceFlagsMoreComing)) query->done = 1;
}

CAMLprim value logseq_transport_dns_start(value hostname, value ipv6) {
  CAMLparam2(hostname, ipv6);
  CAMLlocal1(handle);
  handle = caml_alloc_custom(&logseq_dns_operations, sizeof(void *), 0, 1);
  *(struct logseq_dns_query **)Data_custom_val(handle) = NULL;
  struct logseq_dns_query *query = calloc(1, sizeof(*query));
  if (query == NULL) caml_raise_out_of_memory();
  *(struct logseq_dns_query **)Data_custom_val(handle) = query;
  DNSServiceErrorType error = DNSServiceGetAddrInfo(&query->service, 0, 0,
      Bool_val(ipv6) ? kDNSServiceProtocol_IPv6 : kDNSServiceProtocol_IPv4,
      String_val(hostname), logseq_dns_reply, query);
  if (error != kDNSServiceErr_NoError) {
    logseq_dns_release(handle);
    caml_failwith("DNS query setup failed");
  }
  CAMLreturn(handle);
}

CAMLprim value logseq_transport_dns_fd(value handle) {
  CAMLparam1(handle);
  int fd = DNSServiceRefSockFD(logseq_dns_get(handle)->service);
  if (fd < 0) caml_failwith("DNS query has no descriptor");
  CAMLreturn(Val_int(fd));
}

CAMLprim value logseq_transport_dns_process(value handle) {
  CAMLparam1(handle);
  struct logseq_dns_query *query = logseq_dns_get(handle);
  if (DNSServiceProcessResult(query->service) != kDNSServiceErr_NoError)
    caml_failwith("DNS query processing failed");
  if (query->error) caml_failwith("DNS query failed");
  CAMLreturn(Val_bool(query->done));
}

CAMLprim value logseq_transport_dns_results(value handle) {
  CAMLparam1(handle);
  CAMLlocal3(list, cell, address);
  struct logseq_dns_query *query = logseq_dns_get(handle);
  list = Val_emptylist;
  for (int i = query->count - 1; i >= 0; --i) {
    address = caml_alloc_initialized_string(query->lengths[i], (char *)query->addresses[i]);
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, address); Store_field(cell, 1, list); list = cell;
  }
  CAMLreturn(list);
}

CAMLprim value logseq_transport_dns_close(value handle) {
  CAMLparam1(handle);
  logseq_dns_release(handle);
  CAMLreturn(Val_unit);
}
#else
/* The application targets Apple platforms; unsupported platforms fail explicitly. */
CAMLprim value logseq_transport_dns_start(value host, value ipv6) {
  (void)host; (void)ipv6; caml_failwith("Apple DNS-SD is required");
}
CAMLprim value logseq_transport_dns_fd(value handle) {
  (void)handle; caml_failwith("Apple DNS-SD is required");
}
CAMLprim value logseq_transport_dns_process(value handle) {
  (void)handle; caml_failwith("Apple DNS-SD is required");
}
CAMLprim value logseq_transport_dns_results(value handle) {
  (void)handle; caml_failwith("Apple DNS-SD is required");
}
CAMLprim value logseq_transport_dns_close(value handle) {
  (void)handle; return Val_unit;
}
#endif
