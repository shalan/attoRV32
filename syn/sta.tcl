#!/usr/bin/env -S sta -exit
# sta.tcl — WNS measurement for an AttoRV32 mapped netlist.
# Reads env: LIB, NETLIST, TOP, PERIOD, IO_DELAY.

set lib     $::env(LIB)
set netlist $::env(NETLIST)
set top     $::env(TOP)
set period  $::env(PERIOD)
set io_dly  $::env(IO_DELAY)

read_liberty  $lib
read_verilog  $netlist
link_design   $top

create_clock -name clk -period $period [get_ports clk]

# Constrain all non-clock I/O.
foreach p [get_ports *] {
    set pn [get_property $p full_name]
    if {$pn eq "clk"} { continue }
    set dir [get_property $p direction]
    if {$dir eq "input"}  { set_input_delay  -clock clk $io_dly $p }
    if {$dir eq "output"} { set_output_delay -clock clk $io_dly $p }
}

# WNS
set slack [sta::worst_slack -max]
puts [format "WNS=%.3f" $slack]
