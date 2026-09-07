#=============================================================================
# program.tcl - load the bitstream onto the AX7010 over the on-board USB JTAG
#
#   vivado -mode batch -source scripts/program.tcl
#
# Equivalent to Hardware Manager -> Auto Connect -> Program Device, but without
# any clicking. The ILA probe file is attached at the same time, so opening the
# Hardware Manager GUI afterwards finds the debug cores already described.
#
# Set the J13 jumper to the JTAG position (the two right-hand pins) first, so
# the PS does not boot from SD or QSPI and reconfigure the PL underneath you.
#=============================================================================

set script_dir [file dirname [file normalize [info script]]]
set repo_dir   [file dirname $script_dir]
set build_dir  "$repo_dir/build"
set run_dir    "$build_dir/starfront_bringup/starfront_bringup.runs/impl_1"

# Prefer the copies in build/, which survive a `create_project -force`; fall
# back to the run directory for a project that has just been built in place.
set bit_file "$build_dir/starfront_bringup.bit"
set ltx_file "$build_dir/starfront_bringup.ltx"

if {![file exists $bit_file]} {
    set bit_file "$run_dir/top_starfront_bringup.bit"
    set ltx_file "$run_dir/top_starfront_bringup.ltx"
}

if {![file exists $bit_file]} {
    error "ERROR: no bitstream found - run ./scripts/build.sh impl first"
}

open_hw_manager
connect_hw_server
open_hw_target

# A Zynq JTAG chain shows the ARM DAP as well as the PL device; we want the PL.
set pl_devices [lsearch -all -inline [get_hw_devices] "xc7z010*"]
if {[llength $pl_devices] == 0} {
    error "ERROR: no xc7z010 found on the JTAG chain - devices seen: [get_hw_devices]"
}
set dev [lindex $pl_devices 0]

current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set_property PROGRAM.FILE      $bit_file $dev
if {[file exists $ltx_file]} {
    set_property PROBES.FILE      $ltx_file $dev
    set_property FULL_PROBES.FILE $ltx_file $dev
}

program_hw_devices $dev
refresh_hw_device $dev

puts "INFO: programmed [get_property PART $dev] with $bit_file"
puts "INFO: LED1 should now be blinking at about 1.5 Hz"
