// One demo source for every toolchain in //tools. On the bare-metal
// targets (linked with newlib and -specs=nosys.specs against the default
// linker script), "console" output goes to the memory-mapped UART
// transmit register of QEMU's virt machine (16550 at 0x10000000). The
// hosted builds (hello-darwin, hello-w64) run on a real OS, where that
// address is unmapped — they print through stdio instead.

#include <stdint.h>
#include <stdio.h>

#include "compute.h"

#if defined(__APPLE__) || defined(_WIN32)

static void uart_puts(const char *s) { fputs(s, stdout); }

#else

#define UART0_TX (*(volatile uint8_t *)0x10000000u)

static void uart_puts(const char *s) {
  while (*s) {
    UART0_TX = (uint8_t)*s++;
  }
}

#endif

int main(void) {
  char line[64];
  for (uint32_t i = 0; i < 16; ++i) {
    snprintf(line, sizeof line, "fib(%lu) = %lu\n", (unsigned long)i,
             (unsigned long)fibonacci(i));
    uart_puts(line);
  }
  uart_puts("hello from riscv-none-elf-gcc built from source by bazel\n");
  return 0;
}
