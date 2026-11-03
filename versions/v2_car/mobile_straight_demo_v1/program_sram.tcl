# Two-leg SRAM load only; motor connectors remain unplugged during download.
set root [file normalize [file dirname [info script]]]
if {$argc!=1 || [lindex $argv 0] ne "straight"} {error "Usage: -tclargs straight"}
set bit [file join $root build straight_demo_ax7035b.bit]
if {![file isfile $bit]} {error "Missing two-leg bitstream"}
if {[llength [info commands open_hw_manager]]} {open_hw_manager} else {open_hw}
connect_hw_server -url localhost:3121
set targets [get_hw_targets]
if {[llength $targets]!=1} {error "Expected one JTAG cable"}
current_hw_target [lindex $targets 0]
set_property PARAM.FREQUENCY 1000000 [current_hw_target]
open_hw_target
set devices [get_hw_devices -filter {PART == xc7a35t}]
if {[llength $devices]!=1} {error "Expected one XC7A35T"}
set device [lindex $devices 0]
current_hw_device $device
set_property PROGRAM.FILE $bit $device
program_hw_devices $device
refresh_hw_device -update_hw_probes false $device
set done [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $device]
set crc [get_property REGISTER.CONFIG_STATUS.BIT00_CRC_ERROR $device]
file mkdir [file join $root evidence]
set report [open [file join $root evidence sram_straight_status.txt] w]
puts $report "MODE=straight\nBIT=$bit\nDONE=$done\nCRC_ERROR=$crc\nFLASH_WRITTEN=NO"
close $report
close_hw_target
disconnect_hw_server
if {[llength [info commands close_hw_manager]]} {close_hw_manager} else {close_hw}
if {$done!=1 || $crc!=0} {error "Two-leg SRAM load failed"}
puts "STRAIGHT_SRAM_PROGRAM_PASS NO_FLASH_WRITE"
