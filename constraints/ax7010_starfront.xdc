## ============================================================================
## ALINX AX7010 (xc7z010clg400-1) - starfront-hdl camera bring-up
##
## Sources for every pin below:
##   - AX7010 User Manual, Part 5.2 (PL clock), 7.1 (HDMI), 7.5 (J11), 7.6/7.7
##   - AX7010/AX7020 schematic V2.0, sheets 5 and 15
##   - Zynq xc7z010clg400 package file (for the MRCC / SRCC annotations)
##
## Bank voltages: bank 34 and bank 35 are both 3.3 V by default on this board,
## which is what makes TMDS_33 legal on the HDMI pins and 3.3 V CMOS legal on
## the camera header.
## ============================================================================

## ----------------------------------------------------------------------------
## PL system clock - 50 MHz oscillator
## ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports {sys_clk}]   ;# PL_GCLK, IO_L12P_T1_MRCC_34

## ----------------------------------------------------------------------------
## User keys (active low) and LEDs (active low)
## ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports {key_n[0]}]  ;# KEY1 - reset
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {key_n[1]}]  ;# KEY2
set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} [get_ports {key_n[2]}]  ;# KEY3
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports {key_n[3]}]  ;# KEY4

set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {led_n[0]}]  ;# LED1 - heartbeat
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33} [get_ports {led_n[1]}]  ;# LED2 - MMCM locked
set_property -dict {PACKAGE_PIN K16 IOSTANDARD LVCMOS33} [get_ports {led_n[2]}]  ;# LED3 - camera ID ok
set_property -dict {PACKAGE_PIN J16 IOSTANDARD LVCMOS33} [get_ports {led_n[3]}]  ;# LED4 - PCLK alive

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
## HPD reaches the FPGA through U18 (NC7WZ07), an OPEN-DRAIN buffer: an asserted
## HPD leaves its output high-Z, so without a pull-up this pin reads 0 whether or
## not a monitor is attached.
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {hdmi_hpd}] ;# hot plug detect

## ----------------------------------------------------------------------------
## OV7670 on expansion header J11 (all bank 35, 3.3 V, 33R in series on board)
##
##   J11 pin 1/37/38 = GND, pin 39/40 = +3.3V  -> camera GND and 3V3
##   J11 pin 15 (K18) is deliberately left unconnected as a guard next to PCLK
## ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN F17 IOSTANDARD LVCMOS33} [get_ports {ov7670_data[0]}]  ;# J11-3  EX_IO2_1N
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports {ov7670_data[1]}]  ;# J11-4  EX_IO2_1P
set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS33} [get_ports {ov7670_data[2]}]  ;# J11-5  EX_IO2_2N
set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33} [get_ports {ov7670_data[3]}]  ;# J11-6  EX_IO2_2P
set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS33} [get_ports {ov7670_data[4]}]  ;# J11-7  EX_IO2_3N
set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS33} [get_ports {ov7670_data[5]}]  ;# J11-8  EX_IO2_3P
set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS33} [get_ports {ov7670_data[6]}]  ;# J11-9  EX_IO2_4N
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} [get_ports {ov7670_data[7]}]  ;# J11-10 EX_IO2_4P

set_property -dict {PACKAGE_PIN L20 IOSTANDARD LVCMOS33} [get_ports {ov7670_href}]     ;# J11-11 EX_IO2_5N
set_property -dict {PACKAGE_PIN L19 IOSTANDARD LVCMOS33} [get_ports {ov7670_vsync}]    ;# J11-12 EX_IO2_5P

set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS33} [get_ports {ov7670_sioc}]     ;# J11-13 EX_IO2_6N
set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {ov7670_siod}] ;# J11-14 EX_IO2_6P

## PCLK must land on a clock capable pin so it can reach a BUFG directly
set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS33} [get_ports {ov7670_pclk}]     ;# J11-16 EX_IO2_7P, IO_L12P_T1_MRCC_35

set_property -dict {PACKAGE_PIN G15 IOSTANDARD LVCMOS33} [get_ports {ov7670_pwdn}]     ;# J11-33 EX_IO2_16N
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports {ov7670_reset_n}]  ;# J11-34 EX_IO2_16P

## XCLK sits at the far end of the header, away from PCLK and the data bus
set_property -dict {PACKAGE_PIN K14 IOSTANDARD LVCMOS33} [get_ports {ov7670_xclk}]     ;# J11-36 EX_IO2_17P

## ============================================================================
## Timing
## ============================================================================

create_clock -period 20.000 -name sys_clk  -waveform {0.000 10.000} [get_ports {sys_clk}]
create_clock -period 40.000 -name cam_pclk -waveform {0.000 20.000} [get_ports {ov7670_pclk}]

## The camera domain and the MMCM domains only meet inside dual clock BRAM and
## explicit synchronisers, so treat them as fully asynchronous.
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks sys_clk] \
    -group [get_clocks cam_pclk]

if {[llength [get_clocks -quiet clk_fpga_0]] > 0} {
    set_clock_groups -asynchronous \
        -group [get_clocks clk_fpga_0] \
        -group [get_clocks -include_generated_clocks sys_clk]
}

set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -hierarchical -filter {NAME =~ *clk_out2*}]

## OV7670 datasheet: D[7:0] setup tSU = 15 ns, hold tHD = 8 ns relative to the
## PCLK rising edge (data changes tPDV = 5 ns after the falling edge). With a
## 40 ns period that gives a 25 ns max / 8 ns min arrival window.
set_input_delay -clock cam_pclk -max 25.000 \
    [get_ports {ov7670_data[*] ov7670_href ov7670_vsync}]
set_input_delay -clock cam_pclk -min  8.000 -add_delay \
    [get_ports {ov7670_data[*] ov7670_href ov7670_vsync}]

## Asynchronous or don't-care paths
set_false_path -from [get_ports {key_n[*] hdmi_hpd ov7670_siod}]
set_false_path -to   [get_ports {led_n[*] hdmi_out_en ov7670_sioc ov7670_siod \
                                 ov7670_reset_n ov7670_pwdn}]

## ============================================================================
## Configuration
## ============================================================================
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
