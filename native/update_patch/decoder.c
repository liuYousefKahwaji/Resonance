#define _FILE_OFFSET_BITS 64
#include "decoder.h"
#include "xdelta3.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define seek64 _fseeki64
#else
#define seek64 fseeko
#endif

int resonance_decode(const char *source_path, const char *patch_path,
                     const char *output_path, uint64_t expected_size,
                     patch_cancelled cancelled, void *context,
                     char *error, unsigned error_size) {
  const size_t block_size = 65536;
  FILE *source_file = NULL, *patch_file = NULL, *output = NULL;
  uint8_t *source_buf = NULL, *input_buf = NULL;
  xd3_stream stream = {0}; xd3_source source = {0}; xd3_config config;
  int configured = 0, success = 0, last = 0, ret;
  uint64_t written = 0;
  const char *reason = "Patch IO failed";
  if (!expected_size || expected_size > ((uint64_t)2 << 30) ||
      strcmp(source_path, output_path) == 0 || strcmp(patch_path, output_path) == 0) {
    reason = "Invalid reconstruction paths or size"; goto done;
  }
  source_file = fopen(source_path, "rb"); patch_file = fopen(patch_path, "rb");
  if (!source_file || !patch_file) goto done;
  output = fopen(output_path, "wb"); if (!output) goto done;
  source_buf = malloc(block_size); input_buf = malloc(block_size);
  if (!source_buf || !input_buf) { reason = "Allocation failed"; goto done; }
  xd3_init_config(&config, 0); config.winsize = 8388608;
  if (xd3_config_stream(&stream, &config)) { reason = "Decoder configuration failed"; goto done; }
  configured = 1;
  source.blksize = block_size; source.curblk = source_buf;
  source.onblk = fread(source_buf, 1, block_size, source_file);
  if (ferror(source_file) || xd3_set_source(&stream, &source)) goto done;
  while (!last) {
    size_t count = fread(input_buf, 1, block_size, patch_file);
    if (ferror(patch_file)) goto done;
    last = count < block_size;
    if (last) xd3_set_flags(&stream, stream.flags | XD3_FLUSH);
    xd3_avail_input(&stream, input_buf, count);
    for (;;) {
      if (cancelled && cancelled(context)) { reason = "Reconstruction interrupted"; goto done; }
      ret = xd3_decode_input(&stream);
      if (ret == XD3_INPUT) break;
      if (ret == XD3_OUTPUT) {
        if (stream.avail_out > expected_size - written) { reason = "Reconstruction exceeds signed size"; goto done; }
        if (fwrite(stream.next_out, 1, stream.avail_out, output) != stream.avail_out) goto done;
        written += stream.avail_out; xd3_consume_output(&stream);
      } else if (ret == XD3_GETSRCBLK) {
        if (source.getblkno > INT64_MAX / block_size ||
            seek64(source_file, (int64_t)(source.getblkno * block_size), SEEK_SET)) goto done;
        source.onblk = fread(source_buf, 1, block_size, source_file);
        if (ferror(source_file)) goto done;
        source.curblkno = source.getblkno;
      } else if (ret != XD3_GOTHEADER && ret != XD3_WINSTART && ret != XD3_WINFINISH) {
        reason = stream.msg ? stream.msg : "Invalid VCDIFF patch"; goto done;
      }
    }
  }
  if (xd3_close_stream(&stream) || written != expected_size || fflush(output)) {
    reason = "Incomplete reconstruction"; goto done;
  }
  success = 1;
done:
  if (!success && error_size) snprintf(error, error_size, "%s", reason);
  if (configured) xd3_free_stream(&stream);
  free(source_buf); free(input_buf);
  if (source_file) fclose(source_file);
  if (patch_file) fclose(patch_file);
  if (output && fclose(output)) { success = 0; if (error_size) snprintf(error, error_size, "Output close failed"); }
  if (!success && output) remove(output_path);
  return success ? 0 : -1;
}
