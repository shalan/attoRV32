/* gdb_stub.c — GDB Remote Serial Protocol stub for AttoRV32.
 *
 * Implements the minimum packet set for a useful debugging session:
 *   ? g G m M c s Z0 z0 Z1 z1 qSupported qAttached Hg
 *
 * Software breakpoints (Z0/z0) via c.ebreak / ebreak overwrite.
 * Hardware breakpoints (Z1/z1) via memory-mapped hw_bkpt unit.
 * Software single-step via next-PC prediction (no HW stepper).
 *
 * All code lives in ROM (combinational). Only g_regs[], the breakpoint
 * table, the RSP buffer, and a few flags live in RAM.
 */

#include <stdint.h>
#include "gdb_stub.h"

/* ===================================================================
 * Platform UART I/O
 *
 * IO_BASE is passed by the build system (-DIO_BASE=0x2000).
 * =================================================================== */

#ifndef IO_BASE
#  define IO_BASE 0x2000
#endif

#define UART_DATA   (*(volatile uint32_t *)(IO_BASE + 0x00))
#define UART_STATUS (*(volatile uint32_t *)(IO_BASE + 0x04))

/* ===================================================================
 * Hardware breakpoint registers (hw_bkpt unit, I/O peripheral)
 *
 * BP_BASE is the base address of the hw_bkpt register block.
 * Sub-slot 1 within System Control slot (IO_BASE + 0x20).
 * =================================================================== */

#ifndef BP_BASE
#  define BP_BASE (IO_BASE + 0x20)
#endif

#define BP_CTRL    (*(volatile uint32_t *)(BP_BASE + 0x00))  /* [N-1:0] enable */
#define BP_HIT     (*(volatile uint32_t *)(BP_BASE + 0x04))  /* [N-1:0] hit (W1C) */
#define BP_COUNT   (*(volatile uint32_t *)(BP_BASE + 0x08))  /* N (RO) */
#define BP_ADDR(i) (*(volatile uint32_t *)(BP_BASE + 0x10 + (i) * 4))

int gdb_uart_getc(void) {
    while (!(UART_STATUS & 0x2))     /* wait for RX valid */
        ;
    return UART_DATA & 0xFF;
}

void gdb_uart_putc(int c) {
    while (!(UART_STATUS & 0x1))     /* wait for TX ready */
        ;
    UART_DATA = (uint8_t)c;
}

/* ===================================================================
 * Register frame
 * =================================================================== */

uint32_t g_regs[NGDB_REGS];

/* ===================================================================
 * Hex encode/decode utilities
 * =================================================================== */

static int hex_to_nib(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static char nib_to_hex(int v) {
    return "0123456789abcdef"[v & 0xF];
}

/* Parse a hex number from *pp, advance *pp past it. */
static uint32_t parse_hex(const char **pp) {
    uint32_t v = 0;
    int n;
    while ((n = hex_to_nib(**pp)) >= 0) {
        v = (v << 4) | (uint32_t)n;
        (*pp)++;
    }
    return v;
}

/* Encode len bytes as 2*len hex chars. Returns chars written. */
static int mem_to_hex(const uint8_t *mem, char *buf, int len) {
    int i;
    for (i = 0; i < len; i++) {
        *buf++ = nib_to_hex(mem[i] >> 4);
        *buf++ = nib_to_hex(mem[i]);
    }
    return len * 2;
}

/* Decode 2*len hex chars into memory. Returns bytes written. */
static int hex_to_mem(const char *buf, uint8_t *mem, int len) {
    int i;
    for (i = 0; i < len; i++) {
        int hi = hex_to_nib(*buf++);
        int lo = hex_to_nib(*buf++);
        if (hi < 0 || lo < 0) break;
        mem[i] = (uint8_t)((hi << 4) | lo);
    }
    return i;
}

/* Encode a 32-bit value as 8 hex chars (little-endian byte order). */
static void u32_to_hex_le(uint32_t v, char *buf) {
    int i;
    for (i = 0; i < 4; i++) {
        *buf++ = nib_to_hex((v >> 4) & 0xF);
        *buf++ = nib_to_hex(v & 0xF);
        v >>= 8;
    }
}

/* Parse 8 hex chars as a little-endian 32-bit value. */
static uint32_t hex_le_to_u32(const char *buf) {
    uint32_t v = 0;
    int i;
    for (i = 0; i < 4; i++) {
        int hi = hex_to_nib(buf[i * 2]);
        int lo = hex_to_nib(buf[i * 2 + 1]);
        v |= (uint32_t)((hi << 4) | lo) << (i * 8);
    }
    return v;
}

/* ===================================================================
 * RSP packet framing
 * =================================================================== */

#define PKT_BUF_SIZE 280
static char pkt_buf[PKT_BUF_SIZE];

/* Read a packet payload into buf. Returns length, or -1 on error. */
static int get_packet(char *buf, int max) {
    int c, len, tries;

    for (tries = 0; tries < 3; tries++) {
        /* Wait for '$'. Discard everything else (including '+'/'-'). */
        do { c = gdb_uart_getc(); } while (c != '$');

        uint8_t cksum = 0;
        len = 0;
        while (1) {
            c = gdb_uart_getc();
            if (c == '#') break;
            if (len < max - 1) {
                buf[len++] = (char)c;
                cksum += (uint8_t)c;
            }
        }
        buf[len] = '\0';

        /* Read the two checksum hex chars. */
        int hi = hex_to_nib(gdb_uart_getc());
        int lo = hex_to_nib(gdb_uart_getc());
        uint8_t rx_ck = (uint8_t)((hi << 4) | lo);

        if (rx_ck == cksum) {
            gdb_uart_putc('+');  /* ACK */
            return len;
        }
        gdb_uart_putc('-');      /* NAK — retry */
    }
    return -1;
}

/* Send a packet. data is the payload (no $/#/checksum). */
static void put_packet(const char *data) {
    int retry;
    for (retry = 0; retry < 3; retry++) {
        uint8_t cksum = 0;
        const char *p;

        gdb_uart_putc('$');
        for (p = data; *p; p++) {
            gdb_uart_putc(*p);
            cksum += (uint8_t)*p;
        }
        gdb_uart_putc('#');
        gdb_uart_putc(nib_to_hex(cksum >> 4));
        gdb_uart_putc(nib_to_hex(cksum));

        /* Wait for ACK. Accept '+' or timeout-equivalent. */
        int c = gdb_uart_getc();
        if (c == '+') return;
        /* NAK or garbage — retry. */
    }
}

/* Convenience: send an empty packet (= "not supported"). */
static void put_empty(void) { put_packet(""); }

/* Convenience: send "OK". */
static void put_ok(void) { put_packet("OK"); }

/* Convenience: send an error. */
static void put_err(void) { put_packet("E01"); }

/* ===================================================================
 * Breakpoint table
 * =================================================================== */

#define NBP       10   /* 8 user + 2 step-scratch */
#define NBP_STEP   2   /* last 2 slots are step-scratch */

struct bp {
    uint32_t addr;
    uint32_t orig;      /* saved instruction bytes (2 or 4) */
    uint8_t  len;       /* 2 or 4 */
    uint8_t  used;
};

static struct bp bps[NBP];

static int bp_insert(uint32_t addr, int scratch) {
    int start = scratch ? (NBP - NBP_STEP) : 0;
    int end   = scratch ? NBP : (NBP - NBP_STEP);
    int i;

    /* Check for duplicate. */
    for (i = start; i < end; i++)
        if (bps[i].used && bps[i].addr == addr)
            return 0;  /* already set */

    uint16_t hw = *(volatile uint16_t *)(uintptr_t)addr;
    uint8_t  len = ((hw & 0x3u) == 0x3u) ? 4u : 2u;

    for (i = start; i < end; i++) {
        if (!bps[i].used) {
            bps[i].addr = addr;
            bps[i].len  = len;
            if (len == 2) {
                bps[i].orig = hw;
                *(volatile uint16_t *)(uintptr_t)addr = 0x9002;      /* c.ebreak */
            } else {
                bps[i].orig = *(volatile uint32_t *)(uintptr_t)addr;
                *(volatile uint32_t *)(uintptr_t)addr = 0x00100073;  /* ebreak */
            }
            bps[i].used = 1;
            return 0;
        }
    }
    return -1;  /* table full */
}

static int bp_remove(uint32_t addr, int scratch) {
    int start = scratch ? (NBP - NBP_STEP) : 0;
    int end   = scratch ? NBP : (NBP - NBP_STEP);
    int i;
    for (i = start; i < end; i++) {
        if (bps[i].used && bps[i].addr == addr) {
            if (bps[i].len == 2)
                *(volatile uint16_t *)(uintptr_t)addr = (uint16_t)bps[i].orig;
            else
                *(volatile uint32_t *)(uintptr_t)addr = bps[i].orig;
            bps[i].used = 0;
            return 0;
        }
    }
    return -1;
}

/* Remove all step-scratch breakpoints. */
static void remove_step_bps(void) {
    int i;
    for (i = NBP - NBP_STEP; i < NBP; i++) {
        if (bps[i].used) {
            if (bps[i].len == 2)
                *(volatile uint16_t *)(uintptr_t)bps[i].addr = (uint16_t)bps[i].orig;
            else
                *(volatile uint32_t *)(uintptr_t)bps[i].addr = bps[i].orig;
            bps[i].used = 0;
        }
    }
}

/* ===================================================================
 * Hardware breakpoint management (Z1/z1)
 * =================================================================== */

static int hw_bp_insert(uint32_t addr) {
    uint32_t n = BP_COUNT;
    uint32_t ctrl = BP_CTRL;
    uint32_t i;

    /* Check for duplicate. */
    for (i = 0; i < n; i++)
        if ((ctrl & (1u << i)) && BP_ADDR(i) == addr)
            return 0;  /* already set */

    /* Find a free slot. */
    for (i = 0; i < n; i++) {
        if (!(ctrl & (1u << i))) {
            BP_ADDR(i) = addr;
            BP_CTRL = ctrl | (1u << i);
            return 0;
        }
    }
    return -1;  /* all slots full */
}

static int hw_bp_remove(uint32_t addr) {
    uint32_t n = BP_COUNT;
    uint32_t ctrl = BP_CTRL;
    uint32_t i;

    for (i = 0; i < n; i++) {
        if ((ctrl & (1u << i)) && BP_ADDR(i) == addr) {
            BP_CTRL = ctrl & ~(1u << i);
            BP_HIT = (1u << i);  /* W1C: clear hit flag */
            return 0;
        }
    }
    return -1;  /* not found */
}

/* Clear all hit flags before resuming execution. */
static void hw_bp_clear_hits(void) {
    BP_HIT = BP_HIT;  /* W1C: write back all set bits to clear them */
}

/* ===================================================================
 * Next-PC prediction for software single-step
 * =================================================================== */

/* Sign-extend a value from bit 'b' (0-indexed). */
static inline int32_t sext(uint32_t val, int b) {
    uint32_t m = 1u << b;
    return (int32_t)((val ^ m) - m);
}

/* Returns 1 or 2 successor PCs of the instruction at pc. */
static int next_pcs(uint32_t pc, uint32_t out[2]) {
    uint16_t hw = *(volatile uint16_t *)(uintptr_t)pc;

    /* ---- 32-bit instructions ---- */
    if ((hw & 0x3u) == 0x3u) {
        uint32_t instr = *(volatile uint32_t *)(uintptr_t)pc;
        uint32_t opcode = instr & 0x7F;

        /* JAL: always taken, target = pc + J-imm. */
        if (opcode == 0x6F) {
            int32_t imm = sext(
                ((instr >> 31) << 20) |
                (((instr >> 21) & 0x3FF) << 1) |
                (((instr >> 20) & 1) << 11) |
                (((instr >> 12) & 0xFF) << 12),
                20);
            out[0] = pc + (uint32_t)imm;
            return 1;
        }

        /* JALR: always taken, target = (rs1 + I-imm) & ~1. */
        if (opcode == 0x67) {
            int32_t imm = sext(instr >> 20, 11);
            uint32_t rs1 = (instr >> 15) & 0x1F;
            out[0] = (g_regs[rs1] + (uint32_t)imm) & ~1u;
            return 1;
        }

        /* BRANCH: both fall-through and taken target. */
        if (opcode == 0x63) {
            int32_t imm = sext(
                ((instr >> 31) << 12) |
                (((instr >> 25) & 0x3F) << 5) |
                (((instr >> 8) & 0xF) << 1) |
                (((instr >> 7) & 1) << 11),
                12);
            out[0] = pc + 4;
            out[1] = pc + (uint32_t)imm;
            return 2;
        }

        /* Everything else: fall through. */
        out[0] = pc + 4;
        return 1;
    }

    /* ---- 16-bit compressed instructions ---- */
    uint16_t op   = hw & 0x3;
    uint16_t func = (hw >> 13) & 0x7;

    /* c.j (func=101, op=01): target = pc + CJ-imm. */
    if (op == 1 && func == 5) {
        int32_t imm = sext(
            (((hw >> 12) & 1) << 11) |
            (((hw >> 11) & 1) <<  4) |
            (((hw >>  9) & 3) <<  8) |
            (((hw >>  8) & 1) << 10) |
            (((hw >>  7) & 1) <<  6) |
            (((hw >>  6) & 1) <<  7) |
            (((hw >>  3) & 7) <<  1) |
            (((hw >>  2) & 1) <<  5),
            11);
        out[0] = pc + (uint32_t)imm;
        return 1;
    }

    /* c.jal (func=001, op=01) — RV32 only, same encoding as c.j. */
    if (op == 1 && func == 1) {
        int32_t imm = sext(
            (((hw >> 12) & 1) << 11) |
            (((hw >> 11) & 1) <<  4) |
            (((hw >>  9) & 3) <<  8) |
            (((hw >>  8) & 1) << 10) |
            (((hw >>  7) & 1) <<  6) |
            (((hw >>  6) & 1) <<  7) |
            (((hw >>  3) & 7) <<  1) |
            (((hw >>  2) & 1) <<  5),
            11);
        out[0] = pc + (uint32_t)imm;
        return 1;
    }

    /* c.beqz (func=110, op=01) / c.bnez (func=111, op=01). */
    if (op == 1 && (func == 6 || func == 7)) {
        int32_t imm = sext(
            (((hw >> 12) & 1) << 8) |
            (((hw >> 10) & 3) << 3) |
            (((hw >>  5) & 3) << 6) |
            (((hw >>  3) & 3) << 1) |
            (((hw >>  2) & 1) << 5),
            8);
        out[0] = pc + 2;
        out[1] = pc + (uint32_t)imm;
        return 2;
    }

    /* c.jr (op=10, funct4=1000, rs2=0) / c.jalr (funct4=1001, rs2=0). */
    if (op == 2 && (hw & 0x007F) == 0x0002) {
        uint32_t rs1 = (hw >> 7) & 0x1F;
        uint16_t funct4 = (hw >> 12) & 0xF;
        if ((funct4 == 8 || funct4 == 9) && rs1 != 0) {
            out[0] = g_regs[rs1] & ~1u;
            return 1;
        }
    }

    /* Default: fall through by 2. */
    out[0] = pc + 2;
    return 1;
}

static int stepping;

/* ===================================================================
 * RSP command handlers
 * =================================================================== */

/* '?' — stop reason. */
static void cmd_stop_reason(void) {
    put_packet("T05");
}

/* 'g' — read all registers. */
static void cmd_read_regs(void) {
    char *p = pkt_buf;
    int i;
    g_regs[0] = 0;  /* x0 is always 0 */
    for (i = 0; i < NGDB_REGS; i++) {
        u32_to_hex_le(g_regs[i], p);
        p += 8;
    }
    *p = '\0';
    put_packet(pkt_buf);
}

/* 'G' — write all registers. */
static void cmd_write_regs(const char *data) {
    int i;
    for (i = 0; i < NGDB_REGS; i++) {
        g_regs[i] = hex_le_to_u32(data);
        data += 8;
    }
    g_regs[0] = 0;
    put_ok();
}

/* 'm addr,length' — read memory. */
static void cmd_read_mem(const char *args) {
    const char *p = args;
    uint32_t addr = parse_hex(&p);
    if (*p == ',') p++;
    uint32_t len = parse_hex(&p);

    /* Clamp to half our buffer (2 hex chars per byte). */
    if (len > (PKT_BUF_SIZE - 1) / 2)
        len = (PKT_BUF_SIZE - 1) / 2;

    int n = mem_to_hex((const uint8_t *)(uintptr_t)addr, pkt_buf, (int)len);
    pkt_buf[n] = '\0';
    put_packet(pkt_buf);
}

/* 'M addr,length:XX...' — write memory. */
static void cmd_write_mem(const char *args) {
    const char *p = args;
    uint32_t addr = parse_hex(&p);
    if (*p == ',') p++;
    uint32_t len = parse_hex(&p);
    if (*p == ':') p++;

    hex_to_mem(p, (uint8_t *)(uintptr_t)addr, (int)len);
    put_ok();
}

/* 'c [addr]' — continue. */
static int cmd_continue(const char *args) {
    if (*args) {
        const char *p = args;
        g_regs[NGDB_REGS - 1] = parse_hex(&p);  /* set PC */
    }
    return 1;  /* exit RSP loop */
}

/* 's [addr]' — single-step. */
static int cmd_step(const char *args) {
    if (*args) {
        const char *p = args;
        g_regs[NGDB_REGS - 1] = parse_hex(&p);
    }

    /* Plant step-scratch breakpoints at all successor PCs. */
    uint32_t targets[2];
    int n = next_pcs(g_regs[NGDB_REGS - 1], targets);
    int i;
    for (i = 0; i < n; i++)
        bp_insert(targets[i], 1);

    stepping = 1;
    return 1;  /* exit RSP loop → mret → hit step BP → re-enter */
}

/* 'Z0,addr,kind' — insert software breakpoint.
 * 'Z1,addr,kind' — insert hardware breakpoint. */
static void cmd_insert_bp(const char *args) {
    const char *p = args;
    char type = *p;
    if (*(p + 1) != ',') { put_empty(); return; }
    p += 2;
    uint32_t addr = parse_hex(&p);

    int rc;
    if (type == '0') {
        rc = bp_insert(addr, 0);
    } else if (type == '1') {
        rc = hw_bp_insert(addr);
    } else {
        put_empty();  /* unsupported BP type */
        return;
    }

    if (rc == 0)
        put_ok();
    else
        put_err();
}

/* 'z0,addr,kind' — remove software breakpoint.
 * 'z1,addr,kind' — remove hardware breakpoint. */
static void cmd_remove_bp(const char *args) {
    const char *p = args;
    char type = *p;
    if (*(p + 1) != ',') { put_empty(); return; }
    p += 2;
    uint32_t addr = parse_hex(&p);

    int rc;
    if (type == '0') {
        rc = bp_remove(addr, 0);
    } else if (type == '1') {
        rc = hw_bp_remove(addr);
    } else {
        put_empty();
        return;
    }

    if (rc == 0)
        put_ok();
    else
        put_err();
}

/* 'q...' — query packets. */
static void cmd_query(const char *args) {
    /* qSupported */
    if (args[0] == 'S' && args[1] == 'u') {
        put_packet("PacketSize=200;swbreak+;hwbreak+");
        return;
    }
    /* qAttached */
    if (args[0] == 'A' && args[1] == 't') {
        put_packet("1");
        return;
    }
    put_empty();
}

/* ===================================================================
 * Entry point
 * =================================================================== */

void gdb_stub_entry(uint32_t cause) {
    (void)cause;

    /* If re-entering after a single-step, remove scratch BPs. */
    if (stepping) {
        remove_step_bps();
        stepping = 0;
    }

    /* Send initial stop-reply. */
    cmd_stop_reason();

    /* RSP command loop. */
    for (;;) {
        char buf[PKT_BUF_SIZE];
        int len = get_packet(buf, sizeof buf);
        if (len < 0) continue;

        int resume = 0;
        switch (buf[0]) {
        case '?':
            cmd_stop_reason();
            break;
        case 'g':
            cmd_read_regs();
            break;
        case 'G':
            cmd_write_regs(buf + 1);
            break;
        case 'm':
            cmd_read_mem(buf + 1);
            break;
        case 'M':
            cmd_write_mem(buf + 1);
            break;
        case 'c':
            resume = cmd_continue(buf + 1);
            break;
        case 's':
            resume = cmd_step(buf + 1);
            break;
        case 'Z':
            cmd_insert_bp(buf + 1);
            break;
        case 'z':
            cmd_remove_bp(buf + 1);
            break;
        case 'q':
            cmd_query(buf + 1);
            break;
        case 'H':
            /* Hg — set thread (we're single-threaded). */
            put_ok();
            break;
        case 'v':
            /* vMustReplyEmpty and friends. */
            put_empty();
            break;
        default:
            put_empty();
            break;
        }

        if (resume) break;
    }

    /* Clear hardware breakpoint hit flags before resuming. */
    hw_bp_clear_hits();

    /* On return, crt0_stub.S restores g_regs[] → registers, mepc, mret. */
}
