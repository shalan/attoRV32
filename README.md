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
> optional serial shifter / serial multiplier / single-port register file /
> shared adder, and a timing-driven Sky130A synthesis + self-checking testbench.
> Huge thanks to the original FemtoRV32 authors — without their work this core
> would not exist.

---

## Repository layout

```
AttoRV32/
├── rtl/           Verilog source
│   ├── attorv32.v             # the core (+ decompressor)
│   ├── attorv32_ahbl.v        # AHB-Lite master wrapper
│   ├── attorv32_dbg.v         # debug SoC (core + RAM + stub ROM + UART)
│   └── stub_rom.v             # combinational ROM for GDB stub
├── sim/           Simulation
│   ├── tb.v                   # self-checking testbench
│   ├── run_tb.sh              # build firmware + run iverilog sweep
│   ├── tb_dbg.v               # debug facility testbench (iverilog)
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
│   └── summarize.py           # cell-count / area report builder
├── scripts/       Build helpers
│   └── gen_stub_rom.py        # compile stub → Verilog ROM
├── docs/          Documentation
│   └── debug.md               # GDB debug facility specification
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
| Performance CSRs (`rdcycle`, `rdcycleh`) | `` `define NRV_PERF_CSR `` |
| Single-port register file | `` `define NRV_SINGLE_PORT_REGF `` |
| Shared ALU/PC/LSU adder | `` `define NRV_SHARED_ADDER `` |
| Serial 1-bit/cycle shifter | `` `define NRV_SERIAL_SHIFT `` |
| Serial 32-cycle shift-add multiplier | `` `define NRV_SERIAL_MUL `` |
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
| `NRV_PERF_CSR` | Enable 64-bit cycle counter (`rdcycle` / `rdcycleh`) |
| `NRV_SINGLE_PORT_REGF` | Single-read-port regfile (extra cycle for rs2) |
| `NRV_SHARED_ADDER` | One shared 32-bit adder (requires `SINGLE_PORT`) |
| `NRV_SERIAL_SHIFT` | 1-bit/cycle serial shifter (+shamt cycles) |
| `NRV_SERIAL_MUL` | 32-cycle shift-add multiplier (requires `NRV_M`) |

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
- **MRET** restores `PC ← mepc`, clears `mcause` (re-enables IRQ/NMI).
- `mstatus.MIE` is not auto-cleared on trap entry (no MPIE stack). To
  mask IRQs in software: `csrrci mstatus, 8`.

### CSRs

| CSR | Address | Access | Description |
|---|---|---|---|
| `mstatus` | `0x300` | RW | Bit 3 = MIE (machine interrupt enable) |
| `mepc` | `0x341` | RW | Exception program counter |
| `mcause` | `0x342` | RO | Trap cause (RV-standard format) |
| `rdcycle` | `0xC00` | RO | Cycle counter low (requires `NRV_PERF_CSR`) |
| `rdcycleh` | `0xC80` | RO | Cycle counter high (requires `NRV_PERF_CSR`) |

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

## 5. Bus Wrappers

### AHB-Lite (`rtl/attorv32_ahbl.v`)

Single-beat AHB-Lite master. Translates the native `mem_*` handshake into
`HTRANS`/`HADDR`/`HWRITE`/`HSIZE`/`HWDATA`/`HRDATA`/`HREADY`. Derives
`HSIZE` from `mem_wmask` (byte/half/word). Passes through `nmi` and
`dbg_halt_req`.

### Debug SoC (`rtl/attorv32_dbg.v`)

Reference integration for GDB debugging. Instantiates:

- **AttoRV32** core (`MTVEC_ADDR` = ROM base)
- **RAM** (behavioural, byte-writable)
- **Combinational stub ROM** (`rtl/stub_rom.v`) — GDB RSP code in LUT logic
- **UART I/O registers** (TX data, RX data, status)
- **UART break detector** → `dbg_halt_req` (4-bit saturating counter on RX)

Memory map (with `RAM_AW=12`, total `ADDR_WIDTH=13`):

```
0x0000 – 0x0FEF : RAM  (4080 bytes)
0x0FF0 – 0x0FFF : I/O  (UART + control, 16 bytes)
0x1000 – 0x1FFF : stub ROM  (combinational, traps land here)
```

---

## 6. Debug Facility

See [`docs/debug.md`](docs/debug.md) for the full specification.

**Summary:** GDB connects over UART using the Remote Serial Protocol (RSP).
A ~2.5 KiB stub compiled into a combinational ROM handles all debug
operations — halt, continue, single-step, breakpoints, register/memory
read/write — with **zero changes to the core**. The UART break detector
drives `dbg_halt_req` for async halt (GDB Ctrl-C).

| Resource | Cost |
|---|---|
| Core modifications | 1 FF (`dbg_halt_mask` prevents re-triggering) |
| Stub ROM | ~2,300 cells / 13,044 µm² (Sky130, combinational) |
| UART | ~100–200 cells (polled, minimal) |
| UART break detector | 4 FFs + a few gates |
| RAM overhead | ~800 bytes (register frame + BP table + packet buffer + stack) |

**Verified GDB operations:**

| Operation | How |
|---|---|
| Connect + halt | UART break on TCP connect → `T05` stop-reply |
| Register read/write | `info registers`, `set $pc = ...` |
| Memory read/write | `x/...`, `set {int}addr = ...` |
| Software breakpoints | `break *addr` → `ebreak` / `c.ebreak` overwrite |
| Continue | `continue` → `mret` → user code runs |
| Single-step | `stepi` → next-PC prediction + scratch breakpoints |
| Async halt (Ctrl-C) | GDB sends 0x03 → bridge drives UART break → `dbg_halt_req` |

See [`docs/debug.md`](docs/debug.md) §7 for the full workflow
(build instructions, GDB example session, plusargs) and §8 for
constraints and known limitations.

---

## 7. Operation

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
| Multiply (serial) | 3 + 32–33 |
| Divide / Remainder | 3 + 32 |
| Trap entry | 1 |

---

## 8. Synthesis Results — Sky130A

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

---

## 9. Verification

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

## 10. Credits

- **FemtoRV32** and **Gracilis** core design: Bruno Levy, Matthias Koch
  (2020–2021). https://github.com/BrunoLevy/learn-fpga
- AttoRV32 (minimization, serial arithmetic, NMI, debug halt,
  combinational ROM stub, AHB-Lite wrapper, Sky130A flow): 2026.

Licensed under BSD-3-Clause (see `LICENSE`).
