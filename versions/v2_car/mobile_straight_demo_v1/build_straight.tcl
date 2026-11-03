# Two-leg straight candidate build; does not program hardware or Flash.
set root [file normalize [file dirname [info script]]]
set out [file join $root build]
file mkdir $out
cd $out
create_project -in_memory -part xc7a35tfgg484-2
set snapshot [file join $root .. standalone_mobile_v1 vendor_snapshot]
set camera [file join $snapshot mobile_v1 camera_capture_v1]
set dvi [file join $camera hdmi_reference rgb2dvi_v1_2 src]
foreach src {DVI_Constants.vhd SyncAsync.vhd SyncAsyncReset.vhd ClockGen.vhd OutputSERDES.vhd TMDS_Encoder.vhd rgb2dvi.vhd} {read_vhdl [file join $dvi $src]}
set config [file join $camera geometry_probe_v1]
foreach src {sccb_master.sv ov5640_config.sv geometry_monitor.sv camera_diagnostics.sv} {read_verilog -sv [file join $config $src]}
foreach src {live_video_out.sv live_frame_buffer.sv} {read_verilog -sv [file join $camera live_hdmi_v1 $src]}
read_verilog [file join $snapshot waybill_final team_v1_20261022 team_design_20261022 source_snapshot rtl uart_tx.v]
read_verilog [file join $root .. waybill_standalone_handoff_20261101 waybill_final team_v1_20261022 team_design_20261022 source_snapshot rtl uart_rx.v]
read_verilog -sv [file join $root motion straight_route_controller.sv]
foreach src {square_cdc_mailbox.sv square_binary_frame.sv square_snapshot_engine.sv square_status_overlay.sv square_camera_core.sv} {read_verilog -sv [file join $root camera $src]}
read_verilog -sv [file join $root square_link.sv]
read_verilog -sv [file join $root straight_demo_top.sv]
read_xdc [file join $root square_ax7035b.xdc]
synth_design -top straight_demo_top -part xc7a35tfgg484-2
write_checkpoint -force straight_demo_synth.dcp
set ram36 [get_cells -hier -filter {REF_NAME == RAMB36E1}]
set ram18 [get_cells -hier -filter {REF_NAME == RAMB18E1}]
if {[llength $ram36]*2+[llength $ram18]>100} {error "BRAM budget exceeded"}
# Inherited frame-valid entries and asynchronous reset synchronizer assertion.
set syncpins [get_pins -hier -regexp {.*(diagnostics/valid_sync_reg\[0\]|display_valid_sync_reg\[0\]|ready_sync_reg\[0\]|frozen_sync_reg\[0\]|capture_sync_reg\[0\])/D}]
if {[llength $syncpins]} {set_false_path -to $syncpins}
set resetpins [get_pins -hier -regexp {.*(video_unit/reset_pipe_reg\[[0-2]\]|frame_unit/pixel_reset_pipe_reg\[[01]\])/CLR}]
if {[llength $resetpins]} {set_false_path -to $resetpins}
# Held-data mailboxes intentionally tolerate arbitrary clock phase. A request
# crosses two flops plus a copy_pending cycle; held data is immutable until
# the round-trip acknowledgement. Bound only these bundled paths physically,
# rather than timing them against the 0.317ns nearest sys/pixel clock edges.
# Two unused C/D completed bits are constant-folded in the two-station UI.
foreach {bridge width} {request_bridge 17 response_bridge 16 ui_bridge 64} {
    set source_cells [get_cells -hier -filter "NAME =~ camera_unit/$bridge/held_reg*"]
    set destination_cells [get_cells -hier -filter "NAME =~ camera_unit/$bridge/dst_data_reg*"]
    set source_pins [get_pins -of_objects $source_cells -filter {REF_PIN_NAME == C}]
    set destination_pins [get_pins -of_objects $destination_cells -filter {REF_PIN_NAME == D}]
    if {[llength $source_pins]!=$width || [llength $destination_pins]<$width} {
        error "Mailbox endpoints unexpected for $bridge: [llength $source_pins]/[llength $destination_pins]"
    }
    set_max_delay -datapath_only 19.0 -from $source_pins -to $destination_pins
    set_bus_skew 19.0 -from $source_pins -to $destination_pins
    set first_sync [get_pins -hier -regexp "camera_unit/$bridge/(req_sync_reg|ack_sync_reg)\\\[0\\\]/D"]
    if {[llength $first_sync]!=2} {error "Expected request+ack CDC entry pins for $bridge"}
    set_false_path -to $first_sync
    puts "HELD_MAILBOX_PHYSICAL_BOUND $bridge src=[llength $source_pins] dst=[llength $destination_pins] maxdelay=19ns skew=19ns"
}
report_utilization -file utilization_synth.rpt
opt_design
place_design
route_design
report_timing_summary -file timing.rpt
report_cdc -details -file cdc.rpt
report_drc -file drc.rpt
report_utilization -hierarchical -file utilization_routed.rpt
report_io -file io.rpt
report_bus_skew -file bus_skew.rpt
write_checkpoint -force straight_demo_routed.dcp
set setup [get_property SLACK [lindex [get_timing_paths -delay_type max -max_paths 1] 0]]
set hold [get_property SLACK [lindex [get_timing_paths -delay_type min -max_paths 1] 0]]
if {$setup<0 || $hold<0} {error "Timing failed setup=$setup hold=$hold"}
write_bitstream -force straight_demo_ax7035b.bit
puts "STRAIGHT_BUILD_PASS setup=$setup hold=$hold"
