/* dbg_test.c — minimal counter loop for debug testbench.
 *
 * Increments a counter at address 0x8 in an infinite loop.
 * The debug testbench halts the core via UART break, then
 * verifies the counter was incrementing and resumes.
 */

volatile unsigned int *const COUNTER = (volatile unsigned int *)0x8;

void _start(void) __attribute__((section(".text.start"), naked));
void _start(void) {
    /* Set up a minimal stack. */
    __asm__ volatile (
        "lui sp, %%hi(__stack_top)\n\t"
        "addi sp, sp, %%lo(__stack_top)\n\t"
        ::: "memory"
    );

    *COUNTER = 0;

    for (;;) {
        *COUNTER = *COUNTER + 1;
    }
}
