set root [file normalize [file dirname [info script]]]
set reports [file join $root board_reports]
file mkdir $reports
set snapshot [file normalize [file join $root .. team_v1_20261022 team_design_20261022 source_snapshot]]
set b [file normalize [file join $root .. integration_b_v1 rtl]]
create_project -in_memory -part xc7a35tfgg484-2
read_verilog -sv [file join $b window_stats.sv]
read_verilog -sv [file join $b b_image_core.sv]
read_verilog -sv [file join $root uart_official_v2_top.sv]
read_verilog [file join $snapshot rtl uart_rx.v]
read_verilog [file join $snapshot rtl uart_tx.v]
read_xdc [file join $snapshot v1_board.xdc]
synth_design -top uart_official_v2_top -part xc7a35tfgg484-2
report_utilization -file [file join $reports utilization_synth.rpt]
report_drc -file [file join $reports drc_synth.rpt]
opt_design
place_design
route_design
report_route_status -file [file join $reports route_status.rpt]
report_timing_summary -report_unconstrained -file [file join $reports timing_routed.rpt]
report_utilization -file [file join $reports utilization_routed.rpt]
report_drc -file [file join $reports drc_routed.rpt]
write_checkpoint -force [file join $reports uart_official_v2_top_routed.dcp]
write_bitstream -force [file join $reports uart_official_v2_top.bit]
puts "OFFICIAL_V2_BITSTREAM=[file join $reports uart_official_v2_top.bit]"
