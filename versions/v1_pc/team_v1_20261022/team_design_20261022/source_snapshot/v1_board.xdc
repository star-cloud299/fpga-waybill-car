set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

set_property PACKAGE_PIN Y18 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -name clk_50m -period 20.000 [get_ports clk]

set_property PACKAGE_PIN F20 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]

set_property PACKAGE_PIN G15 [get_ports uart_rxd]
set_property PACKAGE_PIN G16 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS33 [get_ports {uart_rxd uart_txd}]

# AX7035B user LEDs are active low. These status outputs are for observation only.
set_property PACKAGE_PIN F19 [get_ports busy]
set_property PACKAGE_PIN E21 [get_ports packet_error]
set_property IOSTANDARD LVCMOS33 [get_ports {busy packet_error}]
