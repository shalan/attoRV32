/*----------------------------------------------------------------------------
 * tb_dbg_gdb.cpp — Verilator testbench with TCP socket for GDB RSP.
 *
 * Instantiates attorv32_dbg and bridges its internal UART registers to
 * a TCP socket on localhost:3333. GDB connects with:
 *
 *     riscv64-elf-gdb -ex "target remote localhost:3333" firmware.elf
 *
 * The UART bridge pokes uart_rx_data/uart_rx_valid when a byte arrives
 * on the socket, and reads uart_tx_data/uart_tx_valid to send bytes out.
 *
 * Usage:
 *     make -C sim -f Makefile.gdb
 *     ./sim/obj_dbg/Vattorv32_dbg +hex=build/dbg_test/fw.hex
 *
 * Build:
 *     verilator --cc --exe -DBENCH --top-module attorv32_dbg \
 *         rtl/attorv32.v rtl/attorv32_dbg.v rtl/stub_rom.v \
 *         sim/tb_dbg_gdb.cpp -o Vattorv32_dbg
 *---------------------------------------------------------------------------*/

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <errno.h>

#include "Vattorv32_dbg.h"
#include "Vattorv32_dbg___024root.h"
#include "verilated.h"

/* ---------- Configuration ---------- */
static int        tcp_port    = 3333;
static uint64_t   max_cycles  = 100000000ULL;  /* 100M cycles default */
static const char *hex_file   = nullptr;
static bool       trace_uart  = false;

/* ---------- TCP server ---------- */
static int listen_fd = -1;
static int client_fd = -1;

static int tcp_listen(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return -1; }

    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port        = htons(port);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); close(fd); return -1;
    }
    if (listen(fd, 1) < 0) {
        perror("listen"); close(fd); return -1;
    }
    return fd;
}

static int tcp_accept(int lfd) {
    printf("[gdb-bridge] Waiting for GDB on localhost:%d ...\n", tcp_port);
    fflush(stdout);
    int fd = accept(lfd, nullptr, nullptr);
    if (fd < 0) { perror("accept"); return -1; }

    /* Disable Nagle — RSP packets are small, we want them sent immediately. */
    int opt = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));

    /* Set non-blocking so we can poll without stalling the simulation. */
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    printf("[gdb-bridge] GDB connected.\n");
    fflush(stdout);
    return fd;
}

/* Try to read one byte from the socket. Returns 0..255 or -1 if nothing. */
static int tcp_try_read(void) {
    if (client_fd < 0) return -1;
    uint8_t b;
    ssize_t n = read(client_fd, &b, 1);
    if (n == 1) return b;
    if (n == 0) {
        /* EOF — GDB disconnected. */
        printf("[gdb-bridge] GDB disconnected.\n");
        close(client_fd);
        client_fd = -1;
        return -1;
    }
    /* EAGAIN/EWOULDBLOCK = nothing available. */
    return -1;
}

static void tcp_write(uint8_t b) {
    if (client_fd < 0) return;
    ssize_t n = write(client_fd, &b, 1);
    if (n <= 0 && errno != EAGAIN) {
        printf("[gdb-bridge] Write error, closing.\n");
        close(client_fd);
        client_fd = -1;
    }
}

/* ---------- Hex loading ---------- */
static void load_hex(Vattorv32_dbg *top, const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "Cannot open %s\n", path); exit(1); }

    char line[64];
    int idx = 0;
    while (fgets(line, sizeof(line), f)) {
        /* Skip blank lines. */
        if (line[0] == '\n' || line[0] == '\r') continue;
        uint32_t word = (uint32_t)strtoul(line, nullptr, 16);
        if (idx < 1024)
            top->rootp->attorv32_dbg__DOT__ram[idx] = word;
        idx++;
    }
    fclose(f);
    printf("[gdb-bridge] Loaded %d words from %s\n", idx, path);
}

/* ---------- Signal handling ---------- */
static volatile bool quit = false;
static void sighandler(int) { quit = true; }

/* ---------- Main ---------- */
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    /* Parse our custom plusargs. */
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "+hex=", 5) == 0)
            hex_file = argv[i] + 5;
        else if (strncmp(argv[i], "+port=", 6) == 0)
            tcp_port = atoi(argv[i] + 6);
        else if (strncmp(argv[i], "+timeout=", 9) == 0)
            max_cycles = strtoull(argv[i] + 9, nullptr, 0);
        else if (strcmp(argv[i], "+trace_uart") == 0)
            trace_uart = true;
    }

    /* Create model. */
    Vattorv32_dbg *top = new Vattorv32_dbg;

    /* Zero RAM, then load hex. */
    for (int i = 0; i < 1024; i++)
        top->rootp->attorv32_dbg__DOT__ram[i] = 0;
    if (hex_file)
        load_hex(top, hex_file);

    /* Open TCP listen socket. */
    listen_fd = tcp_listen(tcp_port);
    if (listen_fd < 0) { fprintf(stderr, "Cannot bind port %d\n", tcp_port); return 1; }

    signal(SIGINT, sighandler);
    signal(SIGPIPE, SIG_IGN);

    /* Reset. */
    top->clk    = 0;
    top->resetn = 0;
    top->irq    = 0;
    top->uart_rx = 1;  /* idle high */

    for (int i = 0; i < 10; i++) {
        top->clk ^= 1;
        top->eval();
    }
    top->resetn = 1;

    printf("[gdb-bridge] Reset released. Running at localhost:%d\n", tcp_port);
    printf("[gdb-bridge] Connect GDB with:\n");
    printf("    riscv64-unknown-elf-gdb -ex 'target remote localhost:%d' <elf>\n\n", tcp_port);
    fflush(stdout);

    /* Accept GDB connection (blocking). */
    client_fd = tcp_accept(listen_fd);
    if (client_fd < 0) { close(listen_fd); return 1; }

    /* ---------- Main simulation loop ---------- */
    uint64_t cycle = 0;
    int pending_rx = -1;      /* byte waiting to be injected */
    int break_cycles = 0;     /* >0 = driving uart_rx low for UART break */

    /* Trigger a UART break on connect so the CPU halts and the stub
     * sends a T05 stop-reply — this is what GDB expects on attach. */
    break_cycles = 20;
    printf("[gdb-bridge] Triggering initial UART break to halt CPU.\n");
    fflush(stdout);

    uint8_t prev_rx_valid = 0;

    while (!quit && !Verilated::gotFinish() && cycle < max_cycles) {

        /* --- UART break: drive uart_rx low for break_cycles --- */
        if (break_cycles > 0) {
            top->uart_rx = 0;
            break_cycles--;
            if (break_cycles == 0) {
                top->uart_rx = 1;  /* release */
            }
        }

        /* --- RX: inject byte BEFORE rising edge so the DUT sees it
         *         immediately in this cycle's combinational paths.
         *
         * CRITICAL: Do NOT inject during S_WAIT (state 3). The CPU
         * does a write-back during both S_EXECUTE and S_WAIT. If we
         * change uart_rx_data while the CPU is in S_WAIT after a load
         * from UART_DATA, the register file gets overwritten with the
         * new byte instead of the old one (since mem_addr still points
         * to UART_DATA and LOAD_data = mem_rdata = {24'b0, uart_rx_data}). --- */
        if (!top->rootp->attorv32_dbg__DOT__uart_rx_valid
            && top->rootp->attorv32_dbg__DOT__u_core__DOT__state != 3 /* S_WAIT */
            && break_cycles == 0) {
            /* DUT is ready for a new byte. */
            if (pending_rx < 0)
                pending_rx = tcp_try_read();

            /* Ctrl-C (0x03) from GDB → trigger UART break instead of
             * injecting the byte.  This halts the CPU asynchronously. */
            if (pending_rx == 0x03) {
                printf("[gdb-bridge] Ctrl-C → UART break\n");
                fflush(stdout);
                break_cycles = 20;
                pending_rx = -1;
            } else if (pending_rx >= 0) {
                top->rootp->attorv32_dbg__DOT__uart_rx_data  = (uint8_t)pending_rx;
                top->rootp->attorv32_dbg__DOT__uart_rx_valid  = 1;
                if (trace_uart)
                    fprintf(stderr, "[RX @%llu] 0x%02X '%c'\n",
                           (unsigned long long)cycle, pending_rx,
                           (pending_rx >= 0x20 && pending_rx < 0x7F) ? pending_rx : '.');
                pending_rx = -1;
            }
        }

        /* Rising edge. */
        top->clk = 1;
        top->eval();

        /* --- TX: check if the stub wrote a byte --- */
        if (top->rootp->attorv32_dbg__DOT__uart_tx_valid) {
            uint8_t b = top->rootp->attorv32_dbg__DOT__uart_tx_data;
            tcp_write(b);
            if (trace_uart)
                fprintf(stderr, "[TX @%llu] 0x%02X '%c'\n",
                        (unsigned long long)cycle, b,
                        (b >= 0x20 && b < 0x7F) ? b : '.');
        }

        /* --- Track uart_rx_valid consumption --- */
        if (trace_uart) {
            uint8_t cur = top->rootp->attorv32_dbg__DOT__uart_rx_valid;
            if (prev_rx_valid && !cur) {
                fprintf(stderr, "[RX consumed @%llu]\n",
                        (unsigned long long)cycle);
            }
            prev_rx_valid = cur;
        }

        /* Falling edge. */
        top->clk = 0;
        top->eval();

        cycle++;

        /* Re-accept if GDB disconnects and reconnects. */
        if (client_fd < 0) {
            printf("[gdb-bridge] Waiting for GDB reconnect ...\n");
            fflush(stdout);
            client_fd = tcp_accept(listen_fd);
            /* Halt CPU for new connection. */
            break_cycles = 20;
        }
    }

    printf("\n[gdb-bridge] Simulation ended after %llu cycles.\n",
           (unsigned long long)cycle);

    top->final();
    delete top;

    if (client_fd >= 0) close(client_fd);
    if (listen_fd >= 0) close(listen_fd);
    return 0;
}
