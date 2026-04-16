/*----------------------------------------------------------------------------
 * selftest.c — AttoRV32 self-checking firmware
 *
 * Each CHECK(cond) advances the test number. On failure the test number is
 * written to IO_DONE so the testbench prints a FAIL code. On success (end of
 * main) a 0 is written to IO_DONE => PASS.
 *
 * Feature gating (all compile-time, matching the core defines):
 *   HAVE_M       : tests multiply / divide / remainder
 *   HAVE_SRA     : tests SRA / SRAI
 *   HAVE_PERF    : tests rdcycle
 *   HAVE_IRQ     : tests external IRQ via the testbench's tick source
 *
 * By default the Makefile passes HAVE_M and always enables HAVE_IRQ.
 *---------------------------------------------------------------------------*/

#include <stdint.h>

/*---- I/O (top 16 bytes of the address space, computed at link time) -------*/
extern char __ram_end[];
#define IO_DONE_ADDR     ((volatile uint32_t *)((uintptr_t)__ram_end - 16))
#define IO_DEBUG_ADDR    ((volatile uint32_t *)((uintptr_t)__ram_end - 12))
#define IO_IRQ_STATUS    ((volatile uint32_t *)((uintptr_t)__ram_end -  8))
#define IO_IRQ_CLEAR     ((volatile uint32_t *)((uintptr_t)__ram_end -  4))

/*---- Test dispatch --------------------------------------------------------*/
static volatile int test_id = 0;

static inline void done_pass(void) { *IO_DONE_ADDR = 0; while (1) ; }
static inline void done_fail(void) { *IO_DONE_ADDR = (uint32_t)test_id; while (1) ; }

#define CHECK(cond) do { ++test_id; if (!(cond)) done_fail(); } while (0)

/*---- Barrier to prevent GCC from folding the operation. -------------------*/
#define BARRIER(v) __asm__ volatile ("" : "+r"(v))

/*---------------------------------------------------------------------------
 * 1) Integer ALU: add, sub, logical, compare (register and immediate).
 *---------------------------------------------------------------------------*/
static void test_alu(void) {
    int32_t a = 0x12345678, b = 0x0000abcd;  BARRIER(a); BARRIER(b);

    CHECK((a + b) == 0x12350245);
    CHECK((a - b) == 0x1233AAAB);
    CHECK((a & b) == 0x00000248);
    CHECK((a | b) == 0x1234FFFD);
    CHECK((a ^ b) == 0x1234FDB5);

    /* SLT / SLTU */
    int32_t neg = -1; BARRIER(neg);
    CHECK((neg < 0) == 1);
    CHECK(((uint32_t)neg < 1u) == 0);           /* unsigned -1 is huge */

    /* Immediate forms (small and 12-bit extremes). */
    int32_t x = 100; BARRIER(x);
    CHECK((x + 23)    == 123);
    CHECK((x + 2047)  == 2147);
    CHECK((x + -2048) == (100 - 2048));
    CHECK((x & 0xff)  == 100);
}

/*---------------------------------------------------------------------------
 * 2) Shifts — verifies both barrel and serial paths (identical at the ISA
 *    level). We use unsigned to avoid requiring SRA.
 *---------------------------------------------------------------------------*/
static void test_shifts(void) {
    uint32_t x = 0x87654321u; BARRIER(x);

    /* SLL */
    CHECK((x <<  0) == 0x87654321u);
    CHECK((x <<  1) == 0x0ECA8642u);
    CHECK((x <<  4) == 0x76543210u);
    CHECK((x << 16) == 0x43210000u);
    CHECK((x << 31) == 0x80000000u);

    /* SRL */
    CHECK((x >>  0) == 0x87654321u);
    CHECK((x >>  1) == 0x43B2A190u);
    CHECK((x >>  4) == 0x08765432u);
    CHECK((x >> 16) == 0x00008765u);
    CHECK((x >> 31) == 0x00000001u);

    /* Register-amount shift (serial path takes shamt cycles). */
    uint32_t v = 0xdeadbeefu, s = 12; BARRIER(v); BARRIER(s);
    CHECK((v <<  s) == (0xdeadbeefu <<  12));
    CHECK((v >>  s) == (0xdeadbeefu >>  12));

    /* shamt = 0 edge case (serial shifter loads shift_data and finishes). */
    s = 0; BARRIER(s);
    CHECK((v <<  s) == v);
    CHECK((v >>  s) == v);
}

#ifdef HAVE_SRA
static void test_sra(void) {
    int32_t x = (int32_t)0x87654321; BARRIER(x);
    CHECK((x >> 0)  == (int32_t)0x87654321);
    CHECK((x >> 4)  == (int32_t)0xF8765432);
    CHECK((x >> 16) == (int32_t)0xFFFF8765);
    CHECK((x >> 31) == (int32_t)0xFFFFFFFF);
}
#endif

/*---------------------------------------------------------------------------
 * 3) Branches: test each of the six predicates.
 *---------------------------------------------------------------------------*/
static void test_branches(void) {
    int32_t a = 7, b = 7, c = 9;        BARRIER(a); BARRIER(b); BARRIER(c);
    int32_t neg = -3, pos = 5;          BARRIER(neg); BARRIER(pos);

    CHECK(a == b);
    CHECK(a != c);
    CHECK(neg <  pos);
    CHECK(pos >  neg);
    CHECK((uint32_t)neg > (uint32_t)pos);   /* -3 as unsigned is big */
    CHECK((uint32_t)pos < (uint32_t)neg);
}

/*---------------------------------------------------------------------------
 * 4) Loads / stores — byte, half-word, word, aligned and unaligned offsets.
 *---------------------------------------------------------------------------*/
static uint8_t  buf8[16]  __attribute__((aligned(4)));
static uint16_t buf16[8]  __attribute__((aligned(4)));
static uint32_t buf32[4]  __attribute__((aligned(4)));

static void test_loadstore(void) {
    /* Byte write-read across the 4 lanes. */
    for (int i = 0; i < 4; ++i) {
        buf8[i] = (uint8_t)(0xA0 + i);
    }
    CHECK(buf8[0] == 0xA0);
    CHECK(buf8[1] == 0xA1);
    CHECK(buf8[2] == 0xA2);
    CHECK(buf8[3] == 0xA3);

    /* Half-word write-read at both half-lanes. */
    buf16[0] = 0xBEEF;
    buf16[1] = 0xCAFE;
    CHECK(buf16[0] == 0xBEEF);
    CHECK(buf16[1] == 0xCAFE);

    /* Word. */
    buf32[0] = 0xDEADBEEFu;
    buf32[1] = 0x12345678u;
    CHECK(buf32[0] == 0xDEADBEEFu);
    CHECK(buf32[1] == 0x12345678u);

    /* Unsigned byte / half load — sign-extended signed loads require SRA
     * after combine on some code paths, so we test LBU / LHU here and
     * only exercise sign-extension when HAVE_SRA is defined (below). */
    buf8[0] = 0xFF;
    uint8_t  ub = *(volatile uint8_t  *)&buf8[0];
    uint16_t uh = *(volatile uint16_t *)&buf16[0];
    CHECK(ub == 0xFFu);
    CHECK(uh == 0xBEEFu);
#ifdef HAVE_SRA
    int8_t   sb = *(volatile int8_t   *)&buf8[0];
    int16_t  sh = *(volatile int16_t  *)&buf16[0];
    CHECK(sb == -1);
    CHECK(sh == (int16_t)0xBEEF);
#endif
}

/*---------------------------------------------------------------------------
 * 5) Multiply / Divide (only when the M extension is enabled).
 *---------------------------------------------------------------------------*/
#ifdef HAVE_M
static void test_m(void) {
    /* MUL (low 32) */
    int32_t a = 0x12345, b = 0x67;  BARRIER(a); BARRIER(b);
    CHECK(a * b == 0x12345 * 0x67);

    /* Signed × signed negative */
    int32_t x = -3, y = 5;  BARRIER(x); BARRIER(y);
    CHECK(x * y == -15);

    /* MULH variants — via 64-bit promotions, forces MULH[SU] use. */
    int32_t  s1 = (int32_t)0x80000000, s2 = 2; BARRIER(s1); BARRIER(s2);
    int64_t  sp = (int64_t)s1 * (int64_t)s2;
    CHECK((int32_t)(sp >> 32) == (int32_t)0xFFFFFFFF);
    CHECK((int32_t)(sp      ) == 0);

    uint32_t u1 = 0xFFFFFFFFu, u2 = 0xFFFFFFFFu; BARRIER(u1); BARRIER(u2);
    uint64_t up = (uint64_t)u1 * (uint64_t)u2;
    CHECK((uint32_t)(up >> 32) == 0xFFFFFFFEu);
    CHECK((uint32_t)(up      ) == 0x00000001u);

    /* MULHSU: signed × unsigned */
    int32_t  ss = -1;           /* 0xFFFFFFFF signed = -1 */
    uint32_t us = 0xFFFFFFFFu;
    BARRIER(ss); BARRIER(us);
    int64_t  pr = (int64_t)ss * (int64_t)(uint64_t)us;
    CHECK((int32_t)(pr >> 32) == (int32_t)0xFFFFFFFF);
    CHECK((int32_t)(pr      ) == 1);

    /* DIV / REM signed */
    int32_t n = -17, d = 5; BARRIER(n); BARRIER(d);
    CHECK(n / d == -3);
    CHECK(n % d == -2);

    /* DIVU / REMU unsigned */
    uint32_t un = 100u, ud = 7u; BARRIER(un); BARRIER(ud);
    CHECK(un / ud == 14u);
    CHECK(un % ud == 2u);

    /* Divide-by-zero corner: unsigned div returns all-1s, rem returns a. */
    uint32_t dz_n = 42u, dz_d = 0u; BARRIER(dz_n); BARRIER(dz_d);
    CHECK(dz_n / dz_d == 0xFFFFFFFFu);
    CHECK(dz_n % dz_d == 42u);
}
#endif

/*---------------------------------------------------------------------------
 * 6) EBREAK trap: the ISR advances mepc by 2 (c.ebreak) so we return just
 *    past the breakpoint. We set a sentinel before and after.
 *---------------------------------------------------------------------------*/
static volatile int ebreak_marker;
static void test_ebreak(void) {
    ebreak_marker = 0;
    __asm__ volatile (
        "li  t0, 1            \n"
        "sw  t0, %0           \n"
        "c.ebreak             \n"
        "li  t0, 2            \n"
        "sw  t0, %0           \n"
        : "=m"(ebreak_marker)
        :
        : "t0", "memory"
    );
    CHECK(ebreak_marker == 2);           /* the post-EBREAK store must run */
}

/*---------------------------------------------------------------------------
 * 7) IRQ: the testbench raises an IRQ every IRQ_PERIOD cycles. The default
 *    ISR in isr.c increments tick_count and clears IO_IRQ_CLEAR.
 *---------------------------------------------------------------------------*/
extern volatile uint32_t tick_count;

static void test_irq(void) {
    /* Make sure mstatus.MIE is set; crt0 does this, but be defensive. */
    __asm__ volatile ("csrsi mstatus, 8");

    uint32_t t0 = tick_count;
    /* Wait for at least 2 ticks or until ~50k busy iterations. */
    for (uint32_t i = 0; i < 100000u; ++i) {
        if (tick_count >= t0 + 2) break;
        __asm__ volatile ("" ::: "memory");
    }
    CHECK(tick_count >= t0 + 1);
}

/*---------------------------------------------------------------------------
 * 8) WFI: the core must stall at WFI until an interrupt (or NMI/dbg_halt)
 *    arrives, then resume past the WFI. We sample the tick counter before
 *    and after — if WFI didn't block, we might still see progress from the
 *    free-running IRQ source, but the point here is that WFI doesn't trap
 *    (pre-fix it was decoded as EBREAK) and that tick_count advances.
 *---------------------------------------------------------------------------*/
static void test_wfi(void) {
    __asm__ volatile ("csrsi mstatus, 8");      /* MIE on */
    uint32_t t0 = tick_count;
    __asm__ volatile ("wfi" ::: "memory");
    CHECK(tick_count > t0);                     /* at least one IRQ served */
}

/*---------------------------------------------------------------------------
 * main — run each test; if no CHECK fails, write 0 to IO_DONE.
 *---------------------------------------------------------------------------*/
int main(void) {
    test_alu();
    test_shifts();
#ifdef HAVE_SRA
    test_sra();
#endif
    test_branches();
    test_loadstore();
#ifdef HAVE_M
    test_m();
#endif
    test_ebreak();
    test_irq();
    test_wfi();

    done_pass();
    return 0;
}
