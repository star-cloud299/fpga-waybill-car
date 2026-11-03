# Vivado 2019.1: vivado -mode batch -source tools/build_current.tcl
# Rebuild unchanged verified 192x96 RTL into a NEW directory. Does not program FPGA/Flash.
set root [file normalize [file join [file dirname [info script]] ..]]
set stamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set output [file join $root builds $stamp]
if {[file exists $output]} {error "Build directory already exists; choose a new run"}
file mkdir $output
set snapshot [file join $root team_v1_20261022 team_design_20261022 source_snapshot]
set b [file join $root integration_b_v1 rtl]
create_project -in_memory -part xc7a35tfgg484-2
read_verilog -sv [file join $b window_stats.sv]
read_verilog -sv [file join $b b_image_core.sv]
read_verilog -sv [file join $root official_v2 uart_official_v2_top.sv]
read_verilog [file join $snapshot rtl uart_rx.v]
read_verilog [file join $snapshot rtl uart_tx.v]
read_xdc [file join $snapshot v1_board.xdc]
synth_design -top uart_official_v2_top -part xc7a35tfgg484-2
report_utilization -file [file join $output utilization_synth.rpt]
report_drc -file [file join $output drc_synth.rpt]
opt_design
place_design
route_design
report_route_status -file [file join $output route_status.rpt]
report_timing_summary -report_unconstrained -file [file join $output timing_routed.rpt]
report_utilization -file [file join $output utilization_routed.rpt]
report_drc -file [file join $output drc_routed.rpt]
write_checkpoint -force [file join $output uart_official_v2_top_routed.dcp]
write_bitstream -force [file join $output uart_official_v2_top.bit]
puts "NEW_BUILD_OUTPUT=$output"
puts "Check timing and DRC, then program manually and rerun board tests. No Flash was written."
