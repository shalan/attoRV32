# Debug Facility — Implementation Status

This document tracks the implementation status of the GDB debug facility.

## Component Status

| Component | Status | Notes |
|---|---|---|
| Core `dbg_halt_req` + `dbg_halt_mask` | **Done** | 1-FF re-trigger prevention |
| Core `pc_out` output | **Done** | For hw breakpoint comparators |
| Debug SoC (`attorv32_dbg.v`) | **Done** | Page-aligned decode: RAM/ROM/IO |
| Stub ROM (`stub_rom.v`) | **Done** | Auto-generated, ~681 words |
| ROM generation (`gen_stub_rom.py`) | **Done** | Compiles crt0_stub.S + gdb_stub.c |
| GDB stub (`gdb_stub.c/.h`) | **Done** | Full RSP engine, SW+HW BPs, single-step |
| ISR entry (`crt0_stub.S`) | **Done** | Save/restore all regs + mepc |
| Stub linker script (`stub_link.ld.in`) | **Done** | ROM .text, RAM .data/.bss |
| Debug UART (`dbg_uart.v`) | **Done** | Auto-baud (0x55), 8N1, break detect |
| Hardware breakpoints (`hw_bkpt.v`) | **Done** | 4 PC-match slots, memory-mapped |
| Debug testbench (`tb_dbg.v`) | **Done** | 5 tests: halt, ?, g, m, c — all PASS |
| UART testbench (`tb_dbg_uart.v`) | **Done** | 8 tests: auto-baud, TX, RX, break — all PASS |
| Verilator GDB bridge (`tb_dbg_gdb.cpp`) | **Done** | TCP socket ↔ UART register poke |
| RSP demo script (`gdb_rsp_demo.py`) | **Done** | Exercises RSP without GDB |
| Radix-4 Booth multiplier (`NRV_RADIX4_MUL`) | **Done** | 17-cycle multiply, +9% area |
| Performance CSR `minstret`/`minstreth` | **Done** | Instructions-retired counter (under `NRV_PERF_CSR`) |
| Benchmarks (`bench_compute.c`, `bench_sort.c`) | **Done** | Matmul, TEA, insertion sort, bubble sort |

## Memory Map (RAM_AW=12, ADDR_WIDTH=14)

```
0x0000 – 0x0FFF : RAM  (4 KiB)
0x1000 – 0x1FFF : ROM  (4 KiB, combinational)
0x2000 – 0x2FFF : I/O  (16 slots × 256 bytes)
```

### I/O Slot 0 — System Control (8 sub-slots × 32 bytes)

| Sub-slot | Address | Block | Status |
|---|---|---|---|
| 0 | `0x2000` | UART (DATA, STATUS) | **Done** |
| 1 | `0x2020` | HW breakpoints (CTRL, HIT, COUNT, ADDR[0–3]) | **Done** |
| 2 | `0x2040` | System Timer | TBD |
| 3 | `0x2060` | PIC | TBD |
| 4 | `0x2080` | Clocking | TBD |
| 5 | `0x20A0` | Control ($finish in sim) | **Done** |
| 6–7 | `0x20C0–0x20FF` | *(reserved)* | — |

Slots 1–15 (0x2100–0x2FFF) available for user peripherals.

### CSRs (inside core)

| CSR | Address | Access | Notes |
|---|---|---|---|
| `mstatus` | 0x300 | R/W | Bit 3 = MIE |
| `mepc` | 0x341 | R/W | Exception PC |
| `mcause` | 0x342 | RO | Trap cause + handler lock |
| `mcycle` | 0xC00 | RO | Cycle counter low (requires `NRV_PERF_CSR`) |
| `mcycleh` | 0xC80 | RO | Cycle counter high |
| `minstret` | 0xC02 | RO | Instructions-retired counter low (requires `NRV_PERF_CSR`) |
| `minstreth` | 0xC82 | RO | Instructions-retired counter high |

## Open Items

| Item | Priority | Notes |
|---|---|---|
| Auto-baud GDB compatibility | Medium | GDB doesn't send 0x55. Need host wrapper or alternative calibration. |
| FPGA validation | Medium | Tested in simulation only. Real UART path untested. |
| Flash XiP + breakpoints | Low | Future: code in flash uses hw breakpoints for debugging. |
| Data watchpoints | Low | Would need trigger CSRs + address comparators. |

## Verification Summary

```bash
bash sim/run_tb.sh          # Core self-test: 7 configs → 7/7 PASS
bash sim/run_dbg_tb.sh      # Debug facility: 5 RSP tests → 5/5 PASS
# UART unit test: 8 tests → 8/8 PASS (tb_dbg_uart.v)
```
