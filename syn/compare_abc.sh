#!/usr/bin/env bash
# compare_abc.sh — Run synthesis with multiple ABC recipes and compare results.
# Run from repo root:  bash syn/compare_abc.sh
set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PDK="${PDK:-/Users/mshalan/work/pdks/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af/sky130A}"
export LIB="${LIB:-$PDK/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib}"
export SRC="rtl/attorv32.v"
export TOP="AttoRV32"
export BUILD_DIR="build/syn_compare"
export LOG_DIR="build/logs"
STA="/nix/store/2ia51h09wfm9qpm9dg3zq52cr578ah61-opensta/bin/sta"

mkdir -p "$BUILD_DIR" "$LOG_DIR"

# ABC recipes to compare
RECIPES=(
    "timing   syn/abc_timing.script"
    "area     syn/abc_area.script"
    "delay    syn/abc_delay.script"
    "resyn2   syn/abc_resyn2.script"
    "default  syn/abc_default.script"
)

# Representative configs: name | ADDR_WIDTH | RV32E | DEFS
CFGS=(
    "rv32emc_ss_sm_aw12    12  1 -DNRV_M -DNRV_SERIAL_SHIFT -DNRV_SERIAL_MUL"
    "rv32emc_aw12          12  1 -DNRV_M"
    "rv32emc_ss_aw12       12  1 -DNRV_M -DNRV_SERIAL_SHIFT"
    "rv32emc_sm_aw12       12  1 -DNRV_M -DNRV_SERIAL_MUL"
    "rv32ec_aw12           12  1 "
)

PERIOD_NS=14
IO_DELAY=5
export PERIOD_PS=$((PERIOD_NS * 1000))

printf "\n=== ABC Recipe Comparison (Sky130 HD, period=%s ns) ===\n\n" "$PERIOD_NS"
printf "%-32s %6s %12s %10s\n" "CONFIG + RECIPE" "CELLS" "AREA" "WNS(ns)"
printf "%-32s %6s %12s %10s\n" "---" "-----" "----" "-------"

for cfg in "${CFGS[@]}"; do
    read -r NAME AW E DEFS <<< "$cfg"
    for recipe in "${RECIPES[@]}"; do
        read -r RNAME RPATH <<< "$recipe"
        TAG="${NAME}_${RNAME}"
        export CFG_NAME="$TAG"
        export ADDR_WIDTH="$AW"
        export RV32E="$E"
        export DEFS="$DEFS"
        export ABC_SCRIPT="$RPATH"

        yosys -q -c syn/syn.tcl -l "$LOG_DIR/${TAG}.log" 2>&1 || {
            printf "%-32s  FAILED\n" "$TAG"
            continue
        }

        # Extract cell count and area from stat file
        STAT="$BUILD_DIR/${TAG}.stat"
        NETLIST="$BUILD_DIR/${TAG}.mapped.v"
        CELLS=""
        AREA=""
        WNS=""
        if [ -f "$STAT" ]; then
            CELLS=$(grep "cells$" "$STAT" | awk '{print $1}')
            AREA=$(grep "Chip area" "$STAT" | awk '{print $NF}')
        fi

        # Run STA for WNS
        if [ -f "$NETLIST" ]; then
            STA_SCRIPT="$BUILD_DIR/${TAG}.sta.tcl"
            cat > "$STA_SCRIPT" <<STAEOF
read_liberty $LIB
read_verilog $NETLIST
link_design $TOP
create_clock -name clk -period $PERIOD_NS [get_ports clk]
set_input_delay  -clock clk $IO_DELAY [all_inputs]
set_output_delay -clock clk $IO_DELAY [all_outputs]
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 [all_inputs]
set_load 0.07 [all_outputs]
set slack [sta::worst_slack -max]
puts [format "WNS=%.3f" \$slack]
exit
STAEOF
            WNS=$(TERM=dumb $STA -no_init "$STA_SCRIPT" 2>/dev/null | grep "^WNS=" | sed 's/WNS=//')
        fi

        printf "%-32s %6s %12s %10s\n" "$TAG" "$CELLS" "$AREA" "$WNS"
    done
    echo ""
done
