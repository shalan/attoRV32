# AttoRV32 Debug Facility — Specification

## 1. Overview

AttoRV32 has no built-in debug module (no DM/DTM, no JTAG). Instead, a
full GDB session — halt, continue, single-step, software and hardware
breakpoints, register/memory read/write — is achieved with:

- A single added output port (`pc_out`) on the core.
- A **combinational ROM** (~2.7 KiB) synthesised as LUT logic containing
  the ISR entry and GDB RSP engine.
- A **debug UART** with auto-baud (0x55) and break detection.
- A **hardware breakpoint unit** (4 PC-match comparators, memory-mapped).
- A 1-FF `dbg_halt_mask` in the core to prevent re-triggering.

---

## 2. Hardware Architecture

### 2.1 Memory Map

The debug SoC (`rtl/attorv32_dbg.v`) uses page-aligned address decode on
`mem_addr[15:12]`. The core's `ADDR_WIDTH = RAM_AW + 2` (14 bits for
RAM_AW=12), covering 0x0000–0x3FFF.

```
    Example: RAM_AW = 12 → ADDR_WIDTH = 14

    0x0000 ┬───────────────────┐
           │       RAM          │  4 KiB — user .text + .data + .bss + stack
           │                    │  + stub mutable data (g_regs[], BPs, RSP buf)
    0x1000 ├───────────────────┤  ← MTVEC_ADDR
           │    stub ROM        │  4 KiB — _isr_entry + gdb_stub (combinational)
    0x2000 ├───────────────────┤
           │       I/O          │  4 KiB — 16 peripheral slots × 256 bytes
    0x3000 ├───────────────────┤
           │    (reserved)      │  future use (flash XiP, etc.)
    0x3FFF └───────────────────┘
```

Address decode (`rtl/attorv32_dbg.v`):

```verilog
wire [3:0] page_sel = mem_addr[15:12];

wire sel_ram = (page_sel == 4'h0);   // 0x0000–0x0FFF
wire sel_rom = (page_sel == 4'h1);   // 0x1000–0x1FFF
wire sel_io  = (page_sel == 4'h2);   // 0x2000–0x2FFF
```

Notes:
- The core's PC (ADDR_WIDTH bits) only needs to reach RAM + ROM
  (0x0000–0x1FFF = 13 bits). But `loadstore_addr` is also ADDR_WIDTH bits,
  so ADDR_WIDTH must be wide enough for load/store to reach I/O at 0x2000.
  Hence ADDR_WIDTH = RAM_AW + 2 = 14.
- `mem_addr` is 32 bits from the core. The SoC only decodes bits [15:0].

### 2.2 I/O Peripheral Slots

The I/O region (0x2000–0x2FFF) is divided into 16 peripheral slots of
256 bytes each:

```verilog
wire [3:0] io_slot = mem_addr[11:8];   // 16 slots × 256 bytes
```

| Slot | Address Range | Peripheral | Status |
|---|---|---|---|
| 0 | `0x2000–0x20FF` | **System Control** | Implemented (see §2.3) |
| 1–15 | `0x2100–0x2FFF` | *(user peripherals)* | Available for GPIO, SPI, I2C, etc. |

### 2.3 Slot 0 — System Control (0x2000–0x20FF)

Slot 0 contains the core system infrastructure, divided into 8 sub-slots
of 32 bytes each. `mem_addr[7:5]` selects the sub-slot, `mem_addr[4:2]`
selects the register within it (8 word-aligned registers per sub-slot).

```verilog
wire [2:0] sys_subslot = mem_addr[7:5];  // 8 sub-slots × 32 bytes
wire [2:0] sys_reg     = mem_addr[4:2];  // 8 registers per sub-slot
```

| Sub-slot | `[7:5]` | Address | Block | Status |
|---|---|---|---|---|
| 0 | `000` | `0x2000` | **UART** | Implemented |
| 1 | `001` | `0x2020` | **HW Breakpoints** | Implemented |
| 2 | `010` | `0x2040` | **System Timer** | TBD |
| 3 | `011` | `0x2060` | **PIC** | TBD |
| 4 | `100` | `0x2080` | **Clocking** | TBD |
| 5 | `101` | `0x20A0` | **Control** | Implemented |
| 6 | `110` | `0x20C0` | *(reserved)* | — |
| 7 | `111` | `0x20E0` | *(reserved)* | — |

#### Sub-slot 0: UART (0x2000–0x201F)

| Reg | Offset | Name | Access | Description |
|---|---|---|---|---|
| 0 | `+0x00` | `UART_DATA` | R/W | **Write:** TX byte [7:0]. **Read:** RX byte [7:0] (clears rx_valid). |
| 1 | `+0x04` | `UART_STATUS` | RO | [0] `tx_ready` — TX idle. [1] `rx_valid` — byte available. [2] `baud_locked` — calibration done. |
| 2–7 | | *(reserved)* | — | — |

#### Sub-slot 1: Hardware Breakpoints (0x2020–0x203F)

| Reg | Offset | Name | Access | Description |
|---|---|---|---|---|
| 0 | `+0x00` | `BP_CTRL` | R/W | [N-1:0] breakpoint enable bits (N=4). |
| 1 | `+0x04` | `BP_HIT` | R/W1C | [N-1:0] hit flags. Write 1 to clear. |
| 2 | `+0x08` | `BP_COUNT` | RO | Number of breakpoint slots (reads as 4). |
| 3 | `+0x0C` | *(reserved)* | — | — |
| 4 | `+0x10` | `BP_ADDR[0]` | R/W | Breakpoint 0 match address (ADDR_WIDTH bits). |
| 5 | `+0x14` | `BP_ADDR[1]` | R/W | Breakpoint 1 match address. |
| 6 | `+0x18` | `BP_ADDR[2]` | R/W | Breakpoint 2 match address. |
| 7 | `+0x1C` | `BP_ADDR[3]` | R/W | Breakpoint 3 match address. |

The hw_bkpt unit (`rtl/hw_bkpt.v`) compares the core's `pc_out` against
the enabled BP_ADDR registers every cycle. On a match, `halt_req` is
asserted for one clock cycle, which is OR'd into the core's `dbg_halt_req`.
The stub handles hardware breakpoints via Z1/z1 RSP packets.

#### Sub-slot 5: Control (0x20A0–0x20BF)

| Reg | Offset | Name | Access | Description |
|---|---|---|---|---|
| 0 | `+0x00` | `CTRL` | WO | Write any value → `$finish` (simulation bench only; no-op in synthesis). |
| 1–7 | | *(reserved)* | — | — |

### 2.6 CSRs (inside the core)

| CSR | Address | Access | Description |
|---|---|---|---|
| `mstatus` | `0x300` | R/W | Bit [3] = MIE (machine interrupt enable). |
| `mepc` | `0x341` | R/W | Exception PC. HW-written on trap entry; SW-writable. |
| `mcause` | `0x342` | RO | Trap cause. Bit [31] = interrupt flag. Also serves as handler-active lock bit. |

Optionally (gated by `` `define NRV_PERF_CSR ``):

| CSR | Address | Access | Description |
|---|---|---|---|
| `rdcycle` | `0xC00` | RO | Cycle counter low 32 bits. |
| `rdcycleh` | `0xC80` | RO | Cycle counter high 32 bits. |

`mcause` values:

| Value | Meaning |
|---|---|
| `0x8000_000B` | External IRQ (maskable) |
| `0x8000_0000` | NMI (non-maskable) |
| `0x0000_000B` | ECALL |
| `0x0000_0003` | EBREAK / debug halt |

### 2.7 Debug UART (`rtl/dbg_uart.v`)

A minimal UART with auto-baud calibration and break detection for
debug-over-serial. ~170 lines of Verilog, all 10-bit counters.

**Auto-baud calibration:**
After reset, the UART waits for a 0x55 byte ('U'). On the wire (LSB-first,
8N1) this produces 5 evenly-spaced falling edges spanning 8 bit periods:

```
  IDLE  S  D0 D1 D2 D3 D4 D5 D6 D7 STOP
   1    0   1  0  1  0  1  0  1  0   1
        ↓      ↓     ↓     ↓     ↓        ← 5 falling edges
        |←--------  8 bit periods  ------→|
```

The counter between the 1st and 5th edge is right-shifted by 3 to derive
`baud_div` (the bit period in clock cycles). The 0x55 byte is consumed
and NOT delivered to the CPU. After calibration, `locked` goes high.

**GDB compatibility note:** GDB RSP does NOT send 0x55 — its first byte
is `$` (0x24) or `+` (0x2B). The host must send 0x55 before launching GDB:

```bash
# Option 1: shell one-liner
echo -ne '\x55' > /dev/ttyUSBx; sleep 0.1
riscv64-elf-gdb -ex 'target remote /dev/ttyUSBx' firmware.elf

# Option 2: the Verilator GDB bridge handles it internally
```

**Break detection:**
After baud lock, if RX stays low for ≥12 bit-periods (longer than any
valid 8N1 frame), `brk` pulses high for one clock cycle. This is used
for GDB Ctrl-C (async halt).

**Simulation vs Synthesis:**
- `ifdef BENCH`: a behavioural stub with directly poke-able registers
  (`uart_rx_data`, `uart_rx_valid`, `uart_tx_data`, `uart_tx_valid`).
  No bit-level serial — the Verilator bridge writes/reads registers directly.
- Otherwise: the real `dbg_uart` module is instantiated.

### 2.8 UART Break Detector (Simulation)

In BENCH mode, a simplified 4-bit counter detects break:

```verilog
reg [3:0] brk_cnt;
always @(posedge clk)
   if (!resetn)          brk_cnt <= 0;
   else if (uart_rx)     brk_cnt <= 0;         // RX idle → reset
   else if (~(&brk_cnt)) brk_cnt <= brk_cnt+1; // count while low, saturate

wire uart_break = &brk_cnt;  // → dbg_halt_req
```

### 2.9 Trap Behaviour of `dbg_halt_req`

`dbg_halt_req` is the OR of `uart_break` (UART break detector) and
`bp_halt` (hardware breakpoint match). It bypasses both `mstatus.MIE`
and `mcause`:

| Property | Value |
|---|---|
| Blocked by MIE=0? | **No** |
| Blocked by mcause=1 (in handler)? | **No** |
| `mcause` reported | `0x0000_0003` (same as EBREAK) |
| `mepc` saved | `PC_new` (the instruction *about* to execute) |
| Trap vector | `MTVEC_ADDR` (ROM base) |

This means the CPU can be halted at any time, even inside an ISR with
interrupts disabled. The stub sees `mcause=3` and handles it identically
to a software breakpoint.

**Re-trigger prevention:** A 1-FF `dbg_halt_mask` register in the core
is set when `dbg_halt_req` is accepted and cleared on `mret`. While set,
further `dbg_halt_req` assertions are ignored. Cost: 1 FF + 2 gates.

### 2.10 Stub ROM (`rtl/stub_rom.v`)

A parameterised Verilog module containing a single `always @(*)
case(addr)` block. Auto-generated by `scripts/gen_stub_rom.py` from
compiled RISC-V code. Yosys synthesises it as a combinational LUT tree.

- **Zero latency**: instruction fetches from ROM need no wait states.
- **Read-only**: only `.text` and `.rodata` live in ROM. All mutable
  state (`g_regs[]`, breakpoint table, RSP buffer) lives in RAM.

Measured size: ~2.7 KiB code → ~681 words → ~2,300 cells on Sky130.

---

## 3. Software Architecture

### 3.1 Components

| File | Section | Description |
|---|---|---|
| `sw/crt0_stub.S` | `.isr` (ROM) | ISR entry: save all regs → `g_regs[]`, call stub, restore, `mret`. |
| `sw/gdb_stub.c` | `.text` (ROM) | RSP packet engine + command handlers. ~600 lines of C. |
| `sw/gdb_stub.h` | — | `g_regs[]` frame definition, entry point, UART API. |
| `sw/stub_link.ld.in` | — | Linker script: `.text` in ROM, `.data`/`.bss` in RAM. |

### 3.2 Register Frame (`g_regs[]`)

```c
// RV32I: 33 words = 132 bytes  (x0..x31 + pc)
// RV32E: 17 words =  68 bytes  (x0..x15 + pc)
uint32_t g_regs[NGDB_REGS];
```

Layout matches GDB's g-packet register order:

| Index | Register | Notes |
|---|---|---|
| 0 | `x0` | Always 0 (not saved; slot used as scratch during ISR entry) |
| 1 | `x1` (ra) | |
| 2 | `x2` (sp) | Saved *before* clobbering sp with stub stack |
| … | … | |
| 31 | `x31` (RV32I only) | |
| 32 (or 16) | `pc` | Loaded from `mepc` CSR on entry; written back on exit |

### 3.3 ISR Entry Sequence (`crt0_stub.S`)

The ISR entry is the first code in ROM (at `MTVEC_ADDR = ROM_BASE`):

```
1. sw  sp, __sp_save(zero)       // stash original sp using zero-base addressing
2. la  sp, g_regs                // sp = base of register frame
3. sw  x1, 4(sp)                 // save all registers except x0 and x2
   sw  x3, 12(sp)
   ...
   sw  x31, 124(sp)              // (x16..x31 only for RV32I)
4. lw  t0, __sp_save(zero)       // recover original sp
   sw  t0, 8(sp)                 // save to g_regs[2]
5. csrr t0, mepc                 // save PC
   sw  t0, 128(sp)               // g_regs[32] (or 64(sp) for RV32E g_regs[16])
6. csrr a0, mcause               // argument to gdb_stub_entry()
7. la  sp, __stub_stack_top      // switch to stub's own stack
8. call gdb_stub_entry           // → RSP loop (may modify g_regs[])
9. la  sp, g_regs                // restore base
10. lw  t0, 128(sp)              // restore mepc (GDB may have changed it)
    csrw mepc, t0
11. lw  x1, 4(sp)                // restore all registers
    lw  x3, 12(sp)
    ...
    lw  x31, 124(sp)
12. lw  sp, 8(sp)                // restore original sp (must be last)
13. mret
```

### 3.4 RSP Packet Engine

**Framing:** `$payload#XX` where `XX` is a 2-hex-digit modular checksum.
The stub sends `+` (ACK) or `-` (NAK) after receiving each packet.

**Supported packets:**

| Packet | Handler | Reply |
|---|---|---|
| `?` | Stop reason | `T05` (SIGTRAP) |
| `g` | Read all registers | hex-encoded `g_regs[]`, little-endian per word |
| `G` | Write all registers | `OK` |
| `m addr,length` | Read memory | hex-encoded bytes |
| `M addr,length:XX…` | Write memory | `OK` |
| `c [addr]` | Continue | *(exit RSP loop → `mret`)* |
| `s [addr]` | Single-step | *(arm step BPs → exit → re-enter → `T05`)* |
| `Z0,addr,kind` | Insert SW breakpoint | `OK` |
| `z0,addr,kind` | Remove SW breakpoint | `OK` |
| `Z1,addr,kind` | Insert HW breakpoint | `OK` (or `E01` if full) |
| `z1,addr,kind` | Remove HW breakpoint | `OK` |
| `qSupported` | Feature negotiation | `PacketSize=200;swbreak+;hwbreak+` |
| `qAttached` | Attached to process? | `1` |
| `Hg` | Set thread | `OK` (single-threaded) |
| everything else | — | `` (empty packet = unsupported) |

### 3.5 Software Breakpoints

The stub maintains a table of ~10 slots:

```c
struct bp { uint32_t addr; uint32_t orig; uint8_t len; uint8_t used; };
```

**Insert (`Z0`):** Read the instruction at `addr`. If `(instr & 3) == 3`,
it's a 32-bit instruction: save 4 bytes, overwrite with `ebreak`
(`0x00100073`). Otherwise save 2 bytes, overwrite with `c.ebreak`
(`0x9002`). Mark slot as used.

**Remove (`z0`):** Find the slot, restore the saved bytes, free the slot.

**Note:** Software breakpoints only work in RAM. ROM-resident code and
flash-resident code cannot use software breakpoints.

### 3.6 Hardware Breakpoints

For code in read-only memory (ROM, flash), the stub uses the hw_bkpt
peripheral via Z1/z1 RSP packets.

**Insert (`Z1`):** Find a free hw_bkpt slot (check BP_COUNT, scan
BP_CTRL). Write the address to BP_ADDR[i], set the enable bit in
BP_CTRL. Returns `OK` or `E01` if all slots are in use.

**Remove (`z1`):** Find the slot matching the address, clear its enable
bit in BP_CTRL. Returns `OK`.

On stub entry, `hw_bp_clear_hits()` writes BP_HIT to clear all hit flags.

### 3.7 Software Single-Step

No hardware stepper is needed. The stub emulates single-step by
**next-PC prediction**:

1. Decode the instruction at `mepc`.
2. Compute every possible successor PC (fall-through + branch/jump target).
3. Plant "step scratch" breakpoints (last 2 slots in the BP table) at each.
4. Return from the stub (→ `mret`).
5. The CPU executes one instruction and immediately hits one of the scratch
   breakpoints → re-enters the stub.
6. Stub detects re-entry from step (a `stepping` flag), removes the scratch
   BPs, sends `T05` stop-reply.

**Instructions requiring branch-target prediction:**

| Instruction | Successor PCs |
|---|---|
| `JAL` | `pc + J-imm` (always taken) |
| `JALR` | `(g_regs[rs1] + I-imm) & ~1` (always taken) |
| `BEQ/BNE/BLT/BGE/BLTU/BGEU` | `pc + 4` AND `pc + B-imm` (both — don't evaluate condition) |
| `c.j` / `c.jal` | `pc + CJ-imm` |
| `c.jr` / `c.jalr` | `g_regs[rs1]` |
| `c.beqz` / `c.bnez` | `pc + 2` AND `pc + CB-imm` |
| All other instructions | `pc + len` (2 or 4 bytes) |

### 3.8 Async Halt (Ctrl-C)

When the user presses Ctrl-C in GDB, GDB sends a serial break on the
UART line (synthesis) or 0x03 on the TCP socket (Verilator bridge, which
converts it to a simulated UART break). The break detector asserts
`dbg_halt_req`. The CPU traps to `MTVEC_ADDR` (ROM). The stub enters
the RSP loop and sends `T05`. GDB regains control.

---

## 4. Build Flow

```bash
# 1. Compile the stub and generate the ROM Verilog:
python3 scripts/gen_stub_rom.py \
    --rom-base 0x1000 --ram-aw 12 --keep

# 2. Synthesise the debug SoC:
yosys -c syn/syn.tcl   # with SRC="rtl/attorv32_dbg.v rtl/attorv32.v
                        #          rtl/stub_rom.v rtl/hw_bkpt.v rtl/dbg_uart.v"

# 3. Build user firmware (link for the debug address map):
#    RAM: 0x0000–0x0FFF, I/O: 0x2000+
riscv64-unknown-elf-gcc ... -T user.ld -o firmware.elf

# 4. Connect GDB:
#    Send 0x55 calibration byte first (for real UART):
echo -ne '\x55' > /dev/ttyUSB0; sleep 0.1
riscv64-unknown-elf-gdb firmware.elf
(gdb) target remote /dev/ttyUSB0
(gdb) break main
(gdb) continue
(gdb) info registers
(gdb) step
```

---

## 5. Resource Summary

| Item | Cost |
|---|---|
| Core changes | 1 output port (`pc_out`), 1 FF (`dbg_halt_mask`) |
| Stub ROM (combinational) | ~2,300 cells (Sky130) |
| Debug UART (auto-baud + break) | ~200 cells |
| HW breakpoint unit (4 slots) | ~300 cells |
| Break detector (sim) | 4 FFs + ~5 gates |
| RAM (mutable stub data) | ~800 bytes |
| Address space | `ADDR_WIDTH = RAM_AW + 2` (RAM + ROM + I/O) |

---

## 6. Limitations

| Limitation | Workaround |
|---|---|
| No data watchpoints | Not supported. Would need trigger CSRs + comparators. |
| Software breakpoints only in RAM | Use hardware breakpoints (Z1) for ROM/flash code. 4 slots available. |
| Auto-baud requires 0x55 | Host must send calibration byte before GDB connects (see §2.7). |
| Single-step overhead | ~10 µs per step at 72 MHz. Acceptable for interactive debugging. |
| `dbg_halt_req` overwrites mepc | ISR saves mepc immediately. `dbg_halt_mask` prevents re-triggering. |
| 4 hardware breakpoint slots | Sufficient for most interactive debugging. Parameterisable (N in hw_bkpt). |

---

## 7. Verilator GDB Bridge — Workflow

### 7.1 Prerequisites

| Requirement | Tested Version | Notes |
|---|---|---|
| **RISC-V GCC toolchain** | `riscv64-unknown-elf-gcc` | Cross-compiler, assembler, linker, `objcopy`, `objdump` |
| **RISC-V GDB** | `riscv64-elf-gdb` | Your binary name may differ (`riscv64-unknown-elf-gdb`, etc.) |
| **Verilator** | 5.038 | Version 5.x required (`rootp->` signal access, `--public-flat-rw`) |
| **Python 3** | 3.8+ | For `gen_stub_rom.py` (stub compilation) and `gdb_rsp_demo.py` |
| **Make, C++ compiler** | GNU Make, clang/g++ | Verilator compiles a C++ model that must be built |

### 7.2 Build Steps

All commands run from the repository root.

```bash
# Step 1 — Build the Verilator GDB bridge (one command does everything):
bash sim/build_gdb_bridge.sh
```

This script performs three sub-steps automatically:

1. **Generate the stub ROM** (`scripts/gen_stub_rom.py`):
   compiles `sw/crt0_stub.S` + `sw/gdb_stub.c` into a RISC-V ELF,
   extracts the `.text` section, and generates `rtl/stub_rom.v` — a
   combinational Verilog `case` block (~681 words).

2. **Build test firmware** (`sw/dbg_test.c`):
   a minimal counter-loop program that increments `*(0x8)` in a tight
   loop. Compiled to a word-oriented hex file for `$readmemh`.

3. **Verilate + compile**:
   runs `verilator --cc --exe` on the debug SoC (`attorv32_dbg.v` +
   `attorv32.v` + `stub_rom.v` + `hw_bkpt.v` + `tb_dbg_gdb.cpp`),
   then `make` to produce the simulation binary.

Output binary: `build/gdb_bridge/obj_dir/Vattorv32_dbg`

### 7.3 Running a GDB Session

**Terminal 1 — Start the simulation:**

```bash
build/gdb_bridge/obj_dir/Vattorv32_dbg +hex=build/gdb_bridge/fw.hex
```

The simulation prints:

```
[gdb-bridge] Reset released. Running at localhost:3333
[gdb-bridge] Waiting for GDB on localhost:3333 ...
```

It blocks here, waiting for a TCP connection.

**Terminal 2 — Connect GDB:**

```bash
riscv64-elf-gdb build/dbg_test/dbg_test.elf \
    -ex 'target remote localhost:3333'
```

On connect, the bridge triggers a UART break to halt the CPU. GDB
receives a `T05` stop-reply and is ready for interactive debugging.

**Note:** The Verilator bridge uses BENCH mode — it pokes UART registers
directly, bypassing the auto-baud logic. No 0x55 calibration is needed
for simulation.

**Example GDB session:**

```
(gdb) info registers pc sp
pc  0x10   0x10 <_start+16>
sp  0x1000 0x1000

(gdb) x/1xw 0x0008          # Read the counter
0x8:  0x00000000

(gdb) set {int}0x0008 = 0x1000   # Write the counter
(gdb) x/1xw 0x0008
0x8:  0x00001000             # Verified

(gdb) break *0x000E          # Software breakpoint
Breakpoint 1 at 0xe

(gdb) continue               # Resume execution
Breakpoint 1, 0x0000000e in _start ()

(gdb) stepi                  # Single-step
0x00000010 in _start ()

(gdb) hbreak *0x0012         # Hardware breakpoint
Hardware assisted breakpoint 2 at 0x12

(gdb) delete breakpoints
(gdb) continue               # Resume
^C                            # Ctrl-C → async halt
Program received signal SIGINT
(gdb) x/1xw 0x0008
0x8:  0x00015145             # Counter advanced
```

### 7.4 Simulation Plusargs

| Plusarg | Default | Description |
|---|---|---|
| `+hex=<path>` | *(none)* | Word-oriented hex file loaded into RAM via `$readmemh` |
| `+port=<N>` | 3333 | TCP port for GDB RSP |
| `+timeout=<N>` | 100000000 | Maximum simulation cycles before auto-exit |
| `+trace_uart` | off | Print RX/TX byte trace to stderr |

### 7.5 Automated RSP Demo (no GDB required)

A Python script exercises the RSP protocol directly:

```bash
# Terminal 1:
build/gdb_bridge/obj_dir/Vattorv32_dbg +hex=build/gdb_bridge/fw.hex

# Terminal 2:
python3 sim/gdb_rsp_demo.py            # connects to port 3333
python3 sim/gdb_rsp_demo.py 3334       # or specify a different port
```

### 7.6 Iverilog Self-Test (no TCP, no GDB)

For a quick CI-friendly smoke test that requires no external tools
beyond iverilog/vvp:

```bash
bash sim/run_dbg_tb.sh
```

This runs `sim/tb_dbg.v`, which injects RSP packets at the Verilog
level (no sockets) and verifies the stub's responses. Five tests:
initial halt, `?`, `g`, `m`, `c` + re-halt.

---

## 8. Constraints and Known Limitations

### 8.1 Verilator Bridge Write-Back Race

**Constraint:** When poking `uart_rx_data` / `uart_rx_valid` into
the DUT's internal registers from the Verilator C++ testbench, new
bytes must NOT be injected while the CPU is in `S_WAIT` (state 3).

**Cause:** AttoRV32 performs register file write-back during both
`S_EXECUTE` and `S_WAIT`. During `S_WAIT` after a load from
`UART_DATA`, `mem_addr` still points to the UART I/O register.
Changing `uart_rx_data` during `S_WAIT` corrupts `LOAD_data` →
`writeBackData` → the register file is overwritten with the new
byte instead of the byte the CPU actually requested.

**Fix in `tb_dbg_gdb.cpp`:**

```cpp
// Only inject when uart_rx_valid == 0 AND state != S_WAIT (3)
if (!uart_rx_valid
    && state != 3  /* S_WAIT */
    && break_cycles == 0) {
    uart_rx_data  = next_byte;
    uart_rx_valid = 1;
}
```

**Scope:** This constraint applies only to the Verilator testbench's
register-poking approach. Real UART hardware with a proper serdes
does not have this issue.

### 8.2 Software Breakpoints Only in RAM

Breakpoints work by overwriting instructions with `ebreak` /
`c.ebreak`. This only works for code resident in RAM.

**Workaround:** Use hardware breakpoints (`hbreak` in GDB, Z1/z1
packets) for code in ROM or flash. Four slots are available.

### 8.3 Auto-Baud Not GDB-Compatible Out of the Box

GDB RSP sends `$` or `+` as its first byte, not 0x55. The debug
UART will wait in calibration state forever unless the host sends
0x55 first.

**Workaround:** Send `echo -ne '\x55'` to the serial port before
launching GDB, or use a connection wrapper script.

### 8.4 No Data Watchpoints

Hardware watchpoints require trigger comparators (CSRs + address
match logic) that are not implemented. Only code breakpoints are
supported.

### 8.5 No Hardware Single-Step

Single-step is implemented in software by next-PC prediction (§3.7).

### 8.6 `dbg_halt_req` Re-Trigger Prevention

The `dbg_halt_req` signal is level-sensitive. Without protection, it
would re-trigger the trap immediately after `mret`.

**Mechanism:** A 1-FF `dbg_halt_mask` register in the core:
- **Set** when `dbg_halt_req` is accepted.
- **Cleared** on `mret`.
- While set, further `dbg_halt_req` assertions are ignored.

### 8.7 `mepc` Overwrite on Debug Halt

`dbg_halt_req` saves `PC_new` to `mepc`, overwriting any previous value.
The ISR entry saves `mepc` immediately to prevent loss.

### 8.8 `__sp_save` Placement Constraint

The ISR entry saves `sp` using `sw sp, __sp_save(zero)`. The
`__sp_save` variable must be at a RAM address < 0x800. The linker
script places it at address 0x4.

### 8.9 Stub RAM Budget

The stub uses ~800 bytes of RAM for mutable data:

| Item | Size | Notes |
|---|---|---|
| `g_regs[]` (RV32I) | 132 bytes | 33 × 4 bytes (x0–x31 + PC) |
| `g_regs[]` (RV32E) | 68 bytes | 17 × 4 bytes (x0–x15 + PC) |
| Breakpoint table | 120 bytes | 10 slots × 12 bytes |
| `pkt_buf[]` | 280 bytes | RSP packet buffer |
| Stub stack | ~200 bytes | Grows down from top of RAM |
| `stepping` flag | 4 bytes | Single-step state |
| `__sp_save` | 4 bytes | Saved sp during ISR entry |

This is allocated in the upper portion of RAM (STUB_RAM section).
User firmware must not use this region.
