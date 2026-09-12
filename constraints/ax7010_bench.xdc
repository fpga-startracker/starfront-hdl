## ============================================================================
## ALINX AX7010 (xc7z010clg400-1) - starfront-hdl centroiding bench
##
## Same board, same pins, no camera. This is ax7010_starfront.xdc with the
## OV7670 header and its timing removed, because top_starfront_bench has no
## camera ports: leaving the constraints in would attach an input delay to a
## clock nothing drives, and Vivado's warning about that is indistinguishable
## from the one that means something.
##
## Sources for every pin: AX7010 User Manual parts 5.2, 7.1, 7.6, 7.7;
## AX7010/AX7020 schematic V2.0 sheets 5 and 15.
## ============================================================================

## ----------------------------------------------------------------------------
## PL system clock - 50 MHz oscillator
## ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports {sys_clk}]   ;# PL_GCLK, IO_L12P_T1_MRCC_34

## ----------------------------------------------------------------------------
## User keys and LEDs, both active low
## ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports {key_n[0]}]  ;# KEY1 - reset
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {key_n[1]}]  ;# KEY2 - next frame
set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} [get_ports {key_n[2]}]  ;# KEY3 - auto cycle
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports {key_n[3]}]  ;# KEY4 - hold

set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {led_n[0]}]  ;# LED1 - heartbeat
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33} [get_ports {led_n[1]}]  ;# LED2 - replay running
set_property -dict {PACKAGE_PIN K16 IOSTANDARD LVCMOS33} [get_ports {led_n[2]}]  ;# LED3 - a star was dropped
set_property -dict {PACKAGE_PIN J16 IOSTANDARD LVCMOS33} [get_ports {led_n[3]}]  ;# LED4 - star list full

## ----------------------------------------------------------------------------
## HDMI - raw TMDS straight out of PL bank 34 (no encoder chip on the board)
##   channel 0 = blue + sync, channel 1 = green, channel 2 = red
## ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN N18 IOSTANDARD TMDS_33} [get_ports {hdmi_clk_p}]   ;# IO_L13P_T2_MRCC_34
set_property -dict {PACKAGE_PIN P19 IOSTANDARD TMDS_33} [get_ports {hdmi_clk_n}]   ;# IO_L13N_T2_MRCC_34

set_property -dict {PACKAGE_PIN V20 IOSTANDARD TMDS_33} [get_ports {hdmi_d_p[0]}]  ;# HDMI_D0_P (blue)
set_property -dict {PACKAGE_PIN W20 IOSTANDARD TMDS_33} [get_ports {hdmi_d_n[0]}]  ;# HDMI_D0_N
set_property -dict {PACKAGE_PIN T20 IOSTANDARD TMDS_33} [get_ports {hdmi_d_p[1]}]  ;# HDMI_D1_P (green)
set_property -dict {PACKAGE_PIN U20 IOSTANDARD TMDS_33} [get_ports {hdmi_d_n[1]}]  ;# HDMI_D1_N
set_property -dict {PACKAGE_PIN N20 IOSTANDARD TMDS_33} [get_ports {hdmi_d_p[2]}]  ;# HDMI_D2_P (red)
set_property -dict {PACKAGE_PIN P20 IOSTANDARD TMDS_33} [get_ports {hdmi_d_n[2]}]  ;# HDMI_D2_N

set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {hdmi_out_en}] ;# TPS2051B EN - +5V to the sink
## HPD reaches the FPGA through an open-drain buffer, so without a pull-up this
## pin reads 0 whether or not a monitor is attached.
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {hdmi_hpd}]

## ============================================================================
## Timing
## ============================================================================
create_clock -period 20.000 -name sys_clk -waveform {0.000 10.000} [get_ports {sys_clk}]

set_false_path -from [get_ports {key_n[*] hdmi_hpd}]
set_false_path -to   [get_ports {led_n[*] hdmi_out_en}]

## ============================================================================
## Configuration
## ============================================================================
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
