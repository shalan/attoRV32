#!/usr/bin/env bash
# run_tb.sh — build selftest.c firmware and run tb.v against a given config.
#
# Run from the repo root:
#   bash sim/run_tb.sh                 # runs every default config
#   bash sim/run_tb.sh <name> ...      # runs just the named config(s)
#
# Configs are labelled <arch>_<aw>_<opts>:
#   arch : rv32ec | rv32ic
#   aw   : aw12
#   opts : min | m | m_ss_sm | tiny   (matches syn/run_syn.sh labels)
set -u

# Resolve repo root (directory containing this script's parent).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

CROSS="${CROSS:-riscv64-unknown-elf-}"
IVERILOG="${IVERILOG:-iverilog}"
VVP="${VVP:-vvp}"

# Each config is: label | ADDR_WIDTH | RV32E | HAVE_M | DEFS (Verilog)
CFGS=(
    "rv32ec_min_aw12       12 1 0                                        "
    "rv32ec_m_aw12         12 1 1 -DNRV_M"
    "rv32ec_tiny_aw12      12 1 1 -DNRV_M -DNRV_SERIAL_SHIFT -DNRV_SERIAL_MUL -DNRV_SINGLE_PORT_REGF"
    "rv32ic_min_aw12       12 0 0                                        "
    "rv32ic_m_aw12         12 0 1 -DNRV_M"
    "rv32ic_m_ss_sm_aw12   12 0 1 -DNRV_M -DNRV_SERIAL_SHIFT -DNRV_SERIAL_MUL"
    "rv32ic_tiny_aw12      12 0 1 -DNRV_M -DNRV_SERIAL_SHIFT -DNRV_SERIAL_MUL -DNRV_SINGLE_PORT_REGF"
)

BUILD_DIR="build/sim"
LOG_DIR="build/logs"
mkdir -p "$BUILD_DIR" "$LOG_DIR"

run_one() {
    local name="$1" aw="$2" rve="$3" havem="$4" defs="$5"
    echo ">>> $name"

    # 1) Build firmware (in sw/, with artifacts landing in sw/)
    make -s -C sw clean >/dev/null
    if ! make -s -C sw CROSS="$CROSS" SELFTEST=1 \
                  ADDR_WIDTH="$aw" RV32E="$rve" HAVE_M="$havem" \
                  all >"$LOG_DIR/${name}.build.log" 2>&1 ; then
        echo "    BUILD FAILED — see $LOG_DIR/${name}.build.log"
        return 1
    fi

    # 2) Compile testbench (pass defs + parameters)
    local sim_exe="$BUILD_DIR/${name}.vvp"
    if ! $IVERILOG -g2005-sv -DBENCH $defs \
            -Ptb.ADDR_WIDTH="$aw" -Ptb.RV32E="$rve" \
            -o "$sim_exe" sim/tb.v rtl/attorv32.v \
            >"$LOG_DIR/${name}.iv.log" 2>&1 ; then
        echo "    IVERILOG FAILED — see $LOG_DIR/${name}.iv.log"
        return 1
    fi

    # 3) Run simulation
    local out="$LOG_DIR/${name}.sim.log"
    $VVP "$sim_exe" +hex=sw/selftest.hex +timeout=500000 >"$out" 2>&1
    local rc=$?

    # 4) Report
    if grep -q "^\[tb\] PASS" "$out"; then
        local cyc=$(grep "^\[tb\] PASS" "$out" | head -1 | sed 's/.*cycle //')
        echo "    PASS  (cycles = $cyc)"
        return 0
    elif grep -q "^\[tb\] FAIL" "$out"; then
        local code=$(grep "^\[tb\] FAIL" "$out" | head -1)
        echo "    $code"
        return 1
    elif grep -q "TIMEOUT" "$out"; then
        echo "    TIMEOUT — see $out"
        return 1
    else
        echo "    UNKNOWN rc=$rc — see $out"
        return 1
    fi
}

printf "\n=== AttoRV32 self-test ===\n\n"

total=0
pass=0
for cfg in "${CFGS[@]}"; do
    read -r name aw rve havem defs <<< "$cfg"
    # Filter by argv
    if [ "$#" -gt 0 ]; then
        match=0
        for want in "$@"; do
            [ "$name" = "$want" ] && match=1 && break
        done
        [ "$match" -eq 0 ] && continue
    fi
    total=$((total+1))
    if run_one "$name" "$aw" "$rve" "$havem" "$defs"; then
        pass=$((pass+1))
    fi
done

echo
echo "=== Summary: $pass / $total configs PASS ==="
[ "$pass" -eq "$total" ]
