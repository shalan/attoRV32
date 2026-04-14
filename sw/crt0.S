/* crt0.S — AttoRV32 startup
 *
 * Memory layout (ADDR_WIDTH = N gives 2^N bytes):
 *   0x0000 : reset vector (small trampoline to _start)
 *   0x0010 : interrupt vector (MTVEC_ADDR — hardcoded in hardware)
 *   ...    : _start, .text, .rodata, .data, .bss, stack (top of RAM)
 *
 * The hardware jumps to 0x00 on reset and to 0x10 on interrupt.
 * 0x00..0x0F must contain a branch to _start (real startup code).
 * 0x10..     begins the ISR entry.
 */

    .section .reset, "ax"
    .global _reset
_reset:
    c.j     _start              /* 2 bytes; .reset is padded to 0x10 by linker */

/*------------------------------------------------------------------*/
/* Interrupt entry point — placed at 0x10 by the linker.            */
/* Saves caller-saved regs, calls isr_handler(), restores, mret.    */
/*------------------------------------------------------------------*/

    .section .isr, "ax"
    .global _isr_entry
_isr_entry:
#if __riscv_abi_rve
    /* RV32E: only x0..x15 exist. Save ra, t0..t2, a0..a5 (11 regs). */
    addi    sp, sp, -48
    sw      ra,  0(sp)
    sw      t0,  4(sp)
    sw      t1,  8(sp)
    sw      t2, 12(sp)
    sw      a0, 16(sp)
    sw      a1, 20(sp)
    sw      a2, 24(sp)
    sw      a3, 28(sp)
    sw      a4, 32(sp)
    sw      a5, 36(sp)

    /* Read mcause: bit 31 = 1 -> IRQ, 0 -> env-trap (EBREAK/ECALL). */
    csrr    a0, mcause
    mv      a1, sp                 /* pass saved-regs pointer to handlers */
    bgez    a0, 10f                /* if bit31 == 0, env-trap */
    call    irq_handler
    j       11f
10: call    ebreak_handler
11:

    lw      ra,  0(sp)
    lw      t0,  4(sp)
    lw      t1,  8(sp)
    lw      t2, 12(sp)
    lw      a0, 16(sp)
    lw      a1, 20(sp)
    lw      a2, 24(sp)
    lw      a3, 28(sp)
    lw      a4, 32(sp)
    lw      a5, 36(sp)
    addi    sp, sp, 48
#else
    /* RV32I: save all caller-saved regs. */
    addi    sp, sp, -64
    sw      ra,  0(sp)
    sw      t0,  4(sp)
    sw      t1,  8(sp)
    sw      t2, 12(sp)
    sw      t3, 16(sp)
    sw      t4, 20(sp)
    sw      t5, 24(sp)
    sw      t6, 28(sp)
    sw      a0, 32(sp)
    sw      a1, 36(sp)
    sw      a2, 40(sp)
    sw      a3, 44(sp)
    sw      a4, 48(sp)
    sw      a5, 52(sp)
    sw      a6, 56(sp)
    sw      a7, 60(sp)

    /* Dispatch on mcause: bit31=1 -> irq_handler; bit31=0 -> ebreak_handler. */
    csrr    a0, mcause
    mv      a1, sp
    bgez    a0, 10f
    call    irq_handler
    j       11f
10: call    ebreak_handler
11:

    lw      ra,  0(sp)
    lw      t0,  4(sp)
    lw      t1,  8(sp)
    lw      t2, 12(sp)
    lw      t3, 16(sp)
    lw      t4, 20(sp)
    lw      t5, 24(sp)
    lw      t6, 28(sp)
    lw      a0, 32(sp)
    lw      a1, 36(sp)
    lw      a2, 40(sp)
    lw      a3, 44(sp)
    lw      a4, 48(sp)
    lw      a5, 52(sp)
    lw      a6, 56(sp)
    lw      a7, 60(sp)
    addi    sp, sp, 64
#endif
    mret

/*------------------------------------------------------------------*/
/* Real startup: set up sp, clear .bss, enable interrupts, main.    */
/*------------------------------------------------------------------*/

    .section .text.init, "ax"
    .global _start
_start:
    /* Set stack pointer to top of RAM */
    la      sp, __stack_top

    /* Clear .bss */
    la      t0, __bss_start
    la      t1, __bss_end
1:  beq     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    /* Enable interrupts: set mstatus.MIE (bit 3). */
    li      t0, 0x8
    csrs    mstatus, t0

    /* Call main(); if it returns, spin. */
    call    main
3:  j       3b
