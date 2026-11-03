# vivado -mode batch -source benchmark/compare.tcl
# Same part/clock/ports/constraints for both OOC components; not whole-board numbers.
set root [file normalize [file join [file dirname [info script]] ..]]
set stamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set out [file join $root builds component_compare_$stamp]
if {[file exists $out]} {error "output already exists"}
file mkdir $out
set constraint [file join $out clock.xdc]
set fp [open $constraint w]
puts $fp {create_clock -period 20.000 [get_ports clk]}
close $fp
foreach top {window_stats_naive window_stats} {
 create_project -in_memory -part xc7a35tfgg484-2
 if {$top eq "window_stats_naive"} {
  read_verilog -sv [file join $root benchmark window_stats_naive.sv]
 } else {read_verilog -sv [file join $root integration_b_v1 rtl window_stats.sv]}
 read_xdc $constraint
 synth_design -mode out_of_context -top $top -part xc7a35tfgg484-2 -generic K=15 -generic MAX_WIDTH=192
 report_utilization -file [file join $out ${top}_synth_util.rpt]
 opt_design
 place_design
 route_design
 report_utilization -file [file join $out ${top}_route_util.rpt]
 report_timing_summary -report_unconstrained -file [file join $out ${top}_timing.rpt]
 report_drc -file [file join $out ${top}_drc.rpt]
 write_checkpoint [file join $out ${top}.dcp]
 close_project
}
puts "COMPONENT_COMPARISON_OUTPUT=$out"
puts "Review DRC, unconstrained IO paths and both timing reports. No bitstream was programmed."
