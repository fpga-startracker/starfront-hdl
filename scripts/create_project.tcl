#=============================================================================
# create_project.tcl - regenerate a Vivado project for starfront-hdl
#
#   vivado -mode batch -source scripts/create_project.tcl -tclargs <mode> <variant>
#
#     mode      ""       create the project only
#               impl     also synthesise, implement and write the bitstream
#     variant   bringup  camera bring-up only (M0-M4), ENABLE_STARS = 0
#               tracker  bring-up plus the streaming star detector (M5)
#
# Use scripts/build.sh rather than calling this directly.
#
# The two variants are separate projects and separate bitstreams built from one
# source tree, so the plain camera bring-up stays available for demonstration
# without rebuilding it every time the star work moves.
#
# Nothing under build/ is version controlled: the projects, both IP cores and
# the bitstreams are all reproduced from this script plus rtl/ and constraints/.
#=============================================================================

set top_name  "top_starfront"
set part_name "xc7z010clg400-1"

set script_dir [file dirname [file normalize [info script]]]
set repo_dir   [file dirname $script_dir]
set build_dir  "$repo_dir/build"

set run_impl 0
if {[llength $argv] > 0 && [string equal [lindex $argv 0] "impl"]} {
    set run_impl 1
}

set variant "tracker"
if {[llength $argv] > 1 && [string length [lindex $argv 1]] > 0} {
    set variant [lindex $argv 1]
}

switch -- $variant {
    bringup { set enable_stars 0 }
    tracker { set enable_stars 1 }
    default { error "ERROR: unknown variant '$variant' - expected bringup or tracker" }
}

set proj_name "starfront_$variant"

puts "INFO: variant $variant (ENABLE_STARS = $enable_stars)"

file mkdir $build_dir

#-----------------------------------------------------------------------------
# Project
#-----------------------------------------------------------------------------
create_project -force $proj_name $build_dir/$proj_name -part $part_name

#-----------------------------------------------------------------------------
# Sources
#
# Every .v under rtl/ goes in, and the result is verified rather than assumed:
# a module missing from the project shows up as a confusing elaboration error
# much later, or - worse - as a project that builds from this script but looks
# half empty when opened in the GUI.
#-----------------------------------------------------------------------------
set rtl_files [lsort [glob -nocomplain $repo_dir/rtl/*.v]]

if {[llength $rtl_files] == 0} {
    error "ERROR: no .v files found in $repo_dir/rtl"
}

add_files -norecurse $rtl_files
add_files -fileset constrs_1 -norecurse $repo_dir/constraints/ax7010_starfront.xdc

set_property top $top_name [current_fileset]
set_property generic "ENABLE_STARS=$enable_stars" [current_fileset]

set in_project {}
foreach f [get_files -of_objects [get_filesets sources_1]] {
    lappend in_project [file tail $f]
}

set missing {}
foreach f $rtl_files {
    if {[lsearch -exact $in_project [file tail $f]] < 0} {
        lappend missing [file tail $f]
    }
}

if {[llength $missing] > 0} {
    error "ERROR: these RTL files did not make it into the project: $missing"
}

puts "INFO: [llength $rtl_files] RTL sources added:"
foreach f $rtl_files {
    puts "INFO:   [file tail $f]"
}

#-----------------------------------------------------------------------------
# clk_wiz_0 - 50 MHz PL_GCLK in, 125 MHz TMDS serial + 25 MHz pixel out.
#
# Both outputs come from the same MMCM, which is what keeps clk_ser phase
# aligned with clk_pix for the 10:1 OSERDES pair.
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
#   probe4  {bright_y, bright_x, frame_max, threshold, star_count}
#
# Depth is deliberately small. ILA storage is depth x total probe width, and at
# 4096 deep the ~93 bits of probe here cost eleven BRAM tiles - which, on top of
# the 48 the frame buffer needs, left the design at 97.5% of the device. 1024 is
# 41 us of history at 25 MHz; the useful thing about these probes is the latched
# state at the trigger, not the run-up to it.
#-----------------------------------------------------------------------------
create_ip -name ila -vendor xilinx.com -library ip -module_name ila_0

set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES     {5} \
    CONFIG.C_PROBE0_WIDTH      {32} \
    CONFIG.C_PROBE1_WIDTH      {8} \
    CONFIG.C_PROBE2_WIDTH      {5} \
    CONFIG.C_PROBE3_WIDTH      {4} \
    CONFIG.C_PROBE4_WIDTH      {44} \
    CONFIG.C_DATA_DEPTH        {1024} \
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

    # Copy the bitstream and the ILA probe file out of the run directory, which
    # a later `create_project -force` would delete. scripts/program.tcl uses
    # these copies, so regenerating a project never breaks programming.
    set run_dir "$build_dir/$proj_name/$proj_name.runs/impl_1"
    file copy -force "$run_dir/$top_name.bit" "$build_dir/$proj_name.bit"
    puts "INFO: bitstream written to $build_dir/$proj_name.bit"

    if {[file exists "$run_dir/$top_name.ltx"]} {
        file copy -force "$run_dir/$top_name.ltx" "$build_dir/$proj_name.ltx"
        puts "INFO: ILA probes written to $build_dir/$proj_name.ltx"
    }

    open_run impl_1
    report_timing_summary -file "$build_dir/${proj_name}_timing.rpt"
    report_utilization    -file "$build_dir/${proj_name}_utilization.rpt"
    puts "INFO: reports written to $build_dir"
}

#-----------------------------------------------------------------------------
# close_project is what actually flushes the .xpr to disk. Without it Vivado
# writes the project file whenever it feels like it, which is how six sources
# once ended up missing from a project that had built them perfectly well.
#
# The marker on the last line is how build.sh tells a real completion from a
# Tcl error: Vivado batch mode exits 0 even when a script aborts half way.
#-----------------------------------------------------------------------------
close_project

puts "INFO: BUILD COMPLETE"
