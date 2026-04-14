#!/usr/bin/env bash
# run_syn.sh — synthesize AttoRV32 in several configurations (Sky130A).
# Run from the repo root:  bash syn/run_syn.sh
set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PDK="${PDK:-/Users/mshalan/work/pdks/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af/sky130A}"
export LIB="${LIB:-$PDK/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib}"
export SRC="rtl/attorv32.v"
export TOP="AttoRV32"
# ABC recipe: override via ABC_SCRIPT env or --abc flag.
# Available: abc_timing.script (default), abc_area.script, abc_delay.script, abc_resyn2.script
export ABC_SCRIPT="${ABC_SCRIPT:-syn/abc_timing.script}"
export BUILD_DIR="build/syn"
export LOG_DIR="build/logs"

mkdir -p "$BUILD_DIR" "$LOG_DIR"

# Configurations: name | ADDR_WIDTH | RV32E | DEFS
CFGS=(
    "rv32ec_min_aw8       8  1 "
    "rv32ec_min_aw12     12  1 "
    "rv32ic_min_aw12     12  0 "
    "rv32ec_m_aw12       12  1 -DNRV_M"
    "rv32ic_m_aw12       12  0 -DNRV_M"
    "rv32ic_m_sra_aw12   12  0 -DNRV_M -DNRV_SRA"
    "rv32ic_full_aw12    12  0 -DNRV_M -DNRV_SRA -DNRV_PERF_CSR"
    "rv32ec_min_1p_aw12  12  1 -DNRV_SINGLE_PORT_REGF"
    "rv32ic_min_1p_aw12  12  0 -DNRV_SINGLE_PORT_REGF"
    "rv32ec_m_1p_aw12    12  1 -DNRV_M -DNRV_SINGLE_PORT_REGF"
    "rv32ic_m_1p_aw12    12  0 -DNRV_M -DNRV_SINGLE_PORT_REGF"
    "rv32ec_min_1p_sa_aw12 12  1 -DNRV_SINGLE_PORT_REGF -DNRV_SHARED_ADDER"
    "rv32ic_min_1p_sa_aw12 12  0 -DNRV_SINGLE_PORT_REGF -DNRV_SHARED_ADDER"
    "rv32ec_m_1p_sa_aw12   12  1 -DNRV_M -DNRV_SINGLE_PORT_REGF -DNRV_SHARED_ADDER"
    "rv32ic_m_1p_sa_aw12   12  0 -DNRV_M -DNRV_SINGLE_PORT_REGF -DNRV_SHARED_ADDER"
    "rv32ec_min_ss_aw12    12  1 -DNRV_SERIAL_SHIFT"
    "rv32ic_min_ss_aw12    12  0 -DNRV_SERIAL_SHIFT"
    "rv32ec_m_ss_aw12      12  1 -DNRV_M -DNRV_SERIAL_SHIFT"
    "rv32ic_m_ss_aw12      12  0 -DNRV_M -DNRV_SERIAL_SHIFT"
    "rv32ec_m_sm_aw12      12  1 -DNRV_M -DNRV_SERIAL_MUL"
    "rv32ic_m_sm_aw12      12  0 -DNRV_M -DNRV_SERIAL_MUL"
    "rv32ec_m_ss_sm_aw12   12  1 -DNRV_M -DNRV_SERIAL_SHIFT -DNRV_SERIAL_MUL"
    "rv32ic_m_ss_sm_aw12   12  0 -DNRV_M -DNRV_SERIAL_SHIFT -DNRV_SERIAL_MUL"
    "rv32ec_tiny_aw12      12  1 -DNRV_M -DNRV_SERIAL_SHIFT -DNRV_SERIAL_MUL -DNRV_SINGLE_PORT_REGF"
    "rv32ic_tiny_aw12      12  0 -DNRV_M -DNRV_SERIAL_SHIFT -DNRV_SERIAL_MUL -DNRV_SINGLE_PORT_REGF"
)

printf "\n=== AttoRV32 — Sky130A cell counts ===\n\n"
printf "%-22s %-10s %-6s %s\n" "CONFIG" "ADDR_W" "RV32E" "DEFINES"
printf "%-22s %-10s %-6s %s\n" "------" "------" "-----" "-------"

for cfg in "${CFGS[@]}"; do
    read -r NAME AW E DEFS <<< "$cfg"
    printf "%-22s %-10s %-6s %s\n" "$NAME" "$AW" "$E" "${DEFS:-(none)}"
done
echo

for cfg in "${CFGS[@]}"; do
    read -r NAME AW E DEFS <<< "$cfg"
    echo ">>> Synthesizing $NAME ..."
    export CFG_NAME="$NAME"
    export ADDR_WIDTH="$AW"
    export RV32E="$E"
    export DEFS="$DEFS"
    yosys -q -c syn/syn.tcl -l "$LOG_DIR/${NAME}.log" 2>&1 || {
        echo "FAILED: $NAME — see $LOG_DIR/${NAME}.log"
        continue
    }
done

echo
echo "=== Results ==="
python3 syn/summarize.py
