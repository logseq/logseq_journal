#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <zlib.h>
#include <dlfcn.h>

#include <caml/mlvalues.h>
#include <caml/memory.h>

/* zlib is resolved at runtime (same pattern as platform_crypto_stubs.c) so
   the stubs archive carries no link-time -lz dependency on platforms without
   a linker_option pragma. */
typedef int (*zlib_inflate_init2_fn)(z_streamp, int, const char *, int);
typedef int (*zlib_inflate_fn)(z_streamp, int);
typedef int (*zlib_inflate_end_fn)(z_streamp);

static zlib_inflate_init2_fn zlib_inflate_init2;
static zlib_inflate_fn zlib_inflate;
static zlib_inflate_end_fn zlib_inflate_end;

static int zlib_resolve(void) {
  static int resolved = -1;
  if (resolved < 0) {
#if defined(__APPLE__)
    void *handle = dlopen("libz.dylib", RTLD_LAZY);
#else
    void *handle = dlopen("libz.so.1", RTLD_LAZY);
#endif
    if (handle != NULL) {
      zlib_inflate_init2 =
          (zlib_inflate_init2_fn)dlsym(handle, "inflateInit2_");
      zlib_inflate = (zlib_inflate_fn)dlsym(handle, "inflate");
      zlib_inflate_end = (zlib_inflate_end_fn)dlsym(handle, "inflateEnd");
    }
    resolved =
        (zlib_inflate_init2 != NULL && zlib_inflate != NULL &&
         zlib_inflate_end != NULL)
            ? 1
            : 0;
  }
  return resolved;
}

CAMLprim value logseq_journal_gzip_decompress(
    value source_value,
    value destination_value,
    value maximum_bytes_value) {
  CAMLparam3(source_value, destination_value, maximum_bytes_value);
  const char *source = String_val(source_value);
  const char *destination = String_val(destination_value);
  intnat maximum_bytes = Long_val(maximum_bytes_value);
  if (maximum_bytes <= 0) CAMLreturn(Val_int(5));
  if (!zlib_resolve()) CAMLreturn(Val_int(3));
  FILE *input = fopen(source, "rb");
  if (input == NULL) CAMLreturn(Val_int(1));

  int output_fd = open(destination, O_WRONLY | O_CREAT | O_EXCL, 0600);
  FILE *output = output_fd < 0 ? NULL : fdopen(output_fd, "wb");
  if (output == NULL) {
    if (output_fd >= 0) close(output_fd);
    fclose(input);
    CAMLreturn(Val_int(2));
  }

  z_stream stream;
  memset(&stream, 0, sizeof(stream));
  int status = 0;
  if (zlib_inflate_init2(
          &stream, 15 + 16, ZLIB_VERSION, (int)sizeof(z_stream)) != Z_OK) {
    status = 3;
  } else {
    unsigned char input_buffer[16384];
    unsigned char output_buffer[16384];
    intnat produced_total = 0;
    int finished = 0;
    while (!finished && status == 0) {
      stream.avail_in = (uInt)fread(input_buffer, 1, sizeof(input_buffer), input);
      if (ferror(input)) {
        status = 3;
        break;
      }
      if (stream.avail_in == 0) {
        status = 3;
        break;
      }
      stream.next_in = input_buffer;
      while (stream.avail_in > 0 && status == 0) {
        stream.avail_out = sizeof(output_buffer);
        stream.next_out = output_buffer;
        int result = zlib_inflate(&stream, Z_NO_FLUSH);
        if (result != Z_OK && result != Z_STREAM_END) {
          status = 3;
          break;
        }
        size_t produced = sizeof(output_buffer) - stream.avail_out;
        if ((intnat)produced > maximum_bytes - produced_total) {
          status = 5;
          break;
        }
        if (produced > 0 && fwrite(output_buffer, 1, produced, output) != produced) {
          status = 4;
          break;
        }
        produced_total += (intnat)produced;
        if (result == Z_STREAM_END) {
          finished = 1;
          break;
        }
      }
    }
    zlib_inflate_end(&stream);
  }
  if (fclose(input) != 0 && status == 0) status = 3;
  if (fclose(output) != 0 && status == 0) status = 4;
  if (status != 0) remove(destination);
  CAMLreturn(Val_int(status));
}
