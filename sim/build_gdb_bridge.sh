#!/usr/bin/env bash
# build_gdb_bridge.sh — Build the Verilator GDB bridge for AttoRV32 debug.
#
# Usage (from repo root):
#   bash sim/build_gdb_bridge.sh          # build only
#   bash sim/build_gdb_bridge.sh run      # build + run
#
# Then in another terminal:
#   riscv64-elf-gdb -ex 'target remote localhost:3333' build/dbg_test/dbg_test.elf
set -eu

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

BUILD="build/gdb_bridge"
mkdir -p "$BUILD"

# 1) Generate stub ROM if needed.
if [ ! -f rtl/stub_rom.v ] || [ scripts/gen_stub_rom.py -nt rtl/stub_rom.v ]; then
    echo "--- Generating stub ROM ---"
    python3 scripts/gen_stub_rom.py --ram-aw 12 --keep
    echo
fi

# 2) Build test firmware if needed.
if [ ! -f "$BUILD/fw.hex" ]; then
    echo "--- Building test firmware ---"
    bash sim/run_dbg_tb.sh 2>&1 | head -10
    cp build/dbg_test/fw.hex "$BUILD/fw.hex"
    echo
fi

# 3) Verilate + compile.
echo "--- Verilating ---"
verilator --cc --exe \
    -DBENCH \
    -Wno-fatal \
    --public-flat-rw \
    --top-module attorv32_dbg \
    --Mdir "$BUILD/obj_dir" \
    -o Vattorv32_dbg \
    rtl/attorv32.v rtl/attorv32_dbg.v rtl/stub_rom.v \
    sim/tb_dbg_gdb.cpp

echo "--- Compiling ---"
make -j$(sysctl -n hw.ncpu 2>/dev/null || nproc) -C "$BUILD/obj_dir" -f Vattorv32_dbg.mk

echo
echo "--- Build complete ---"
echo "Binary: $BUILD/obj_dir/Vattorv32_dbg"
echo
echo "To run:"
echo "  $BUILD/obj_dir/Vattorv32_dbg +hex=$BUILD/fw.hex"
echo
echo "Then in another terminal:"
echo "  riscv64-elf-gdb build/dbg_test/dbg_test.elf \\"
echo "    -ex 'target remote localhost:3333'"

if [ "${1:-}" = "run" ]; then
    echo
    echo "--- Starting simulation ---"
    exec "$BUILD/obj_dir/Vattorv32_dbg" "+hex=$BUILD/fw.hex"
fi
