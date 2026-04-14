# Debug Facility — Implementation Plan

This document is the step-by-step plan for bringing the GDB debug
facility from its current skeleton state to a working end-to-end GDB
session.

## Current State

| Component | Status |
|---|---|
| Core (`dbg_halt_req`, `nmi` ports + `dbg_halt_mask`) | **Done** |
| Debug SoC wrapper (`attorv32_dbg.v`) | **Done** — address decode, RAM, ROM, UART, break detector |
| Stub ROM module (`stub_rom.v`) | **Done** — auto-generated, 623 words |
| ROM generation script (`gen_stub_rom.py`) | **Done** — compiles crt0_stub.S + gdb_stub.c |
| GDB stub (`gdb_stub.c/.h`) | **Done** — full RSP engine, BP table, `next_pcs()` |
| Stub linker script (`stub_link.ld.in`) | **Done** — stub data at top of RAM |
| ISR hook in `isr.c` | **Done** — `#ifdef GDB_STUB` calls `gdb_stub_entry()` |
| ROM-resident ISR entry (`crt0_stub.S`) | **Done** — saves/restores all regs + mepc |
| RSP packet engine (get/put/dispatch) | **Done** — in gdb_stub.c |
| `next_pcs()` branch decoder | **Done** — full RV32IC coverage |
| Platform UART I/O | **Done** — inline in gdb_stub.c |
| Debug testbench (`tb_dbg.v`) | **Done** — halt, ?, g, m, c all pass |
| End-to-end GDB test | **Not started** (requires UART bridge) |

---

## Phase 1: ROM-Resident ISR Entry

**File:** `sw/crt0_stub.S` (new)

**Goal:** On any trap, save the full register set + mepc into `g_regs[]`,
call `gdb_stub_entry(mcause)`, restore everything, `mret`.

**Tasks:**

1. Define `__sp_save` (1 word in `.bss`) for the bootstrap sp stash.
2. Define `__stub_stack` (256-byte region in `.bss`) and
   `__stub_stack_top` symbol.
3. Write ISR entry (`.section .isr`):
   - Stash `sp` to `__sp_save` via zero-base `sw`.
   - Load `sp ← &g_regs[0]`.
   - Save x1, x3..x31 (RV32I) or x1, x3..x15 (RV32E) by offset.
   - Recover original `sp` from `__sp_save`, save to `g_regs[2]`.
   - `csrr` mepc → save to `g_regs[PC]`.
   - `csrr` mcause → `a0`.
   - Set `sp ← __stub_stack_top`.
   - `call gdb_stub_entry`.
   - Restore mepc from `g_regs[PC]` → `csrw mepc`.
   - Restore all registers from `g_regs[]`.
   - Restore `sp` from `g_regs[2]` last.
   - `mret`.
4. Guard RV32E vs RV32I with `#if __riscv_abi_rve`.

**Test (incremental):** Compile `crt0_stub.S` + a trivial
`gdb_stub_entry()` that immediately returns. Generate ROM. Load a user
program that executes `ebreak`. Verify in simulation that registers are
identical before and after the trap.

**Estimated size:** ~120 lines of assembly, ~200 bytes of machine code.

---

## Phase 2: RSP Packet Engine

**File:** `sw/gdb_stub.c` (fill in skeleton)

### Phase 2a: Hex Utilities (~60 lines)

- `hex_to_nib(char c) → int`
- `nib_to_hex(int v) → char`
- `hex_to_u32(const char **pp) → uint32_t`
- `u32_to_hex(uint32_t v, char *buf) → int`
- `mem_to_hex(const uint8_t *mem, char *buf, int len)`
- `hex_to_mem(const char *buf, uint8_t *mem, int len)`

### Phase 2b: Packet Framing (~80 lines)

- `get_packet(char *buf, int max) → int` — wait for `$`, accumulate to
  `#`, verify checksum, ACK/NAK.
- `put_packet(const char *data)` — send `$`, data, `#`, checksum, wait
  for `+`.

**Test:** Inject `$?#3f` via simulated UART RX. Verify the stub replies
`$T05#b9` on TX.

### Phase 2c: Command Handlers (~250 lines)

Implement in this order (each is independently testable):

1. `?` → `T05`
2. `g` → hex-encode `g_regs[]`
3. `G` → hex-decode into `g_regs[]` → `OK`
4. `m addr,len` → hex-encode memory
5. `M addr,len:data` → hex-decode into memory → `OK`
6. `c [addr]` → set PC if given, return from stub
7. `Z0,addr,kind` → `bp_insert()` → `OK`
8. `z0,addr,kind` → `bp_remove()` → `OK`
9. `s [addr]` → arm step BPs, return from stub (depends on Phase 3)
10. `qSupported` → `PacketSize=200`
11. `qAttached` → `1`
12. `Hg` → `OK`
13. Default → empty packet

### Phase 2d: Main Dispatch Loop (~40 lines)

```c
void gdb_stub_entry(uint32_t cause) {
    if (stepping) { remove_step_bps(); stepping = 0; }
    put_packet("T05");
    for (;;) {
        char buf[280];
        get_packet(buf, sizeof buf);
        switch (buf[0]) {
            case '?': ... break;
            case 'g': ... break;
            ...
            case 'c': ... return;  // mret back to user
            case 's': ... return;  // arm step BPs, mret
        }
    }
}
```

**Actual:** ~600 lines of C, ~2.5 KiB compiled (60% of 4 KiB ROM).

---

## Phase 3: Software Single-Step

**File:** `sw/gdb_stub.c` (fill in `next_pcs()`)

**Tasks:**

1. Write immediate-extraction helpers for J-type, B-type, I-type,
   CJ-type, CB-type formats (~40 lines).
2. Decode 32-bit control-flow instructions: JAL, JALR,
   BEQ/BNE/BLT/BGE/BLTU/BGEU (~30 lines).
3. Decode 16-bit compressed control-flow: c.j, c.jal, c.jr, c.jalr,
   c.beqz, c.bnez (~40 lines).
4. Default: fall-through `pc + len`.

**Test:** Plant a step breakpoint on a known branch instruction. Verify
both successor PCs are correct. Single-step through a small loop.

**Estimated:** ~120 lines of C.

---

## Phase 4: Platform UART I/O

**File:** `sw/gdb_uart.c` (new, ~30 lines) or inline in `gdb_stub.c`.

```c
#define UART_DATA   (*(volatile uint32_t *)(IO_BASE + 0))
#define UART_STATUS (*(volatile uint32_t *)(IO_BASE + 4))

int  gdb_uart_getc(void) {
    while (!(UART_STATUS & 2)) ;
    return UART_DATA & 0xFF;
}
void gdb_uart_putc(int c) {
    while (!(UART_STATUS & 1)) ;
    UART_DATA = (uint8_t)c;
}
```

`IO_BASE` is passed as `-DIO_BASE=0x0FF0` by `gen_stub_rom.py`,
computed from `--ram-aw`.

---

## Phase 5: gen_stub_rom.py Refinement

**File:** `scripts/gen_stub_rom.py`

**Tasks:**

1. Add `crt0_stub.S` to the source list (compile with `$(CC) -c`,
   link first so `.isr` is at ROM entry).
2. Replace the inline linker script with template-substituted
   `stub_link.ld.in` (substitute `@RAM_SIZE@`, `@ROM_BASE@`,
   `@ROM_SIZE@`).
3. Add `gdb_uart.c` to source list (or compile `gdb_stub.c` with
   `-DIO_BASE=...`).
4. Pass `-DIO_BASE=$(( (1 << ram_aw) - 16 ))` to the C compiler.
5. Extract `.isr`, `.text`, and `.rodata` sections into the binary.
6. Error if binary exceeds ROM size.
7. Verify the first bytes are at `ROM_BASE` (not zero).

---

## Phase 6: Stub Linker Script Fix

**File:** `sw/stub_link.ld.in`

**Issue:** The current script places `.data`/`.bss` at RAM origin
(0x0000), which conflicts with the user firmware's reset vector and code.

**Fix:** Place stub `.data`/`.bss` at the top of the RAM region, just
below `IO_BASE`:

```
__stub_data_start = @IO_BASE@ - @STUB_RESERVE@;
.data __stub_data_start : { ... } > RAM
.bss : { ... } > RAM
```

Where `@STUB_RESERVE@` ≈ 512 bytes (g_regs + BPs + stack + RSP buf).

The user firmware's linker script must end its stack before this region:
```
__stack_top = @IO_BASE@ - @STUB_RESERVE@;
```

---

## Phase 7: Debug Testbench

**File:** `sim/tb_dbg.v` (new)

**Approach:** Instantiate `attorv32_dbg`. Inject UART bytes directly
into the module's `uart_rx_data`/`uart_rx_valid` registers using
hierarchical references (avoid bit-level UART timing complexity).

**Test sequence:**

1. Load a simple user program: a loop incrementing a counter in RAM.
2. Let it run 1000 cycles.
3. Assert `uart_rx` low for 20 cycles (simulate UART break → halt).
4. Wait for the stub to enter the RSP loop (detect TX activity or
   wait N cycles).
5. Send `$?#3f` → expect `$T05#b9`.
6. Send `$g#67` → verify register dump is valid hex.
7. Send `$m0000,04#XX` → verify 4-byte memory read matches RAM.
8. Send `$c#63` → verify core resumes user code.
9. Check that the counter in RAM continued incrementing after resume.

**Stretch tests:**

- Plant a breakpoint (`Z0`), continue, verify it halts at the BP.
- Remove the BP (`z0`), continue, verify it runs past.
- Single-step (`s`), verify PC advances by one instruction.

---

## Phase 8: End-to-End GDB Test

**Not automated.** Requires a human with a UART bridge or a
Verilator-based TCP-to-UART adapter.

**Steps:**

1. Build and programme the debug SoC onto an FPGA or run in Verilator.
2. Connect UART to host via USB-serial adapter.
3. Launch GDB:
   ```
   riscv64-unknown-elf-gdb firmware.elf
   (gdb) set remotetimeout 10
   (gdb) target remote /dev/ttyUSB0
   ```
4. Exercise: `break main`, `c`, `info reg`, `x/4x 0`, `step`, `next`,
   `print variable`, `set $a0 = 42`, `continue`.

---

## Critical Path

```
Phase 1 (crt0_stub.S)
    │
    ▼
Phase 2a–2b (hex + framing)
    │
    ▼
Phase 4 (UART I/O)  ──┐
    │                   │
    ▼                   ▼
Phase 5 (gen_stub_rom.py)
    │
    ▼
Phase 7 (testbench: ?, g, m, c)   ← first end-to-end validation
    │
    ▼
Phase 2c (remaining handlers: G, M, Z0, z0)
    │
    ▼
Phase 3 (next_pcs → single-step)
    │
    ▼
Phase 7+ (testbench: step, breakpoint tests)
    │
    ▼
Phase 8 (real GDB)
```

Phase 6 (linker fix) is on the side — needed before Phase 5 but
independent of the RSP engine.

---

## Integration Risks

| Risk | Mitigation |
|---|---|
| `dbg_halt_req` re-triggers before first ROM instruction | **Solved:** 1-FF `dbg_halt_mask` in the core; set on acceptance, cleared on mret. |
| Stub stack overlaps user data | Separate `__stub_stack` region in linker. Verify with `size` output. |
| ROM too small for stub code | `gen_stub_rom.py` errors if binary > ROM_SIZE. Actual: 2.5 KiB code in 4 KiB ROM = 40% headroom. |
| `g_regs[]` / user data conflict | Place stub .data/.bss at top of RAM (below IO). User firmware avoids that region via `__stub_reserve`. |
| JALR target unknown at step time | Read `rs1` from `g_regs[]` — correct because regs were saved at trap point. |
| GDB sends unknown packets | Reply empty packet. GDB handles this gracefully. |
| Checksum mismatch / noise | NAK (`-`) and retry. Standard RSP recovery. |

---

## Estimated Effort

| Phase | New Code | Effort |
|---|---|---|
| 1. crt0_stub.S | ~120 lines asm | 1–2 hours |
| 2. RSP engine | ~450 lines C | 4–6 hours |
| 3. next_pcs() | ~120 lines C | 1–2 hours |
| 4. UART I/O | ~30 lines C | 15 minutes |
| 5. gen_stub_rom.py | ~40 lines diff | 1 hour |
| 6. Linker fix | ~10 lines diff | 15 minutes |
| 7. Testbench | ~200 lines Verilog | 2–3 hours |
| 8. Real GDB test | — | 1–2 hours |
| **Total** | **~970 lines** | **~12 hours** |
