/* crt0_stub.S — ROM-resident ISR entry for the GDB debug stub.
 *
 * Placed at MTVEC_ADDR (ROM base) by the linker. On any trap the CPU
 * jumps here. We save the FULL register set + mepc into g_regs[],
 * call gdb_stub_entry(mcause), then restore everything and mret.
 *
 * Memory layout:
 *   g_regs[0]       : x0  (always 0 — slot used as scratch during save)
 *   g_regs[1..31]   : x1..x31  (RV32I)  or  g_regs[1..15] for RV32E
 *   g_regs[32]      : pc (mepc) for RV32I; g_regs[16] for RV32E
 *
 * We use __sp_save (a 1-word scratch in .bss) to bootstrap without
 * clobbering any register before it's saved.
 */

    .section .isr, "ax"
    .global _isr_entry
    .balign 4
_isr_entry:

#if __riscv_abi_rve
    /* ============================================================ */
    /* RV32E: 16 registers (x0..x15). Frame = 17 words (68 bytes).  */
    /* ============================================================ */

    /* 1. Stash sp (x2) to scratch using zero-base addressing.
     *    __sp_save must be in the low 2 KiB of RAM (signed 12-bit). */
    sw      sp, %lo(__sp_save)(zero)

    /* 2. Load base of g_regs[] into sp. */
    lui     sp, %hi(g_regs)
    addi    sp, sp, %lo(g_regs)

    /* 3. Save x1, x3..x15 (skip x0=zero, x2=sp handled below). */
    sw      x1,   4(sp)
    sw      x3,  12(sp)
    sw      x4,  16(sp)
    sw      x5,  20(sp)
    sw      x6,  24(sp)
    sw      x7,  28(sp)
    sw      x8,  32(sp)
    sw      x9,  36(sp)
    sw      x10, 40(sp)
    sw      x11, 44(sp)
    sw      x12, 48(sp)
    sw      x13, 52(sp)
    sw      x14, 56(sp)
    sw      x15, 60(sp)

    /* 4. Recover original sp from scratch, save to g_regs[2]. */
    lw      t0, %lo(__sp_save)(zero)
    sw      t0,   8(sp)

    /* 5. Save mepc → g_regs[16] (the PC slot for RV32E). */
    csrr    t0, mepc
    sw      t0,  64(sp)

    /* 6. mcause → a0 (first argument to gdb_stub_entry). */
    csrr    a0, mcause

    /* 7. Switch to stub-private stack. */
    lui     sp, %hi(__stub_stack_top)
    addi    sp, sp, %lo(__stub_stack_top)

    /* 8. Call the RSP engine. */
    call    gdb_stub_entry

    /* ---- Restore ------------------------------------------------ */

    /* 9. Reload g_regs base. */
    lui     sp, %hi(g_regs)
    addi    sp, sp, %lo(g_regs)

    /* 10. Restore mepc (GDB may have changed it via G packet). */
    lw      t0,  64(sp)
    csrw    mepc, t0

    /* 11. Restore x1, x3..x15. */
    lw      x1,   4(sp)
    lw      x3,  12(sp)
    lw      x4,  16(sp)
    lw      x5,  20(sp)
    lw      x6,  24(sp)
    lw      x7,  28(sp)
    lw      x8,  32(sp)
    lw      x9,  36(sp)
    lw      x10, 40(sp)
    lw      x11, 44(sp)
    lw      x12, 48(sp)
    lw      x13, 52(sp)
    lw      x14, 56(sp)
    lw      x15, 60(sp)

    /* 12. Restore sp last (from g_regs[2]). */
    lw      sp,   8(sp)

    /* 13. Return from trap. */
    mret

#else
    /* ============================================================ */
    /* RV32I: 32 registers (x0..x31). Frame = 33 words (132 bytes). */
    /* ============================================================ */

    /* 1. Stash sp. */
    sw      sp, %lo(__sp_save)(zero)

    /* 2. Load g_regs base. */
    lui     sp, %hi(g_regs)
    addi    sp, sp, %lo(g_regs)

    /* 3. Save x1, x3..x31 (skip x0, x2). */
    sw      x1,    4(sp)
    sw      x3,   12(sp)
    sw      x4,   16(sp)
    sw      x5,   20(sp)
    sw      x6,   24(sp)
    sw      x7,   28(sp)
    sw      x8,   32(sp)
    sw      x9,   36(sp)
    sw      x10,  40(sp)
    sw      x11,  44(sp)
    sw      x12,  48(sp)
    sw      x13,  52(sp)
    sw      x14,  56(sp)
    sw      x15,  60(sp)
    sw      x16,  64(sp)
    sw      x17,  68(sp)
    sw      x18,  72(sp)
    sw      x19,  76(sp)
    sw      x20,  80(sp)
    sw      x21,  84(sp)
    sw      x22,  88(sp)
    sw      x23,  92(sp)
    sw      x24,  96(sp)
    sw      x25, 100(sp)
    sw      x26, 104(sp)
    sw      x27, 108(sp)
    sw      x28, 112(sp)
    sw      x29, 116(sp)
    sw      x30, 120(sp)
    sw      x31, 124(sp)

    /* 4. Recover original sp, save to g_regs[2]. */
    lw      t0, %lo(__sp_save)(zero)
    sw      t0,    8(sp)

    /* 5. Save mepc → g_regs[32]. */
    csrr    t0, mepc
    sw      t0,  128(sp)

    /* 6. mcause → a0. */
    csrr    a0, mcause

    /* 7. Stub stack. */
    lui     sp, %hi(__stub_stack_top)
    addi    sp, sp, %lo(__stub_stack_top)

    /* 8. Call RSP engine. */
    call    gdb_stub_entry

    /* ---- Restore ------------------------------------------------ */

    /* 9. Reload g_regs base. */
    lui     sp, %hi(g_regs)
    addi    sp, sp, %lo(g_regs)

    /* 10. Restore mepc. */
    lw      t0,  128(sp)
    csrw    mepc, t0

    /* 11. Restore x1, x3..x31. */
    lw      x1,    4(sp)
    lw      x3,   12(sp)
    lw      x4,   16(sp)
    lw      x5,   20(sp)
    lw      x6,   24(sp)
    lw      x7,   28(sp)
    lw      x8,   32(sp)
    lw      x9,   36(sp)
    lw      x10,  40(sp)
    lw      x11,  44(sp)
    lw      x12,  48(sp)
    lw      x13,  52(sp)
    lw      x14,  56(sp)
    lw      x15,  60(sp)
    lw      x16,  64(sp)
    lw      x17,  68(sp)
    lw      x18,  72(sp)
    lw      x19,  76(sp)
    lw      x20,  80(sp)
    lw      x21,  84(sp)
    lw      x22,  88(sp)
    lw      x23,  92(sp)
    lw      x24,  96(sp)
    lw      x25, 100(sp)
    lw      x26, 104(sp)
    lw      x27, 108(sp)
    lw      x28, 112(sp)
    lw      x29, 116(sp)
    lw      x30, 120(sp)
    lw      x31, 124(sp)

    /* 12. Restore sp last. */
    lw      sp,    8(sp)

    /* 13. mret. */
    mret

#endif

    /* ============================================================ */
    /* Scratch: __sp_save MUST be in low RAM (< 0x800) so that     */
    /* sw/lw via zero-base signed-12-bit addressing works.         */
    /* Placed in a .sp_scratch section routed to low RAM.          */
    /* ============================================================ */
    .section .sp_scratch, "aw", @nobits
    .balign 4
    .global __sp_save
__sp_save:
    .space 4

    /* ============================================================ */
    /* BSS: stub-private stack (in stub RAM near top of RAM).       */
    /* ============================================================ */
    .section .bss
    .balign 4
    .global __stub_stack
__stub_stack:
    .space 256
    .global __stub_stack_top
__stub_stack_top:
