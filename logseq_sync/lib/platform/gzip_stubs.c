#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <zlib.h>

#if defined(__APPLE__)
__asm__(".linker_option \"-lz\"");
#endif

#include <caml/mlvalues.h>
#include <caml/memory.h>

CAMLprim value logseq_journal_gzip_decompress(
    value source_value,
    value destination_value,
    value maximum_bytes_value) {
  CAMLparam3(source_value, destination_value, maximum_bytes_value);
  const char *source = String_val(source_value);
  const char *destination = String_val(destination_value);
  intnat maximum_bytes = Long_val(maximum_bytes_value);
  if (maximum_bytes <= 0) CAMLreturn(Val_int(5));
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
  if (inflateInit2(&stream, 15 + 16) != Z_OK) {
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
        int result = inflate(&stream, Z_NO_FLUSH);
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
    inflateEnd(&stream);
  }
  if (fclose(input) != 0 && status == 0) status = 3;
  if (fclose(output) != 0 && status == 0) status = 4;
  if (status != 0) remove(destination);
  CAMLreturn(Val_int(status));
}
