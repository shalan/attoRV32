# syn.tcl — Yosys synthesis for AttoRV32 (Sky130A)
#
# Env vars (passed from run_syn.sh):
#   CFG_NAME     : label for the report
#   ADDR_WIDTH   : 8..12
#   RV32E        : 0 or 1
#   DEFS         : verilog `defines (e.g. "-DNRV_M")
#   LIB          : path to sky130 .lib
#   TOP          : top module (AttoRV32)
#   SRC          : Verilog source

yosys -import

set cfg_name    $::env(CFG_NAME)
set addr_width  $::env(ADDR_WIDTH)
set rv32e       $::env(RV32E)
set defs        $::env(DEFS)
set lib         $::env(LIB)
set top         $::env(TOP)
set src         $::env(SRC)

# Read source with defines
set read_cmd "read_verilog $defs $src"
eval $read_cmd

# Set top-level parameters
chparam -set ADDR_WIDTH $addr_width -set RV32E $rv32e $top

# Generic synthesis
hierarchy -check -top $top
synth -top $top -flatten

# Map DFFs to liberty
dfflibmap -liberty $lib

# --- Timing-driven technology mapping ------------------------------------
# Period in picoseconds. Default 10 ns; override via PERIOD_PS env.
set period_ps 10000
if {[info exists ::env(PERIOD_PS)]} { set period_ps $::env(PERIOD_PS) }

# Substitute {D} in the abc script template.
set abc_tpl   [expr {[info exists ::env(ABC_SCRIPT)] ? $::env(ABC_SCRIPT) : "syn/abc_timing.script"}]
set build_dir [expr {[info exists ::env(BUILD_DIR)] ? $::env(BUILD_DIR) : "build/syn"}]
file mkdir $build_dir

set fin  [open $abc_tpl r]
set body [read $fin]
close $fin
regsub -all "\\{D\\}" $body $period_ps body
set script_path "${build_dir}/${cfg_name}.abc.script"
set fout [open $script_path w]
puts -nonewline $fout $body
close $fout

# Technology map with custom, timing-driven script.
abc -liberty $lib -script $script_path

# Clean up
opt_clean -purge

# Final stats
tee -o "${build_dir}/${cfg_name}.stat" stat -liberty $lib -top $top
write_verilog "${build_dir}/${cfg_name}.mapped.v"
