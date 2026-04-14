/* isr.c — trap handlers called from _isr_entry in crt0.S.
 *
 * The core now distinguishes two trap causes:
 *   - IRQ    : mcause = 0x8000000B  (external interrupt)  -> irq_handler
 *   - EBREAK : mcause = 0x00000003  (breakpoint / env)    -> ebreak_handler
 *
 * Both receive:
 *   a0 = mcause value (already read by the wrapper)
 *   a1 = pointer to the saved register frame on the stack
 */

#include <stdint.h>

/* I/O sits at the top of RAM, linker-provided: __ram_end is one past the
 * last byte, so the 4 IO regs are at __ram_end - 16, -12, -8, -4. */
extern char __ram_end[];
#define IO_IRQ_STATUS  (*(volatile uint32_t *)((uintptr_t)__ram_end -  8))
#define IO_IRQ_CLEAR   (*(volatile uint32_t *)((uintptr_t)__ram_end -  4))

volatile uint32_t tick_count;

/* ------------------------------------------------------------------ */
/* External interrupt                                                 */
/* ------------------------------------------------------------------ */
void irq_handler(uint32_t cause, void *frame) {
    (void)cause; (void)frame;
    uint32_t status = IO_IRQ_STATUS;
    if (status & 0x1u) {
        tick_count++;
        IO_IRQ_CLEAR = 0x1u;
    }
}

/* ------------------------------------------------------------------ */
/* EBREAK / ECALL handler                                             */
/*                                                                    */
/* By default we advance mepc past the trapping instruction so MRET   */
/* resumes after it (otherwise we'd loop forever on the same EBREAK). */
/* A GDB stub would replace this with its RSP state machine.          */
/* ------------------------------------------------------------------ */
static inline uint32_t read_mepc(void) {
    uint32_t v; __asm__ volatile ("csrr %0, mepc" : "=r"(v));
    return v;
}
static inline void write_mepc(uint32_t v) {
    __asm__ volatile ("csrw mepc, %0" :: "r"(v));
}

void ebreak_handler(uint32_t cause, void *frame) {
    (void)cause; (void)frame;

    /* Decide instruction length: c.ebreak is 16 bits, ebreak is 32. */
    uint32_t epc = read_mepc();
    uint16_t hw  = *(volatile uint16_t *)(uintptr_t)epc;
    uint32_t len = ((hw & 0x3u) == 0x3u) ? 4u : 2u;
    write_mepc(epc + len);

    /* Hook point for the GDB stub. With -DGDB_STUB the debugger is
     * invoked on every EBREAK (user-placed or stub-planted). It reads
     * and writes the saved register frame via g_regs[] populated by
     * the extended ISR prologue in crt0.S. */
#ifdef GDB_STUB
    extern void gdb_stub_entry(uint32_t cause);
    /* Skip the default mepc+=len advance so the stub can decide: for a
     * single-step-return it wants mepc unchanged; for a "continue past
     * this ebreak" it will advance mepc itself. */
    write_mepc(epc);
    gdb_stub_entry(cause);
#endif
}
