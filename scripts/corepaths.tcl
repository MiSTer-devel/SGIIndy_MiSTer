# corepaths.tcl - the core clock's worst setup paths of a fit already on disk,
# one per endpoint, for tools/pathfamilies.py to group.
#
# worstpaths.tcl answers "which path is worst"; this answers "which FAMILY of
# paths is in the way", which is what decides the fix. Build 45 missed by
# 0.927 ns and the summary said nothing more; 286 of these 300 endpoints came
# from one source (mc_gio_dma -> ddr3_mux), and the second run below - with
# that source excluded - showed the next family (the CPU's bus_addr through
# sgi_memmap) and how far off it was. Two fixes, one refit, +0.639 ns.
#
#   "$QUARTUS_BIN/quartus_sta" -t scripts/corepaths.tcl > paths.txt
#   python tools/pathfamilies.py paths.txt
#   EXCLUDE='*u_mc|*' ...   also report with those sources left out
project_open sgiindy
create_timing_netlist
read_sdc
update_timing_netlist

set clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set n 300
if {[info exists ::env(NPATHS)]} { set n $::env(NPATHS) }

puts "==== worst $n unique endpoints, core clock ===="
report_timing -setup -to_clock $clk -npaths $n -nworst 1 -detail summary -stdout

if {[info exists ::env(EXCLUDE)]} {
    set src [remove_from_collection [get_keepers *] [get_keepers $::env(EXCLUDE)]]
    puts "==== worst $n unique endpoints, core clock, sources $::env(EXCLUDE) excluded ===="
    report_timing -setup -from $src -to_clock $clk -npaths $n -nworst 1 -detail summary -stdout
}

delete_timing_netlist
project_close
