#=============================================================================
# create_project.tcl - regenerate a Vivado project for starfront-hdl
#
#   vivado -mode batch -source scripts/create_project.tcl -tclargs <mode> <variant>
#
#     mode      ""       create the project only
#               impl     also synthesise, implement and write the bitstream
#     variant   bringup  camera bring-up only (M0-M4), ENABLE_STARS = 0
#               tracker  bring-up plus the sub-pixel centroiding pipeline on
#                        the live camera and the star-field sensor profile
#                        (M7), ENABLE_STARS = 2. ENABLE_STARS = 1 is the older
#                        M5 peak detector, still buildable by editing this.
#               stream   no camera: the Zynq PS feeds frames in over
#                        AXI4-Stream, ENABLE_STARS = 2, SIM_CAM_ONLY = 1.
#                        Aliases: sim, tracker_sim, ps
#               bench    no camera: replays stored star fields through the
#                        centroiding pipeline, a different top and XDC
#
# Use scripts/build.sh rather than calling this directly.
#
# The variants are separate projects and separate bitstreams built from one
# source tree, so the plain camera bring-up stays available for demonstration
# without rebuilding it every time the star work moves.
#
# Nothing under build/ is version controlled: the projects, both IP cores and
# the bitstreams are all reproduced from this script plus rtl/ and constraints/.
#=============================================================================

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

# Each variant is a top, a constraint file, a set of generics, and whether the
# Zynq PS block design is built. Aliases are folded onto one canonical name so
# that two spellings cannot produce two build/ directories for one bitstream.
set has_ps 0

switch -- $variant {
    bringup {
        set top_name  "top_starfront"
        set xdc_file  "ax7010_starfront.xdc"
        set generics  "ENABLE_STARS=0 SIM_CAM_ONLY=0"
    }
    tracker {
        set top_name  "top_starfront"
        set xdc_file  "ax7010_starfront.xdc"
        set generics  "ENABLE_STARS=2 SIM_CAM_ONLY=0"
    }
    stream -
    sim -
    tracker_sim -
    ps {
        set variant   "stream"
        set top_name  "top_starfront"
        set xdc_file  "ax7010_starfront.xdc"
        set generics  "ENABLE_STARS=2 SIM_CAM_ONLY=1"
        set has_ps    1
    }
    bench {
        set top_name  "top_starfront_bench"
        set xdc_file  "ax7010_bench.xdc"
        set generics  ""
    }
    default {
        error "ERROR: unknown variant '$variant' - expected bringup, tracker, stream or bench"
    }
}
}

set proj_name "starfront_$variant"

puts "INFO: variant $variant (top $top_name, $xdc_file, generics {$generics}, PS $has_ps)"

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
add_files -fileset constrs_1 -norecurse $repo_dir/constraints/$xdc_file

# The frame store is initialised with $readmemh at elaboration. Vivado resolves
# that filename against the files in the project, so the memory file has to be
# added like any other source - without it the store falls back to the
# synthetic field frame_source.v writes first, which looks plausible and is not
# the data anyone wanted.
if {[string equal $variant "bench"]} {
    set mem_file "$build_dir/frames.mem"
    if {[file exists $mem_file]} {
        add_files -norecurse $mem_file
        set_property file_type {Memory Initialization Files} [get_files $mem_file]
        puts "INFO: frame store loads $mem_file"
    } else {
        puts "WARNING: $mem_file not found - the bitstream will hold a synthetic"
        puts "WARNING: star field. Run bench/prepare_frames.py to load real data."
    }
}

set_property top $top_name [current_fileset]
if {[string length $generics] > 0} {
    set_property generic $generics [current_fileset]
}

# The PS is instantiated only by the stream variant. Every other build is
# PL-only and compiles top_starfront with NO_PS defined, which stubs the
# wrapper out - otherwise synthesis stops on a module it has no source for.
if {$has_ps} {
    puts "INFO: generating the ax7010_PS block design from scripts/ax7010_ps_bd.tcl"
    source "$repo_dir/scripts/ax7010_ps_bd.tcl"
    make_wrapper -files [get_files ax7010_PS.bd] -top -import
} else {
    set_property verilog_define [list NO_PS=1] [current_fileset]
}
}

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

#-----------------------------------------------------------------------------
# jtag_axi_0 - an AXI4 master driven from the host over the same USB JTAG cable
# that carries the bitstream. Only the bench variant has anywhere to put it.
#
# This is the only route a PL-only design on this board has to bulk data: the
# 32 MB QSPI flash is on PS_MIO0-6 and the Zynq's Quad-SPI controller is
# MIO-only, so the PL cannot reach it, and the only other memory on the PL side
# is a 512-byte I2C EEPROM.
#-----------------------------------------------------------------------------
if {[string equal $variant "bench"]} {
    create_ip -name jtag_axi -vendor xilinx.com -library ip -module_name jtag_axi_0

    set_property -dict [list \
        CONFIG.PROTOCOL         {0} \
        CONFIG.M_AXI_DATA_WIDTH {32} \
        CONFIG.M_AXI_ADDR_WIDTH {32} \
        CONFIG.M_HAS_BURST      {1} \
    ] [get_ips jtag_axi_0]

    generate_target all [get_ips jtag_axi_0]
}

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

    if {$has_ps} {
        file mkdir "$build_dir/ax7010_ps"
        write_hw_platform -fixed -include_bit -force -file "$build_dir/ax7010_ps/ax7010_ps_wrapper.xsa"
        puts "INFO: hardware platform exported to $build_dir/ax7010_ps/ax7010_ps_wrapper.xsa"
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
