#=============================================================================
# create_project.tcl - regenerate the Vivado project for starfront-hdl
#
#   vivado -mode batch -source scripts/create_project.tcl
#   vivado -mode batch -source scripts/create_project.tcl -tclargs impl
#
# The second form also runs synthesis and implementation and writes the
# bitstream to build/starfront_bringup.bit.
#
# Nothing under build/ is version controlled: the project, both IP cores and
# the bitstream are all reproduced from this script plus rtl/ and constraints/.
#=============================================================================

set proj_name "starfront_bringup"
set part_name "xc7z010clg400-1"
set top_name  "top_starfront_bringup"

set script_dir [file dirname [file normalize [info script]]]
set repo_dir   [file dirname $script_dir]
set build_dir  "$repo_dir/build"

set run_impl 0
if {[llength $argv] > 0 && [string equal [lindex $argv 0] "impl"]} {
    set run_impl 1
}

file mkdir $build_dir

#-----------------------------------------------------------------------------
# Project
#-----------------------------------------------------------------------------
create_project -force $proj_name $build_dir/$proj_name -part $part_name

add_files -norecurse [glob $repo_dir/rtl/*.v]
add_files -fileset constrs_1 -norecurse $repo_dir/constraints/ax7010_starfront.xdc

set_property top $top_name [current_fileset]

#-----------------------------------------------------------------------------
# clk_wiz_0 - 50 MHz PL_GCLK in, 125 MHz TMDS serial + 25 MHz pixel out.
#
# Both outputs come from the same MMCM (VCO 750 MHz), which is what keeps
# clk_ser phase aligned with clk_pix for the 10:1 OSERDES pair.
#-----------------------------------------------------------------------------
create_ip -name clk_wiz -vendor xilinx.com -library ip -module_name clk_wiz_0

set_property -dict [list \
    CONFIG.PRIM_SOURCE                  {Single_ended_clock_capable_pin} \
    CONFIG.PRIM_IN_FREQ                 {50.000} \
    CONFIG.CLKIN1_JITTER_PS             {200.0} \
    CONFIG.NUM_OUT_CLKS                 {2} \
    CONFIG.CLKOUT1_USED                 {true} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ   {125.000} \
    CONFIG.CLKOUT2_USED                 {true} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ   {25.000} \
    CONFIG.USE_LOCKED                   {true} \
    CONFIG.USE_RESET                    {false} \
] [get_ips clk_wiz_0]

generate_target all [get_ips clk_wiz_0]

#-----------------------------------------------------------------------------
# ila_0 - for looking at the SCCB waveform when the on-screen status says the
# camera ID read failed.
#   probe0  {cam_readback, cam_ver, cam_pid, probe_state}
#   probe1  {0, 0, id_ok, rw_ok, sio_c, sio_d_in, sio_d_oe, sccb_busy}
#   probe2  sccb state
#   probe3  {data, href, vsync, pclk} activity
#-----------------------------------------------------------------------------
create_ip -name ila -vendor xilinx.com -library ip -module_name ila_0

set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES     {4} \
    CONFIG.C_PROBE0_WIDTH      {32} \
    CONFIG.C_PROBE1_WIDTH      {8} \
    CONFIG.C_PROBE2_WIDTH      {5} \
    CONFIG.C_PROBE3_WIDTH      {4} \
    CONFIG.C_DATA_DEPTH        {4096} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.C_EN_STRG_QUAL      {1} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
] [get_ips ila_0]

generate_target all [get_ips ila_0]

update_compile_order -fileset sources_1

puts "INFO: project created at $build_dir/$proj_name"

#-----------------------------------------------------------------------------
# Optional build
#-----------------------------------------------------------------------------
if {$run_impl} {
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
        error "ERROR: synthesis failed - see $build_dir/$proj_name for the log"
    }

    launch_runs impl_1 -to_step write_bitstream -jobs 8
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
        error "ERROR: implementation failed - see $build_dir/$proj_name for the log"
    }

    set bit_src "$build_dir/$proj_name/$proj_name.runs/impl_1/$top_name.bit"
    file copy -force $bit_src "$build_dir/$proj_name.bit"
    puts "INFO: bitstream written to $build_dir/$proj_name.bit"

    open_run impl_1
    report_timing_summary -file "$build_dir/timing_summary.rpt"
    report_utilization    -file "$build_dir/utilization.rpt"
    puts "INFO: reports written to $build_dir"
}
