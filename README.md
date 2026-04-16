# AttoRV32

A heavily-minimized, parameterized RV32 core targeting ASIC implementation on
small technologies (Sky130A and similar). The C (compressed) extension and
interrupts are always on; everything else — including the M extension, SRA,
performance CSRs, single-port register file, and serial arithmetic units — is
guarded by `` `define `` options.

Niche: deeply-embedded controllers, IP blocks inside a larger SoC, educational
cores. Not a performance part.

> **Inspired by / derived from FemtoRV32.**
> AttoRV32 started from Bruno Levy and Matthias Koch's
> [FemtoRV32 "Gracilis"](https://github.com/BrunoLevy/learn-fpga/tree/master/FemtoRV)
> core, then was stripped down, re-parameterized, and re-plumbed for small-ASIC
> flows: hardcoded `mtvec`, non-sticky external IRQ, NMI, debug halt input,
> optional serial shifter / serial multiplier (radix-2 or radix-4 Booth) /
> single-port register file / shared adder, performance counters
> (`mcycle` + `minstret`), a GDB-over-UART debug facility, and a
> timing-driven Sky130A synthesis + self-checking testbench.
> Huge thanks to the original FemtoRV32 authors — without their work this core
> would not exist.

---

## Repository layout

```
AttoRV32/
├── rtl/           Verilog source
│   ├── attorv32.v             # the core (+ decompressor)
│   ├── attorv32_ahbl.v        # AHB-Lite master wrapper
│   ├── attorv32_dbg.v         # debug SoC (core + RAM + stub ROM + UART + bkpt)
│   ├── dbg_uart.v             # debug UART (auto-baud 0x55, 8N1, break detect)
│   ├── hw_bkpt.v              # hardware breakpoint unit (4 PC comparators)
│   └── stub_rom.v             # combinational ROM for GDB stub (auto-generated)
├── sim/           Simulation
│   ├── tb.v                   # self-checking testbench
│   ├── run_tb.sh              # build firmware + run iverilog sweep
│   ├── tb_dbg.v               # debug facility testbench (iverilog)
│   ├── tb_dbg_uart.v          # debug UART testbench (auto-baud, TX/RX, break)
│   ├── run_dbg_tb.sh          # build debug firmware + run tb_dbg.v
│   ├── tb_dbg_gdb.cpp         # Verilator GDB bridge (TCP ↔ UART)
│   ├── build_gdb_bridge.sh    # build the Verilator GDB bridge
│   └── gdb_rsp_demo.py        # scripted RSP demo (no GDB required)
├── sw/            Bare-metal firmware
│   ├── Makefile
│   ├── crt0.S                 # reset + ISR entry
│   ├── isr.c                  # default IRQ / EBREAK handlers
│   ├── link.ld.in             # linker template (RAM size substituted)
│   ├── main.c                 # minimal blinker example
│   ├── selftest.c             # self-checking firmware (used by tb)
│   ├── bench_compute.c        # matmul + TEA benchmark (CPI measurement)
│   ├── bench_sort.c           # insertion + bubble sort benchmark
│   ├── gdb_stub.h             # GDB RSP stub header
│   ├── gdb_stub.c             # GDB RSP stub (~600 lines, full implementation)
│   ├── crt0_stub.S            # ISR entry: save regs → g_regs[], call stub, restore, mret
│   ├── dbg_test.c             # Minimal counter-loop firmware for debug testing
│   └── stub_link.ld.in        # linker template for ROM-resident stub
├── syn/           Sky130A synthesis
│   ├── run_syn.sh             # config sweep driver
│   ├── syn.tcl                # Yosys flow (timing-driven ABC)
│   ├── sta.tcl                # OpenSTA WNS measurement
│   ├── abc_timing.script      # ABC mapping template ({D} = period ps)
│   ├── abc_area.script        # ABC area-optimized recipe
│   ├── abc_delay.script       # ABC delay-optimized recipe
│   ├── abc_resyn2.script      # ABC resyn2 recipe
│   ├── abc_default.script     # ABC default recipe (best area overall)
│   ├── compare_abc.sh         # ABC recipe comparison on a single config
│   ├── compare_emc.sh         # RV32EMC config × ABC recipe comparison
│   └── summarize.py           # cell-count / area report builder
├── scripts/       Build helpers
│   └── gen_stub_rom.py        # compile stub → Verilog ROM
├── docs/          Documentation
│   ├── debug.md               # GDB debug facility specification
│   └── debug-impl-plan.md     # debug facility implementation status
├── LICENSE
└── README.md
```

All scripts are designed to be run from the repo root. Generated artefacts
land in `build/` and are ignored by git.

### Quick start

```bash
# Self-check sweep (iverilog + vvp required)
bash sim/run_tb.sh

# Debug facility smoke test (iverilog)
bash sim/run_dbg_tb.sh

# GDB debugging session (Verilator + RISC-V toolchain required)
bash sim/build_gdb_bridge.sh run     # Terminal 1: start simulation
riscv64-elf-gdb build/dbg_test/dbg_test.elf \
    -ex 'target remote localhost:3333'  # Terminal 2: connect GDB

# Synthesis sweep (yosys + Sky130A .lib required)
bash syn/run_syn.sh
```

---

## 1. Features

| Feature | Status |
|---|---|
| RV32 base (I or E) | Parameter `RV32E` |
| C (compressed) extension | Always on |
| M (mul/div/rem) extension | `` `define NRV_M `` |
| SRA / SRAI | `` `define NRV_SRA `` |
| Performance CSRs (`rdcycle`, `rdinstret` + high halves) | `` `define NRV_PERF_CSR `` |
| Single-port register file | `` `define NRV_SINGLE_PORT_REGF `` |
| Shared ALU/PC/LSU adder | `` `define NRV_SHARED_ADDER `` |
| Serial 1-bit/cycle shifter | `` `define NRV_SERIAL_SHIFT `` |
| Serial 32-cycle shift-add multiplier | `` `define NRV_SERIAL_MUL `` |
| Radix-4 modified Booth multiplier (17 cycles) | `` `define NRV_RADIX4_MUL `` |
| External interrupt (maskable, non-sticky) | Always on |
| NMI (non-maskable interrupt) | Always on |
| Debug halt (bypasses MIE + mcause) | Always on |
| Proper EBREAK / ECALL trap, RV-standard `mcause` | Always on |
| CSRs | `mstatus` (rw), `mepc` (rw), `mcause` (ro) |
| `mtvec` | Hardcoded via `MTVEC_ADDR` parameter |
| Reset vector | `0x00000000` (hardcoded) |
| Data path | 32-bit |
| Memory interface | 32-bit, word-aligned, byte-enable store mask |

---

## 2. Parameters and Defines

### Verilog parameters

| Parameter | Range | Default | Description |
|---|---|---|---|
| `ADDR_WIDTH` | 8..16 | 12 | Address bus width → `2^ADDR_WIDTH` byte space |
| `RV32E` | 0 / 1 | 0 | 0 = 32 registers (RV32I), 1 = 16 registers (RV32E) |
| `MTVEC_ADDR` | any | `'h10` | Hardware interrupt/trap vector address |

### Compile-time defines

| Define | Effect |
|---|---|
| `NRV_M` | Enable M extension (MUL/DIV/REM/MULH*) |
| `NRV_SRA` | Enable arithmetic right shift (SRA/SRAI) |
| `NRV_PERF_CSR` | 64-bit cycle + instruction-retired counters |
| `NRV_SINGLE_PORT_REGF` | Single-read-port regfile (extra cycle for rs2) |
| `NRV_SHARED_ADDER` | One shared 32-bit adder (requires `SINGLE_PORT`) |
| `NRV_SERIAL_SHIFT` | 1-bit/cycle serial shifter (+shamt cycles) |
| `NRV_SERIAL_MUL` | 32-cycle shift-add multiplier (requires `NRV_M`) |
| `NRV_RADIX4_MUL` | Radix-4 modified Booth: 17-cycle multiply (requires `NRV_SERIAL_MUL`) |

---

## 3. Trap Architecture

### Trap sources

| Source | Gated by MIE? | Gated by mcause? | `mcause` | mepc saves |
|---|---|---|---|---|
| External IRQ (`interrupt_request`) | Yes | Yes | `0x8000_000B` | PC_new (next instr) |
| NMI (`nmi`) | **No** | Yes | `0x8000_0000` | PC_new (next instr) |
| Debug halt (`dbg_halt_req`) | **No** | **No** | `0x0000_0003` | PC_new (next instr) |
| EBREAK / c.ebreak | N/A | Yes | `0x0000_0003` | PC (trapping instr) |
| ECALL | N/A | Yes | `0x0000_000B` | PC (trapping instr) |

**Priority** (highest first): `dbg_halt_req` > `nmi` > `interrupt_request` > EBREAK/ECALL.

All traps vector to `MTVEC_ADDR`. The ISR reads `mcause` to dispatch.

### Key semantics

- **External IRQ** is non-sticky: the source must hold the line high until
  the CPU accepts it. Gated by `mstatus.MIE` and `mcause` (no nesting).
- **NMI** bypasses `mstatus.MIE` but is blocked by `mcause=1` (will not
  nest into an active handler). Use for watchdog, power-fail, safety faults.
- **`dbg_halt_req`** bypasses **both** MIE and mcause — can halt the CPU
  at any time, even inside an ISR with interrupts disabled. Reports
  `mcause=3` (same as EBREAK) so a GDB stub handles it transparently.
  Drive from a UART break detector for GDB Ctrl-C support.
- **WFI** stalls the pipeline in S_EXECUTE until a wake event
  (`interrupt_request | nmi | dbg_halt_req`). Wake is ungated by MIE —
  per RISC-V spec, WFI must wake on any pending interrupt even when
  interrupts are disabled. If the interrupt isn't actually accepted,
  execution continues past WFI. For async traps during WFI, `mepc`
  captures WFI+4 so the handler returns *past* the WFI instruction.
  Cost: 3 cycles + stall wait. `minstret` does not tick during stall.
- **MRET** restores `PC ← mepc`, clears `mcause` (re-enables IRQ/NMI).
- `mstatus.MIE` is not auto-cleared on trap entry (no MPIE stack). To
  mask IRQs in software: `csrrci mstatus, 8`.

### CSRs

| CSR | Address | Access | Description |
|---|---|---|---|
| `mstatus` | `0x300` | RW | Bit 3 = MIE (machine interrupt enable) |
| `mepc` | `0x341` | RW | Exception program counter |
| `mcause` | `0x342` | RO | Trap cause (RV-standard format) |
| `mcycle` | `0xC00` | RO | Cycle counter low (requires `NRV_PERF_CSR`) |
| `mcycleh` | `0xC80` | RO | Cycle counter high (requires `NRV_PERF_CSR`) |
| `minstret` | `0xC02` | RO | Instructions-retired counter low (requires `NRV_PERF_CSR`) |
| `minstreth` | `0xC82` | RO | Instructions-retired counter high (requires `NRV_PERF_CSR`) |

---

## 4. Port Map

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | System clock |
| `reset` | in | 1 | Active-low synchronous reset |
| `mem_addr` | out | 32 | Memory address (`ADDR_WIDTH` LSBs significant) |
| `mem_wdata` | out | 32 | Write data (byte-lane replicated for B/H stores) |
| `mem_wmask` | out | 4 | Byte-enable store mask (0 when not storing) |
| `mem_rdata` | in | 32 | Read data (instructions and data share this bus) |
| `mem_rstrb` | out | 1 | Read strobe (high during fetch and load) |
| `mem_rbusy` | in | 1 | Memory stall — read path |
| `mem_wbusy` | in | 1 | Memory stall — write path |
| `interrupt_request` | in | 1 | Maskable external interrupt (level, non-sticky) |
| `nmi` | in | 1 | Non-maskable interrupt (level) |
| `dbg_halt_req` | in | 1 | Debug halt request (level, highest priority) |
| `pc_out` | out | `ADDR_WIDTH` | Current PC (feeds HW breakpoint comparators) |

### Instantiation example

```verilog
AttoRV32 #(
    .ADDR_WIDTH (12),
    .RV32E      (0),
    .MTVEC_ADDR (12'h010)
) u_cpu (
    .clk               (clk),
    .reset             (rst_n),          // active LOW
    .mem_addr          (mem_addr),
    .mem_wdata         (mem_wdata),
    .mem_wmask         (mem_wmask),
    .mem_rdata         (mem_rdata),
    .mem_rstrb         (mem_rstrb),
    .mem_rbusy         (mem_rbusy),
    .mem_wbusy         (mem_wbusy),
    .interrupt_request (irq),
    .nmi               (nmi),
    .dbg_halt_req      (dbg_halt)
);
```

---

## 5. Memory Map

Two reference memory layouts ship with the repo: the **standalone firmware**
layout used by `sim/tb.v` and all `sw/` firmware (selftest, main, benchmarks),
and the **debug SoC** layout used by `rtl/attorv32_dbg.v`. They are
independent — a given build uses one or the other.

### 5.1 Standalone firmware (`sim/tb.v` + `sw/link.ld.in`)

Single flat RAM of `2^ADDR_WIDTH` bytes (default 4 KiB at `ADDR_WIDTH=12`).
Code and data share the space. The top 16 bytes are reserved for
memory-mapped I/O decoded by the testbench.

```
0x0000           .reset     Reset trampoline (<= 16 bytes)
0x0010           .isr       ISR entry (matches MTVEC_ADDR = 0x10)
0x0014 ...       .text      Program code (.rodata, .data, .bss follow)
 ...
RAM_END - 16     IO_DONE    Write any -> $finish (0 = PASS, !0 = FAIL)
RAM_END - 12     IO_DEBUG   Write low byte -> character to $write (printf)
RAM_END -  8     IO_IRQ_STS Read: pending IRQ status
RAM_END -  4     IO_IRQ_CLR Write: clear IRQ + IRQ source
RAM_END          __ram_end  (stack grows down from IO_DONE)
```

The linker exports `__ram_end`; firmware derives MMIO addresses as
`__ram_end - 16/12/8/4`. See `sw/bench_compute.c` and `sw/selftest.c` for
typical usage. `MTVEC_ADDR = 0x010` is hardcoded so `crt0.S` can place the
trap handler at a known address without relocation.

### 5.2 Debug SoC (`rtl/attorv32_dbg.v`)

Page-aligned split RAM / ROM / I/O, decoded from `mem_addr[15:12]`. Default
`RAM_AW = 12` (4 KiB each of RAM and ROM) gives `ADDR_WIDTH = 14`.

```
0x0000 - 0x0FFF : RAM  (4 KiB - synchronous SRAM, reset vector here)
0x1000 - 0x1FFF : ROM  (4 KiB - combinational GDB stub, MTVEC_ADDR here)
0x2000 - 0x2FFF : I/O  (16 peripheral slots x 256 bytes)
```

I/O slot 0 (0x2000 – 0x20FF) — **System Control** (8 sub-slots × 32 bytes,
decoded from `mem_addr[7:5]`; 8 word registers per sub-slot via
`mem_addr[4:2]`):

| Sub-slot | Address | Block | Registers |
|---|---|---|---|
| 0 | `0x2000` | UART | `DATA` (reg 0), `STATUS` (reg 1: `{LOCKED, RX_VALID, TX_READY}`) |
| 1 | `0x2020` | HW breakpoints | `BP_CTRL`, `BP_HIT`, `BP_COUNT`, `BP_ADDR[0..3]` |
| 2 | `0x2040` | System Timer | *(TBD)* |
| 3 | `0x2060` | PIC | *(TBD)* |
| 4 | `0x2080` | Clocking | *(TBD)* |
| 5 | `0x20A0` | Control | write `CTRL` → `$finish` (simulation only) |
| 6–7 | `0x20C0–0x20FF` | *(reserved)* | — |

I/O slots 1–15 (`0x2100–0x2FFF`) are free for user peripherals.

---

## 6. Bus Wrappers

### AHB-Lite (`rtl/attorv32_ahbl.v`)

Single-beat AHB-Lite master. Translates the native `mem_*` handshake into
`HTRANS`/`HADDR`/`HWRITE`/`HSIZE`/`HWDATA`/`HRDATA`/`HREADY`. Derives
`HSIZE` from `mem_wmask` (byte/half/word). Passes through `nmi` and
`dbg_halt_req`.

### Debug SoC (`rtl/attorv32_dbg.v`)

Reference integration for GDB debugging. Instantiates:

- **AttoRV32** core (`MTVEC_ADDR` = ROM base, `pc_out` for breakpoints)
- **RAM** (synchronous read/write, maps to real SRAM)
- **Combinational stub ROM** (`rtl/stub_rom.v`) — GDB RSP code in LUT logic
- **Debug UART** (`rtl/dbg_uart.v`) — auto-baud (0x55), 8N1, break detection
- **Hardware breakpoints** (`rtl/hw_bkpt.v`) — 4 PC-match comparators
- **UART break detector** → `dbg_halt_req` (4-bit counter in sim, 12-bit-period in synthesis)

Memory map and register layout: see Section 5.2.

---

## 7. Debug Facility

See [`docs/debug.md`](docs/debug.md) for the full specification.

**Summary:** GDB connects over UART using the Remote Serial Protocol (RSP).
A ~2.7 KiB stub compiled into a combinational ROM handles all debug
operations — halt, continue, single-step, software + hardware breakpoints,
register/memory read/write. The core adds one output port (`pc_out`) and
one FF (`dbg_halt_mask`).

| Resource | Cost |
|---|---|
| Core modifications | 1 output port (`pc_out`), 1 FF (`dbg_halt_mask`) |
| Stub ROM | ~2,300 cells (Sky130, combinational) |
| Debug UART (auto-baud + break) | ~200 cells |
| HW breakpoint unit (4 slots) | ~300 cells |
| RAM overhead | ~800 bytes (register frame + BP table + packet buffer + stack) |

**Verified GDB operations:**

| Operation | How |
|---|---|
| Connect + halt | UART break on TCP connect → `T05` stop-reply |
| Register read/write | `info registers`, `set $pc = ...` |
| Memory read/write | `x/...`, `set {int}addr = ...` |
| Software breakpoints | `break *addr` → `ebreak` / `c.ebreak` overwrite (RAM only) |
| Hardware breakpoints | `hbreak *addr` → hw_bkpt PC comparator (ROM/flash too) |
| Continue | `continue` → `mret` → user code runs |
| Single-step | `stepi` → next-PC prediction + scratch breakpoints |
| Async halt (Ctrl-C) | GDB sends 0x03 → bridge drives UART break → `dbg_halt_req` |

See [`docs/debug.md`](docs/debug.md) for the full specification,
build workflow, GDB example session, and known limitations.

---

## 8. Operation

### 7.1 State machine

4-state (default) or 5-state (with `NRV_SINGLE_PORT_REGF`), binary-encoded:

```
FETCH_INSTR → WAIT_INSTR → [FETCH_RS2] → EXECUTE → (WAIT | WAIT_INSTR | FETCH_INSTR)
                                           ↑__________________________|
```

### 7.2 Cycle cost per instruction class (zero-wait memory)

| Class | Cycles |
|---|---:|
| ALU / branch / JAL / JALR / CSR / LUI / AUIPC | 3 |
| + single-port rs2 detour (STORE / BRANCH / ALUreg) | +1 |
| Load | 4 (+ memory waits) |
| Store | 4 (+ memory waits) |
| Shift (barrel) | 3 |
| Shift (serial) | 3 + shamt |
| Multiply (parallel) | 3 |
| Multiply (serial, radix-2) | 3 + 32–33 |
| Multiply (serial, radix-4 Booth) | 3 + 17–18 |
| Divide / Remainder | 3 + 32 |
| WFI | 3 + wait (stalls until IRQ/NMI/dbg_halt) |
| Trap entry | 1 |

---

## 9. Synthesis Results — Sky130A

Synthesized with **yosys 0.57** + a custom timing-driven ABC script (see
`syn/abc_timing.script`) against `sky130_fd_sc_hd__tt_025C_1v80`. Target
period 14 ns, I/O delay 3 ns. STA with **OpenSTA 2.6.0**. All
configurations meet timing with ≥ 5.28 ns slack. Numbers are **pre-PnR**.

Sorted by cell count:

| Config | Cells | FFs | Area (µm²) | Max path (ns) | WNS (ns) | Description |
|---|---:|---:|---:|---:|---:|---|
| rv32ec_min_1p_aw12 | 4,979 | 684 | 39,047 | 3.79 | +7.22 | RV32EC + single-port regf |
| rv32ec_min_1p_sa_aw12 | 5,117 | 684 | 39,106 | 5.03 | +5.97 | + shared adder |
| rv32ec_min_aw8 | 5,777 | 671 | 42,283 | 3.64 | +7.36 | RV32EC, 256 B |
| rv32ec_min_ss_aw12 | 5,883 | 721 | 44,057 | 3.56 | +7.44 | + serial shifter |
| rv32ec_min_aw12 | 6,167 | 683 | 44,096 | 3.56 | +7.44 | RV32EC baseline |
| rv32ic_min_1p_aw12 | 6,783 | 1,196 | 59,575 | 5.03 | +5.97 | RV32IC + 1p regf |
| **rv32ec_tiny_aw12** | **7,556** | **1,017** | **55,987** | **5.48** | **+5.52** | **smallest M core** |
| rv32ic_min_aw12 | 9,440 | 1,195 | 71,161 | 3.70 | +7.30 | RV32IC baseline |
| rv32ic_m_aw12 | 20,159 | 1,386 | 124,270 | 4.85 | +6.15 | RV32IMC full |
| rv32ic_full_aw12 | 20,605 | 1,450 | 126,804 | 5.02 | +5.98 | + SRA + perf CSRs |

*(Full 25-config table available via `bash syn/run_syn.sh`.)*

### RV32EMC configs (`syn/compare_emc.sh`)

Four canonical RV32EMC configurations, all with `NRV_SRA`, `NRV_SINGLE_PORT_REGF`,
`NRV_SHARED_ADDER`. Synthesized with `abc_default.script`. Sky130 HD, AW=12.

| Config | Description | Cells | FFs | Area (µm²) |
|---|---|---:|---:|---:|
| A | parallel mul + parallel shift | 10,946 | 889 | 87,250 |
| **B** | **serial mul + parallel shift** | **5,831** | **993** | **54,390** |
| C | parallel mul + serial shift | 10,653 | 928 | 87,021 |
| D | serial mul + serial shift | 5,496 | 1,032 | 54,117 |

### Radix-2 vs Radix-4 Booth multiplier (`syn/compare_abc.sh`)

Config B variant (serial mul + parallel shift), RV32EMC, AW=12, `abc_default.script`:

| Multiplier | Cycles / mul | Cells | FFs | Area (µm²) | Δ vs R2 |
|---|---:|---:|---:|---:|---|
| Radix-2 (`NRV_SERIAL_MUL`) | 32–33 | 5,831 | 993 | 54,390 | — |
| Radix-4 Booth (`+NRV_RADIX4_MUL`) | 17–18 | 6,297 | 1,028 | 59,181 | +466 cells, +4,791 µm² (+8.8%) |

Radix-4 Booth nets ~1.27× speedup on multiply-heavy workloads (see Section 11)
for ~9% extra area on a Config-B base.

---

## 10. Verification

```bash
bash sim/run_tb.sh        # 7 configs, ~10k cycles each → 7/7 PASS
bash sim/run_dbg_tb.sh    # debug facility: 5 RSP tests → 5/5 PASS
```

The selftest firmware (`sw/selftest.c`) covers: integer ALU, shifts
(barrel + serial), SRA, branches, loads/stores, M-extension
(MUL/MULH/DIV/REM corner cases), EBREAK trap, external IRQ.

The debug testbench (`sim/tb_dbg.v`) covers: UART break halt,
`?` stop-reason query, `g` register read, `m` memory read,
`c` continue + re-halt. Runs under iverilog with no external
dependencies.

For interactive GDB testing (Verilator + RISC-V GDB):

```bash
bash sim/build_gdb_bridge.sh run        # Terminal 1
riscv64-elf-gdb build/dbg_test/dbg_test.elf \
    -ex 'target remote localhost:3333'   # Terminal 2
```

---

## 11. Benchmarks

CPI (Cycles Per Instruction) measured on **Config B**: RV32EMC, serial mul,
parallel shift, single-port regfile, shared adder, SRA (`NRV_M NRV_SRA
NRV_SINGLE_PORT_REGF NRV_SHARED_ADDER NRV_SERIAL_MUL`). RV32E=1, AW=12.
IRQs disabled during measurement.  Requires `NRV_PERF_CSR` for
`mcycle`/`minstret` counters.

### Radix-2 (32-cycle serial mul) vs Radix-4 Booth (17-cycle mul)

| Benchmark | Instructions | R2 Cycles | R2 CPI | R4 Cycles | R4 CPI | Speedup |
|---|---:|---:|---:|---:|---:|---:|
| 4×4 matmul ×10 | 6,673 | 45,170 | 6.77 | 35,570 | 5.33 | 1.27× |
| TEA encrypt ×16 blocks | 9,796 | 35,523 | 3.63 | 35,523 | 3.63 | — |
| Insertion sort 32×5 | 11,199 | 43,372 | 3.87 | 43,372 | 3.87 | — |
| Bubble sort 32×5 | 20,869 | 77,177 | 3.70 | 77,177 | 3.70 | — |

**Observations:**

- **Baseline CPI ≈ 3.7** reflects multi-cycle overhead: single-port regfile
  (+1 cycle for rs2), shared adder, and multi-cycle loads/stores.
- **Matmul CPI = 5.33** (R4) is highest due to multiply-heavy inner loop;
  radix-4 Booth cuts 9,600 cycles (1.27× speedup) vs radix-2.
- **TEA/sort** have no MUL instructions — identical on both multipliers.
- **Radix-4 Booth area cost:** +466 cells / +4,800 µm² (~9%) on Sky130 HD.

Build and run:

```bash
# Build benchmarks
make -C sw clean && make -C sw BENCH_COMPUTE=1 ADDR_WIDTH=12 RV32E=1 HAVE_M=1
make -C sw clean && make -C sw BENCH_SORT=1    ADDR_WIDTH=12 RV32E=1 HAVE_M=1

# Simulate (add NRV_PERF_CSR for cycle/instret counters)
iverilog -g2005-sv -DBENCH -DNRV_M -DNRV_SRA -DNRV_SINGLE_PORT_REGF \
    -DNRV_SHARED_ADDER -DNRV_SERIAL_MUL -DNRV_RADIX4_MUL -DNRV_PERF_CSR \
    -Ptb.ADDR_WIDTH=12 -Ptb.RV32E=1 \
    -o build/sim/bench.vvp sim/tb.v rtl/attorv32.v
vvp build/sim/bench.vvp +hex=sw/bench_compute.hex +timeout=2000000
vvp build/sim/bench.vvp +hex=sw/bench_sort.hex    +timeout=2000000
```

---

## 12. Credits

- **FemtoRV32** and **Gracilis** core design: Bruno Levy, Matthias Koch
  (2020–2021). https://github.com/BrunoLevy/learn-fpga
- AttoRV32 (minimization, serial arithmetic, NMI, debug halt,
  combinational ROM stub, AHB-Lite wrapper, Sky130A flow): 2026.

Licensed under BSD-3-Clause (see `LICENSE`).
