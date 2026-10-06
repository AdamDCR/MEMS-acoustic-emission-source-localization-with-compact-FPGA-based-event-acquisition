############## NET - IOSTANDARD ######################
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
#############SPI Configurate Setting##################
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
############## clock define###########################
create_clock -period 5.000 [get_ports sys_clk_p]
set_property PACKAGE_PIN R4 [get_ports sys_clk_p]
set_property PACKAGE_PIN T4 [get_ports sys_clk_n]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_n]
# Board clock pins stay fixed. Only implementation-side clock placement is constrained below.
# DDR3 MIG already occupies the X1Y2 MMCM/PLL column, so bind system_clk_module to the free
# MMCM in the same clock region and allow dedicated routing across CMT columns in that region.
set_property LOC MMCME2_ADV_X0Y2 [get_cells system_clk_module_inst/inst/mmcm_adv_inst]
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets system_clk_module_inst/inst/clk_in1_system_clk_module]
############## RESET define############################
set_property PACKAGE_PIN V17 [get_ports reset_sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports reset_sys_clk]

##############  led define############################
set_property IOSTANDARD LVCMOS33 [get_ports {LED_OUT[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports SYS_OUT]

set_property PACKAGE_PIN AB22 [get_ports {LED_OUT[0]}]
set_property PACKAGE_PIN AB21 [get_ports {LED_OUT[1]}]
set_property PACKAGE_PIN V15 [get_ports {LED_OUT[2]}]
set_property PACKAGE_PIN U15 [get_ports {LED_OUT[3]}]
set_property PACKAGE_PIN W17 [get_ports SYS_OUT]

##############  key define############################
set_property IOSTANDARD LVCMOS33 [get_ports {KEY[*]}]

set_property PACKAGE_PIN AA19 [get_ports {KEY[0]}]
set_property PACKAGE_PIN AB20 [get_ports {KEY[1]}]
set_property PACKAGE_PIN AA20 [get_ports {KEY[2]}]
set_property PACKAGE_PIN AA21 [get_ports {KEY[3]}]

##############  DS18B20+ define############################
set_property IOSTANDARD LVCMOS33 [get_ports TEM]
# AE_MultiChannel CON2 pin1 -> AX7203B CON2 pin1 -> FPGA W15
set_property PACKAGE_PIN W15 [get_ports TEM]
##############  Humdity define############################
set_property IOSTANDARD LVCMOS33 [get_ports H_SCL]
set_property IOSTANDARD LVCMOS33 [get_ports H_SDA]
set_property PACKAGE_PIN AB10 [get_ports H_SDA]
set_property PACKAGE_PIN AA9 [get_ports H_SCL]



##############  IO3V3 define############################
#   set_property IOSTANDARD LVCMOS33 [get_ports {IO3V3[*]}]
#   set_property PACKAGE_PIN R18 [get_ports {IO3V3[0]}]
#   set_property PACKAGE_PIN T18 [get_ports {IO3V3[1]}]
#   set_property PACKAGE_PIN U22 [get_ports {IO3V3[2]}]
#   set_property PACKAGE_PIN V22 [get_ports {IO3V3[3]}]
#   set_property PACKAGE_PIN Y18 [get_ports {IO3V3[4]}]
#   set_property PACKAGE_PIN Y19 [get_ports {IO3V3[5]}]
#   set_property PACKAGE_PIN W19 [get_ports {IO3V3[6]}]
#   set_property PACKAGE_PIN W20 [get_ports {IO3V3[7]}]
#   set_property PACKAGE_PIN Y22 [get_ports {IO3V3[8]}]
#   set_property PACKAGE_PIN Y21 [get_ports {IO3V3[9]}]
#   set_property PACKAGE_PIN U21 [get_ports {IO3V3[10]}]
#   set_property PACKAGE_PIN T21 [get_ports {IO3V3[11]}]
#   set_property PACKAGE_PIN W21 [get_ports {IO3V3[12]}]
#   set_property PACKAGE_PIN W22 [get_ports {IO3V3[13]}]
#   set_property PACKAGE_PIN T20 [get_ports {IO3V3[14]}]
#   set_property PACKAGE_PIN AB18 [get_ports {IO3V3[15]}]
#   set_property PACKAGE_PIN AA18 [get_ports {IO3V3[16]}]

##############  Inertia define############################
set_property IOSTANDARD LVCMOS33 [get_ports Inertia_SDO]
set_property IOSTANDARD LVCMOS33 [get_ports Inertia_SDX]
set_property IOSTANDARD LVCMOS33 [get_ports Inertia_SCX]
set_property IOSTANDARD LVCMOS33 [get_ports Inertia_INT1]
set_property IOSTANDARD LVCMOS33 [get_ports Inertia_INT2]
set_property IOSTANDARD LVCMOS33 [get_ports Inertia_OSCB]
set_property IOSTANDARD LVCMOS33 [get_ports Inertia_OSDO]
set_property IOSTANDARD LVCMOS33 [get_ports Inertia_CSB]
set_property IOSTANDARD LVCMOS33 [get_ports Inertia_SCL]
set_property IOSTANDARD LVCMOS33 [get_ports Inertia_SDA]

set_property PACKAGE_PIN T15 [get_ports Inertia_INT1]
set_property PACKAGE_PIN V13 [get_ports Inertia_SCX]
set_property PACKAGE_PIN V14 [get_ports Inertia_SDX]
set_property PACKAGE_PIN W11 [get_ports Inertia_SDO]
set_property PACKAGE_PIN W12 [get_ports Inertia_SDA]
set_property PACKAGE_PIN Y11 [get_ports Inertia_SCL]
set_property PACKAGE_PIN Y12 [get_ports Inertia_CSB]
set_property PACKAGE_PIN V10 [get_ports Inertia_OSDO]
set_property PACKAGE_PIN AA10 [get_ports Inertia_INT2]
set_property PACKAGE_PIN AA11 [get_ports Inertia_OSCB]



##############  pulse_out define ############################
set_property IOSTANDARD LVCMOS33 [get_ports {EN[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {INA[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {INB[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {INC[*]}]

set_property PACKAGE_PIN AA15 [get_ports {EN[0]}]
set_property PACKAGE_PIN Y13 [get_ports {EN[1]}]
set_property PACKAGE_PIN AB16 [get_ports {EN[2]}]
set_property PACKAGE_PIN AA13 [get_ports {EN[3]}]

set_property PACKAGE_PIN AB15 [get_ports {INA[0]}]
set_property PACKAGE_PIN AA14 [get_ports {INA[1]}]
set_property PACKAGE_PIN AB17 [get_ports {INA[2]}]
set_property PACKAGE_PIN AB13 [get_ports {INA[3]}]


set_property PACKAGE_PIN Y16 [get_ports {INB[0]}]
set_property PACKAGE_PIN AB11 [get_ports {INB[1]}]
set_property PACKAGE_PIN W14 [get_ports {INB[2]}]
set_property PACKAGE_PIN T16 [get_ports {INB[3]}]


set_property PACKAGE_PIN AA16 [get_ports {INC[0]}]
set_property PACKAGE_PIN AB12 [get_ports {INC[1]}]
set_property PACKAGE_PIN Y14 [get_ports {INC[2]}]
set_property PACKAGE_PIN U16 [get_ports {INC[3]}]

##############  Binary Bytes######################## 
set_property IOSTANDARD LVCMOS15 [get_ports {BIN[*]}]
set_property PACKAGE_PIN AB6 [get_ports {BIN[0]}]
set_property PACKAGE_PIN AB7 [get_ports {BIN[1]}]
set_property PACKAGE_PIN W7 [get_ports {BIN[2]}]
set_property PACKAGE_PIN V7 [get_ports {BIN[3]}]
set_property PACKAGE_PIN Y6 [get_ports {BIN[4]}]
set_property PACKAGE_PIN AA6 [get_ports {BIN[5]}]
set_property PACKAGE_PIN Y7 [get_ports {BIN[6]}]
set_property PACKAGE_PIN Y8 [get_ports {BIN[7]}]

############## usb uart define######################## éĄśé¨ćŠĺąĺźč
#   set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]
#   set_property PACKAGE_PIN AA15 [get_ports uart_rx]
#
#   set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]
#   set_property PACKAGE_PIN AB15 [get_ports uart_tx]

#########################ethernet######################
create_clock -period 8.000 [get_ports eth_rxc]
create_clock -period 8.000 [get_ports eth_txc]
# Board-level RGMII RXC pin is fixed and does not use a dedicated clock route
# to BUFG on this design. Allow non-dedicated routing so implementation can continue.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -hier -filter {NAME =~ *eth_rxc_IBUF_BUFG*}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_rxd[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_txd[*]}]
set_property SLEW FAST [get_ports {eth_txd[*]}]

# set_property IOSTANDARD LVCMOS33 [get_ports eth_mdc]
# set_property IOSTANDARD LVCMOS33 [get_ports eth_mdio]
#   set_property IOSTANDARD LVCMOS33 [get_ports e1_reset]

set_property IOSTANDARD LVCMOS33 [get_ports eth_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports eth_rxc]
set_property IOSTANDARD LVCMOS33 [get_ports eth_rx_ctl]
set_property IOSTANDARD LVCMOS33 [get_ports eth_txc]
set_property IOSTANDARD LVCMOS33 [get_ports eth_tx_ctl]

set_property SLEW FAST [get_ports eth_txc]
set_property SLEW FAST [get_ports eth_tx_ctl]

set_property PACKAGE_PIN R19 [get_ports {eth_rxd[3]}]
set_property PACKAGE_PIN P19 [get_ports {eth_rxd[2]}]
set_property PACKAGE_PIN U18 [get_ports {eth_rxd[1]}]
set_property PACKAGE_PIN U17 [get_ports {eth_rxd[0]}]

set_property PACKAGE_PIN P16 [get_ports {eth_txd[3]}]
set_property PACKAGE_PIN R17 [get_ports {eth_txd[2]}]
set_property PACKAGE_PIN R16 [get_ports {eth_txd[1]}]
set_property PACKAGE_PIN P15 [get_ports {eth_txd[0]}]
# set_property PACKAGE_PIN N14 [get_ports eth_mdc]
# set_property PACKAGE_PIN P14 [get_ports eth_mdio]
#   set_property PACKAGE_PIN D16 [get_ports e1_reset]

set_property PACKAGE_PIN N13 [get_ports eth_rst_n]
set_property PACKAGE_PIN V19 [get_ports eth_rx_ctl]
set_property PACKAGE_PIN U20 [get_ports eth_txc]
set_property PACKAGE_PIN V20 [get_ports eth_tx_ctl]
set_property PACKAGE_PIN V18 [get_ports eth_rxc]

############## adc1 define##################

set_property IOSTANDARD LVCMOS25 [get_ports adc1_pdwn]
set_property IOSTANDARD LVCMOS25 [get_ports adc1_spi_csn]
set_property IOSTANDARD LVCMOS25 [get_ports adc1_spi_sck]
set_property IOSTANDARD LVCMOS25 [get_ports adc1_spi_dio]
set_property IOSTANDARD LVCMOS25 [get_ports adc1_sync]

set_property PACKAGE_PIN M15 [get_ports adc1_pdwn]
set_property PACKAGE_PIN L15 [get_ports adc1_spi_csn]
set_property PACKAGE_PIN K16 [get_ports adc1_spi_sck]
set_property PACKAGE_PIN L14 [get_ports adc1_spi_dio]
set_property PACKAGE_PIN M16 [get_ports adc1_sync]

set_property PULLUP true [get_ports adc1_spi_dio]

set_property PACKAGE_PIN J20 [get_ports adc1_clk_out_p]
set_property IOSTANDARD LVDS_25 [get_ports adc1_clk_out_p]

set_property PACKAGE_PIN H13 [get_ports adc1_fclk_p]
set_property IOSTANDARD LVDS_25 [get_ports adc1_fclk_p]
set_property DIFF_TERM TRUE [get_ports adc1_fclk_p]
set_property DIFF_TERM TRUE [get_ports adc1_fclk_n]

create_clock -period 3.571 [get_ports adc1_dclk_p]
set_property PACKAGE_PIN L19 [get_ports adc1_dclk_p]
set_property IOSTANDARD LVDS_25 [get_ports adc1_dclk_p]
set_property DIFF_TERM TRUE [get_ports adc1_dclk_p]
set_property DIFF_TERM TRUE [get_ports adc1_dclk_n]

set_property IOSTANDARD LVDS_25 [get_ports {adc1_data_in_p[*]}]
set_property DIFF_TERM TRUE [get_ports {adc1_data_in_n[7]}]
set_property DIFF_TERM TRUE [get_ports {adc1_data_in_n[6]}]
set_property DIFF_TERM TRUE [get_ports {adc1_data_in_n[5]}]
set_property DIFF_TERM TRUE [get_ports {adc1_data_in_n[4]}]
set_property DIFF_TERM TRUE [get_ports {adc1_data_in_n[3]}]
set_property DIFF_TERM TRUE [get_ports {adc1_data_in_n[2]}]
set_property DIFF_TERM TRUE [get_ports {adc1_data_in_n[1]}]
set_property DIFF_TERM TRUE [get_ports {adc1_data_in_n[0]}]
set_property DIFF_TERM true [get_ports {adc1_data_in_p[*]}]
set_property DIFF_TERM true [get_ports {adc1_data_in_p[*]}]

set_property PACKAGE_PIN M18 [get_ports {adc1_data_in_p[0]}]
set_property PACKAGE_PIN K13 [get_ports {adc1_data_in_p[1]}]
set_property PACKAGE_PIN N18 [get_ports {adc1_data_in_p[2]}]
set_property PACKAGE_PIN J14 [get_ports {adc1_data_in_p[3]}]
set_property PACKAGE_PIN K18 [get_ports {adc1_data_in_p[4]}]
set_property PACKAGE_PIN N22 [get_ports {adc1_data_in_p[5]}]
set_property PACKAGE_PIN J22 [get_ports {adc1_data_in_p[6]}]
set_property PACKAGE_PIN H20 [get_ports {adc1_data_in_p[7]}]

############## adc2 define##################
set_property PACKAGE_PIN C14 [get_ports adc2_pdwn]
set_property PACKAGE_PIN C15 [get_ports adc2_spi_csn]
set_property PACKAGE_PIN F20 [get_ports adc2_spi_sck]
set_property PACKAGE_PIN F19 [get_ports adc2_spi_dio]
set_property PACKAGE_PIN E17 [get_ports adc2_sync]

set_property IOSTANDARD LVCMOS25 [get_ports adc2_pdwn]
set_property IOSTANDARD LVCMOS25 [get_ports adc2_spi_csn]
set_property IOSTANDARD LVCMOS25 [get_ports adc2_spi_sck]
set_property IOSTANDARD LVCMOS25 [get_ports adc2_spi_dio]
set_property IOSTANDARD LVCMOS25 [get_ports adc2_sync]

set_property PULLUP true [get_ports adc2_spi_dio]

set_property PACKAGE_PIN D17 [get_ports adc2_clk_out_p]
set_property IOSTANDARD LVDS_25 [get_ports adc2_clk_out_p]

set_property PACKAGE_PIN B15 [get_ports adc2_fclk_p]
set_property IOSTANDARD LVDS_25 [get_ports adc2_fclk_p]
set_property DIFF_TERM TRUE [get_ports adc2_fclk_p]
set_property DIFF_TERM TRUE [get_ports adc2_fclk_n]

create_clock -period 3.571 [get_ports adc2_dclk_p]
set_property PACKAGE_PIN C18 [get_ports adc2_dclk_p]
set_property IOSTANDARD LVDS_25 [get_ports adc2_dclk_p]
set_property DIFF_TERM TRUE [get_ports adc2_dclk_p]
set_property DIFF_TERM TRUE [get_ports adc2_dclk_n]

set_property IOSTANDARD LVDS_25 [get_ports {adc2_data_in_p[*]}]
set_property DIFF_TERM TRUE [get_ports {adc2_data_in_n[7]}]
set_property DIFF_TERM TRUE [get_ports {adc2_data_in_n[6]}]
set_property DIFF_TERM TRUE [get_ports {adc2_data_in_n[5]}]
set_property DIFF_TERM TRUE [get_ports {adc2_data_in_n[4]}]
set_property DIFF_TERM TRUE [get_ports {adc2_data_in_n[3]}]
set_property DIFF_TERM TRUE [get_ports {adc2_data_in_n[2]}]
set_property DIFF_TERM TRUE [get_ports {adc2_data_in_n[1]}]
set_property DIFF_TERM TRUE [get_ports {adc2_data_in_n[0]}]
set_property DIFF_TERM true [get_ports {adc2_data_in_p[*]}]
set_property DIFF_TERM true [get_ports {adc2_data_in_p[*]}]

set_property PACKAGE_PIN C22 [get_ports {adc2_data_in_p[0]}]
set_property PACKAGE_PIN E19 [get_ports {adc2_data_in_p[1]}]
set_property PACKAGE_PIN E16 [get_ports {adc2_data_in_p[2]}]
set_property PACKAGE_PIN B20 [get_ports {adc2_data_in_p[3]}]
set_property PACKAGE_PIN B17 [get_ports {adc2_data_in_p[4]}]
set_property PACKAGE_PIN F18 [get_ports {adc2_data_in_p[5]}]
set_property PACKAGE_PIN A18 [get_ports {adc2_data_in_p[6]}]
set_property PACKAGE_PIN D20 [get_ports {adc2_data_in_p[7]}]


set_clock_groups -name clk_group -asynchronous -group [get_clocks eth_rxc] -group [get_clocks eth_txc]
set_false_path -from [get_clocks eth_rxc] -to [get_clocks -of_objects [get_pins system_clk_module_inst/inst/mmcm_adv_inst/CLKOUT0]]
