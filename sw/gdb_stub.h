/* gdb_stub.h — minimum-viable GDB Remote Serial Protocol stub.
 *
 * Hooked from ebreak_handler() and irq_handler() (for Ctrl-C). The stub
 * talks RSP over a polled UART supplied by the platform:
 *
 *     int  gdb_uart_getc(void);    // blocking, returns 0..255
 *     void gdb_uart_putc(int c);   // blocking
 *
 * Full register frame as GDB expects for RV32:
 *   x0..x31 (32 words) + pc (1 word) = 33 words = 132 bytes.
 * For RV32E use NGDB_REGS = 17 (x0..x15 + pc).
 */
#ifndef GDB_STUB_H
#define GDB_STUB_H

#include <stdint.h>

#ifdef __riscv_abi_rve
#  define NGDB_REGS 17
#else
#  define NGDB_REGS 33
#endif

/* Frame populated by the ISR entry when GDB_STUB is defined. Layout
 * must exactly mirror GDB's g-packet register order: x0 first, then
 * x1..x(N-1), then pc. x0 is always written as 0. */
extern uint32_t g_regs[NGDB_REGS];

/* Called by ebreak_handler() and by irq_handler() on Ctrl-C. */
void gdb_stub_entry(uint32_t cause);

/* Platform-supplied byte I/O. */
int  gdb_uart_getc(void);
void gdb_uart_putc(int c);

#endif
