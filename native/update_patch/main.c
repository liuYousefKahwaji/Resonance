#include "decoder.h"
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  if (argc != 5) { fprintf(stderr, "usage: resonance-patch source patch output expected-size\n"); return 2; }
  char error[192];
  if (resonance_decode(argv[1], argv[2], argv[3], strtoull(argv[4], NULL, 10), NULL, NULL, error, sizeof(error))) {
    fprintf(stderr, "%s\n", error); return 1;
  }
  return 0;
}
