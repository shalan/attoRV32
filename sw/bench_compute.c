/*----------------------------------------------------------------------------
 * bench_compute.c — Matrix-multiply + TEA-encrypt benchmark for AttoRV32.
 *
 * Workloads:
 *   1) 4×4 × 4×4 matrix multiplication (uint32_t), 10 iterations.
 *   2) TEA block cipher, 32 Feistel rounds × 16 blocks.
 *
 * Reads mcycle / minstret before and after each workload, prints results
 * via IO_DEBUG (one character at a time), then writes IO_DONE = 0 (PASS).
 *
 * Build:  make CROSS=... BENCH_COMPUTE=1 ADDR_WIDTH=12 RV32E=1 HAVE_M=1
 *---------------------------------------------------------------------------*/
#include <stdint.h>

/*---- I/O (top 16 bytes of address space) ----------------------------------*/
extern char __ram_end[];
#define IO_DONE  (*(volatile uint32_t *)((uintptr_t)__ram_end - 16))
#define IO_DEBUG (*(volatile uint32_t *)((uintptr_t)__ram_end - 12))

/*---- Performance counters (require NRV_PERF_CSR) --------------------------*/
static inline uint32_t rdcycle(void)  {
    uint32_t v; __asm__ volatile ("csrr %0, 0xC00" : "=r"(v)); return v;
}
static inline uint32_t rdinstret(void) {
    uint32_t v; __asm__ volatile ("csrr %0, 0xC02" : "=r"(v)); return v;
}

/*---- Simple output via IO_DEBUG -------------------------------------------*/
static void putch(char c) { IO_DEBUG = (uint8_t)c; }

static void puts_n(const char *s) {
    while (*s) putch(*s++);
}

static void print_u32(uint32_t v) {
    char buf[10];
    int i = 0;
    if (v == 0) { putch('0'); return; }
    while (v) { buf[i++] = '0' + (v % 10); v /= 10; }
    while (i--) putch(buf[i]);
}

/*---- Prevent constant-folding ---------------------------------------------*/
#define BARRIER(v) __asm__ volatile ("" : "+r"(v))

/*---- Interrupt control (disable during measurement) -----------------------*/
static inline void irq_disable(void) { __asm__ volatile ("csrc mstatus, 8"); }
static inline void irq_enable(void)  { __asm__ volatile ("csrs mstatus, 8"); }

/*==========================================================================*/
/* Workload 1: 4×4 matrix multiply (uint32_t)                              */
/*==========================================================================*/
#define N 4

static uint32_t A[N][N] = {
    { 1,  2,  3,  4},
    { 5,  6,  7,  8},
    { 9, 10, 11, 12},
    {13, 14, 15, 16}
};

static uint32_t B[N][N] = {
    {17, 18, 19, 20},
    {21, 22, 23, 24},
    {25, 26, 27, 28},
    {29, 30, 31, 32}
};

static uint32_t C[N][N];

static void matmul(uint32_t c[N][N],
                   const uint32_t a[N][N],
                   const uint32_t b[N][N])
{
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            uint32_t sum = 0;
            for (int k = 0; k < N; k++)
                sum += a[i][k] * b[k][j];
            c[i][j] = sum;
        }
}

/*==========================================================================*/
/* Workload 2: TEA (Tiny Encryption Algorithm) — 32 rounds per block       */
/*==========================================================================*/
static void tea_encrypt(uint32_t v[2], const uint32_t key[4])
{
    uint32_t v0 = v[0], v1 = v[1];
    uint32_t sum = 0;
    const uint32_t delta = 0x9E3779B9;
    for (int i = 0; i < 32; i++) {
        sum += delta;
        v0  += ((v1 << 4) + key[0]) ^ (v1 + sum) ^ ((v1 >> 5) + key[1]);
        v1  += ((v0 << 4) + key[2]) ^ (v0 + sum) ^ ((v0 >> 5) + key[3]);
    }
    v[0] = v0;
    v[1] = v1;
}

static const uint32_t tea_key[4] = {
    0xDEADBEEF, 0xCAFEBABE, 0x01234567, 0x89ABCDEF
};

/*==========================================================================*/
/* main                                                                     */
/*==========================================================================*/
int main(void)
{
    uint32_t c0, c1, i0, i1;

    /* ---- Matrix multiply: 10 iterations ---- */
    puts_n("=== 4x4 matmul x10 ===\n");

    irq_disable();
    c0 = rdcycle();
    i0 = rdinstret();

    for (int iter = 0; iter < 10; iter++) {
        matmul(C, A, B);
        /* Use result to prevent optimiser from removing the call */
        BARRIER(C[0][0]);
    }

    c1 = rdcycle();
    i1 = rdinstret();
    irq_enable();

    puts_n("cycles : "); print_u32(c1 - c0); putch('\n');
    puts_n("instret: "); print_u32(i1 - i0); putch('\n');

    /* Print a quick sanity value: C[0][0] should be 250 (1*17+2*21+3*25+4*29) */
    puts_n("C[0][0]: "); print_u32(C[0][0]); putch('\n');

    /* ---- TEA encrypt: 16 blocks ---- */
    puts_n("=== TEA x16 blocks ===\n");

    uint32_t block[2] = {0x01020304, 0x05060708};

    irq_disable();
    c0 = rdcycle();
    i0 = rdinstret();

    for (int blk = 0; blk < 16; blk++) {
        tea_encrypt(block, tea_key);
        BARRIER(block[0]);
    }

    c1 = rdcycle();
    i1 = rdinstret();
    irq_enable();

    puts_n("cycles : "); print_u32(c1 - c0); putch('\n');
    puts_n("instret: "); print_u32(i1 - i0); putch('\n');

    /* ---- Done ---- */
    puts_n("DONE\n");
    IO_DONE = 0;
    while (1) ;
}
