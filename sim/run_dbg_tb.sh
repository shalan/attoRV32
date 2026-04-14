#!/usr/bin/env bash
# run_dbg_tb.sh — build debug test firmware, generate stub ROM, run tb_dbg.v.
#
# Run from the repo root:
#   bash sim/run_dbg_tb.sh
set -eu

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

CROSS="${CROSS:-riscv64-unknown-elf-}"
IVERILOG="${IVERILOG:-iverilog}"
VVP="${VVP:-vvp}"

BUILD="build/dbg_test"
mkdir -p "$BUILD"

RAM_AW=12
RAM_SIZE=$((1 << RAM_AW))
IO_BASE=$((RAM_SIZE - 16))

echo "=== Debug Facility Test ==="
echo

# 1) Compile test firmware (simple counter loop).
echo "--- Building test firmware ---"
cat > "$BUILD/dbg_test.ld" << LDEOF
MEMORY {
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x0BF0
}
ENTRY(_start)
SECTIONS {
    .text 0x0000 : {
        *(.text.start)
        *(.text .text.*)
    } > RAM
    .data : { *(.data .data.*) } > RAM
    .bss (NOLOAD) : { *(.bss .bss.*) } > RAM
    __stack_top = 0x0BF0;
}
LDEOF

${CROSS}gcc -march=rv32ic_zicsr -mabi=ilp32 -Os -ffreestanding \
    -nostdlib -nostartfiles -fno-builtin -fno-pic -mcmodel=medlow \
    -Wl,--no-relax \
    -T "$BUILD/dbg_test.ld" \
    -o "$BUILD/dbg_test.elf" \
    sw/dbg_test.c

${CROSS}objcopy -O binary "$BUILD/dbg_test.elf" "$BUILD/dbg_test.bin"
${CROSS}size "$BUILD/dbg_test.elf"

# Convert to word-oriented hex for $readmemh with 32-bit RAM.
python3 -c "
import struct, sys
with open('$BUILD/dbg_test.bin', 'rb') as f:
    data = f.read()
while len(data) % 4:
    data += b'\x00'
for i in range(0, len(data), 4):
    word = struct.unpack_from('<I', data, i)[0]
    print(f'{word:08X}')
" > "$BUILD/dbg_test.hex"

echo "Firmware hex: $(wc -l < "$BUILD/dbg_test.hex") words"
echo

# 2) Generate stub ROM (if not already up to date).
echo "--- Generating stub ROM ---"
python3 scripts/gen_stub_rom.py --ram-aw $RAM_AW --keep
echo

# 3) Compile testbench.
echo "--- Compiling testbench ---"
$IVERILOG -g2005-sv -DBENCH \
    -o "$BUILD/tb_dbg.vvp" \
    sim/tb_dbg.v rtl/attorv32.v rtl/attorv32_dbg.v rtl/stub_rom.v

# 4) Run simulation.
echo "--- Running simulation ---"
cp "$BUILD/dbg_test.hex" "$BUILD/fw.hex"
$VVP "$BUILD/tb_dbg.vvp" "+hex=$BUILD/fw.hex" "+timeout=2000000"
