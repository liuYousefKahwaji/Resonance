#pragma once
#include <stdint.h>
typedef int (*patch_cancelled)(void *context);
int resonance_decode(const char *source_path, const char *patch_path,
                     const char *output_path, uint64_t expected_size,
                     patch_cancelled cancelled, void *context,
                     char *error, unsigned error_size);
