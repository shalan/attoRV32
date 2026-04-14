/*----------------------------------------------------------------------------
 * bench_sort.c — Sorting benchmark for AttoRV32.
 *
 * Workloads:
 *   1) Insertion sort on 32-element uint32_t array, 5 iterations.
 *   2) Bubble sort on 32-element uint32_t array, 5 iterations.
 *
 * Reads mcycle / minstret before and after each workload, prints results
 * via IO_DEBUG (one character at a time), then writes IO_DONE = 0 (PASS).
 *
 * Build:  make CROSS=... BENCH_SORT=1 ADDR_WIDTH=12 RV32E=1 HAVE_M=0
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

/*---- Initial data (pseudo-random, reproducible) ---------------------------*/
#define ARRAY_SIZE 32

/* Simple xorshift32 PRNG for deterministic test vectors */
static uint32_t xorshift32(uint32_t *state) {
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

static void fill_array(uint32_t *arr, int n, uint32_t seed) {
    uint32_t state = seed;
    for (int i = 0; i < n; i++)
        arr[i] = xorshift32(&state) & 0xFFFF;   /* keep values small */
}

/*==========================================================================*/
/* Workload 1: Insertion sort                                               */
/*==========================================================================*/
static void insertion_sort(uint32_t *arr, int n)
{
    for (int i = 1; i < n; i++) {
        uint32_t key = arr[i];
        int j = i - 1;
        while (j >= 0 && arr[j] > key) {
            arr[j + 1] = arr[j];
            j--;
        }
        arr[j + 1] = key;
    }
}

/*==========================================================================*/
/* Workload 2: Bubble sort                                                  */
/*==========================================================================*/
static void bubble_sort(uint32_t *arr, int n)
{
    for (int i = 0; i < n - 1; i++) {
        int swapped = 0;
        for (int j = 0; j < n - 1 - i; j++) {
            if (arr[j] > arr[j + 1]) {
                uint32_t tmp = arr[j];
                arr[j] = arr[j + 1];
                arr[j + 1] = tmp;
                swapped = 1;
            }
        }
        if (!swapped) break;
    }
}

/*==========================================================================*/
/* Verification: check array is sorted                                      */
/*==========================================================================*/
static int is_sorted(const uint32_t *arr, int n)
{
    for (int i = 1; i < n; i++)
        if (arr[i] < arr[i - 1]) return 0;
    return 1;
}

/*==========================================================================*/
/* main                                                                     */
/*==========================================================================*/
static uint32_t arr[ARRAY_SIZE];

int main(void)
{
    uint32_t c0, c1, i0, i1;

    /* ---- Insertion sort: 5 iterations ---- */
    puts_n("=== insertion sort 32x5 ===\n");

    irq_disable();
    c0 = rdcycle();
    i0 = rdinstret();

    for (int iter = 0; iter < 5; iter++) {
        fill_array(arr, ARRAY_SIZE, 0xDEAD0000u + iter);
        BARRIER(arr[0]);
        insertion_sort(arr, ARRAY_SIZE);
        BARRIER(arr[0]);
    }

    c1 = rdcycle();
    i1 = rdinstret();
    irq_enable();

    puts_n("cycles : "); print_u32(c1 - c0); putch('\n');
    puts_n("instret: "); print_u32(i1 - i0); putch('\n');
    puts_n("sorted : "); puts_n(is_sorted(arr, ARRAY_SIZE) ? "yes" : "NO");
    putch('\n');

    /* ---- Bubble sort: 5 iterations ---- */
    puts_n("=== bubble sort 32x5 ===\n");

    irq_disable();
    c0 = rdcycle();
    i0 = rdinstret();

    for (int iter = 0; iter < 5; iter++) {
        fill_array(arr, ARRAY_SIZE, 0xCAFE0000u + iter);
        BARRIER(arr[0]);
        bubble_sort(arr, ARRAY_SIZE);
        BARRIER(arr[0]);
    }

    c1 = rdcycle();
    i1 = rdinstret();
    irq_enable();

    puts_n("cycles : "); print_u32(c1 - c0); putch('\n');
    puts_n("instret: "); print_u32(i1 - i0); putch('\n');
    puts_n("sorted : "); puts_n(is_sorted(arr, ARRAY_SIZE) ? "yes" : "NO");
    putch('\n');

    /* ---- Done ---- */
    puts_n("DONE\n");
    IO_DONE = 0;
    while (1) ;
}
