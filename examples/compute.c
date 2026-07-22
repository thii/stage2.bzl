#include "compute.h"

uint32_t fibonacci(uint32_t n) {
  uint32_t a = 0;
  uint32_t b = 1;
  while (n--) {
    uint32_t next = a + b;
    a = b;
    b = next;
  }
  return a;
}
