/* main.c — Minimal example for AttoRV32.
 *
 * Assumes a memory-mapped I/O register for a simple GPIO or UART at a
 * fixed address. Replace IO_ADDR with your SoC's real address.
 *
 * NOTE: All right-shifts here use unsigned operands so that GCC never
 * emits SRA / SRAI (we built the core without NRV_SRA).
 */

#include <stdint.h>

/* Example MMIO — adjust to your platform. Placed near top of RAM. */
#define IO_LED    (*(volatile uint32_t *)0x000000F0)
#define IO_TICK   (*(volatile uint32_t *)0x000000F4)

static void delay(uint32_t n) {
    while (n--) __asm__ volatile ("nop");
}

int main(void) {
    uint32_t pattern = 0x1u;
    for (;;) {
        IO_LED = pattern;
        /* rotate-left by 1, all unsigned — no SRA generated */
        pattern = (pattern << 1) | (pattern >> 31);
        delay(1000);
    }
    return 0;
}
