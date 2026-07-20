// Emits IREE runtime constants as JSON, read from IREE's own headers.
// Downstream consumers must never hand-transcribe these: the walking skeleton
// hard-coded FLOAT_32 as 0x00000120 when it is 0x21000020, and the error stayed
// invisible until an output type was mapped back.
#include <stdio.h>

#include "iree/base/api.h"
#include "iree/hal/api.h"

static int emit_element_types(const char* path) {
  FILE* f = fopen(path, "w");
  if (!f) return 1;
  fprintf(f, "{\n");
  int first = 1;
#define E(sym)                                                            \
  do {                                                                    \
    fprintf(f, "%s  \"%s\": %llu", first ? "" : ",\n", #sym,              \
            (unsigned long long)IREE_HAL_ELEMENT_TYPE_##sym);             \
    first = 0;                                                            \
  } while (0)
  E(NONE); E(OPAQUE_8); E(OPAQUE_16); E(OPAQUE_32); E(OPAQUE_64);
  E(BOOL_8);
  E(INT_8); E(INT_16); E(INT_32); E(INT_64);
  E(SINT_8); E(SINT_16); E(SINT_32); E(SINT_64);
  E(UINT_8); E(UINT_16); E(UINT_32); E(UINT_64);
  E(FLOAT_16); E(FLOAT_32); E(FLOAT_64);
  E(BFLOAT_16);
  E(COMPLEX_FLOAT_64); E(COMPLEX_FLOAT_128);
#undef E
  fprintf(f, "\n}\n");
  fclose(f);
  return 0;
}

static int emit_status_codes(const char* path) {
  FILE* f = fopen(path, "w");
  if (!f) return 1;
  fprintf(f, "{\n");
  int first = 1;
#define E(sym)                                                            \
  do {                                                                    \
    fprintf(f, "%s  \"%s\": %llu", first ? "" : ",\n", #sym,              \
            (unsigned long long)IREE_STATUS_##sym);                       \
    first = 0;                                                            \
  } while (0)
  E(OK); E(CANCELLED); E(UNKNOWN); E(INVALID_ARGUMENT); E(DEADLINE_EXCEEDED);
  E(NOT_FOUND); E(ALREADY_EXISTS); E(PERMISSION_DENIED); E(RESOURCE_EXHAUSTED);
  E(FAILED_PRECONDITION); E(ABORTED); E(OUT_OF_RANGE); E(UNIMPLEMENTED);
  E(INTERNAL); E(UNAVAILABLE); E(DATA_LOSS); E(UNAUTHENTICATED);
  E(DEFERRED); E(INCOMPATIBLE);
#undef E
  fprintf(f, "\n}\n");
  fclose(f);
  return 0;
}

int main(int argc, char** argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: emit_constants <element_types.json> <status_codes.json>\n");
    return 2;
  }
  if (emit_element_types(argv[1])) return 1;
  if (emit_status_codes(argv[2])) return 1;
  return 0;
}
