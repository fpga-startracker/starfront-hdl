#=============================================================================
# feed_video.tcl - stream frames into the board and read the star list back
#
#   vivado -mode batch -source scripts/feed_video.tcl -tclargs <dir> [count] [out.csv]
#
#   <dir>     a directory of .mem files written by bench/export_stream.py,
#             played in name order
#   count     how many to send, 0 or absent = all of them
#   out.csv   where to write the star lists the board reports back
#
# This is the only route a PL-only design on this board has to bulk data. The
# AX7010's 32 MB QSPI flash sits on PS_MIO0-6 and the Zynq's Quad-SPI controller
# is MIO-only, so the PL cannot reach it; the only other memory on the PL side
# is a 512-byte I2C EEPROM. Everything therefore comes over the same USB JTAG
# cable that carries the bitstream, which is slow - expect a few frames a second
# - but it is a real stream of different images, and more to the point it brings
# the star list back, so the board can be scored against the DUST truth instead
# of read off the screen.
#
# Use scripts/stream_video.sh rather than calling this directly.
#=============================================================================

set FB_BASE   0x00000000
set LIST_BASE 0x00010000
set REG_BASE  0x00020000
set MAGIC     0x53544652

set WORDS_PER_FRAME 16384
set BURST           256           ;# words per AXI transaction, the AXI4 maximum
set N_STARS         64

proc usage {} {
    puts "usage: vivado -mode batch -source scripts/feed_video.tcl \\"
    puts "         -tclargs <frame-dir> \[count\] \[out.csv\]"
    exit 1
}

if {[llength $argv] < 1} { usage }
set frame_dir [lindex $argv 0]
set want      [expr {[llength $argv] > 1 ? [lindex $argv 1] : 0}]
set out_csv   [expr {[llength $argv] > 2 ? [lindex $argv 2] : ""}]

set frames [lsort [glob -nocomplain $frame_dir/*.mem]]
if {[llength $frames] == 0} {
    puts "ERROR: no .mem files in $frame_dir - run bench/export_stream.py first"
    exit 1
}
if {$want > 0 && $want < [llength $frames]} {
    set frames [lrange $frames 0 [expr {$want - 1}]]
}

#-----------------------------------------------------------------------------
# Connect
#-----------------------------------------------------------------------------
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set dev ""
foreach d [get_hw_devices] {
    if {[string match "xc7z010*" $d]} { set dev $d }
}
if {$dev eq ""} {
    error "ERROR: no xc7z010 on the JTAG chain - devices seen: [get_hw_devices]"
}
current_hw_device $dev

# The probe file has to be attached and the device refreshed *with* probes, or
# the debug cores are never scanned and the JTAG-to-AXI master does not appear
# at all - which reads as "no master on the device" and looks exactly like the
# wrong bitstream being loaded.
set ltx "[file dirname [file normalize [info script]]]/../build/starfront_bench.ltx"
if {[file exists $ltx]} {
    set_property PROBES.FILE      $ltx $dev
    set_property FULL_PROBES.FILE $ltx $dev
}
refresh_hw_device $dev

set axi [lindex [get_hw_axis] 0]
if {$axi eq ""} {
    puts "ERROR: no JTAG-to-AXI master found on the device."
    puts "       The bench bitstream must be loaded first: ./scripts/program.sh bench"
    exit 1
}
puts "INFO: using $axi"

#-----------------------------------------------------------------------------
# A read returns its beats concatenated into one hex string, most recently
# received first, so the words come back in reverse order. Splitting and
# reversing here is less error-prone than remembering it at every call site.
#-----------------------------------------------------------------------------
proc axi_read {axi addr nwords} {
    # -force rather than deleting first: there is no delete_hw_axi_txns in
    # 2025.2, and a transaction that already exists is exactly what we want to
    # overwrite anyway.
    create_hw_axi_txn rd_txn $axi -force -address [format %08x $addr] \
        -len $nwords -type read
    run_hw_axi -quiet rd_txn
    set raw [get_property DATA [get_hw_axi_txns rd_txn]]
    set out {}
    for {set i 0} {$i < $nwords} {incr i} {
        lappend out [string range $raw [expr {$i * 8}] [expr {$i * 8 + 7}]]
    }
    return [lreverse $out]
}

proc axi_write {axi addr words} {
    create_hw_axi_txn wr_txn $axi -force -address [format %08x $addr] \
        -len [llength $words] -type write -data $words
    run_hw_axi -quiet wr_txn
}

#-----------------------------------------------------------------------------
# Prove the link before sending a megabyte down it. If the magic register does
# not read back, nothing after this point means anything - and a silent wrong
# answer here looks exactly like a working stream of black frames.
#-----------------------------------------------------------------------------
set got [lindex [axi_read $axi $REG_BASE 1] 0]
if {[format %08x $MAGIC] ne [string tolower $got]} {
    puts "ERROR: magic register read back as 0x$got, expected [format %08x $MAGIC]."
    puts "       Either the bench bitstream is not loaded, or the word order out"
    puts "       of get_property DATA differs on this Vivado - check axi_read."
    exit 1
}
puts "INFO: link verified, magic reads back correctly"

# Take the controls away from the keys, and stop the free-running scroll so the
# only thing changing is the frames being sent.
axi_write $axi [expr {$REG_BASE + 0x20}] [list 00000008]

#-----------------------------------------------------------------------------
# Walk the scroll back to zero.
#
# Turning the scroll off stops it moving; it does not move it back, and by the
# time a host connects it has usually drifted somewhere. That matters more than
# a constant offset would: an offset that is not a multiple of four resamples
# the binned image - three parts of one sensor pixel and one of the next - so
# the frame the detector sees is not quite the frame that was sent, and its
# centroids carry the S-curve of that quarter-pixel shift. Stepping is the only
# control there is, so step until the register reads zero.
#-----------------------------------------------------------------------------
proc read_scroll {axi base} {
    set v 0x[lindex [axi_read $axi [expr {$base + 0x14}] 1] 0]
    return [expr {($v & 0x40) ? (($v & 0x7f) - 128) : ($v & 0x7f)}]
}

set sc [read_scroll $axi $REG_BASE]
set tries 0
while {$sc != 0 && $tries < 200} {
    axi_write $axi [expr {$REG_BASE + 0x20}] [list 00000018]   ;# override + step
    set sc [read_scroll $axi $REG_BASE]
    incr tries
}
if {$sc != 0} {
    puts "WARNING: scroll would not return to zero, stuck at $sc"
} else {
    puts "INFO: scroll zeroed in $tries steps"
}

#-----------------------------------------------------------------------------
# Stream
#-----------------------------------------------------------------------------
set rows {}
set t0 [clock milliseconds]
set n 0

foreach f $frames {
    set fh [open $f r]
    set words [split [string trim [read $fh]] "\n"]
    close $fh
    if {[llength $words] != $WORDS_PER_FRAME} {
        puts "ERROR: $f has [llength $words] words, expected $WORDS_PER_FRAME"
        exit 1
    }

    for {set w 0} {$w < $WORDS_PER_FRAME} {incr w $BURST} {
        axi_write $axi [expr {$FB_BASE + $w * 4}] \
            [lrange $words $w [expr {$w + $BURST - 1}]]
    }

    # Swap at the next frame boundary, then wait for the detector to have run on
    # it. The background followers settle over about four frames, so five is a
    # frame of margin; at 24 fps that is 210 ms.
    axi_write $axi [expr {$REG_BASE + 0x20}] [list 00000009]

    # A hex string has to become a value before expr sees it - "0x[...]" inside
    # expr braces is a parse error, not a number.
    set fc0 0x[lindex [axi_read $axi [expr {$REG_BASE + 8}] 1] 0]
    while {1} {
        set fc 0x[lindex [axi_read $axi [expr {$REG_BASE + 8}] 1] 0]
        if {(($fc - $fc0) & 0xffff) >= 5} break
    }

    # The scroll offset is not zeroed when the host takes the controls - turning
    # the scroll off stops it moving, it does not move it back - so whatever it
    # had drifted to is still shifting the image. Report it and let the scorer
    # subtract it rather than pretending it is zero.
    set sc 0x[lindex [axi_read $axi [expr {$REG_BASE + 0x14}] 1] 0]
    set scroll [expr {($sc & 0x40) ? (($sc & 0x7f) - 128) : ($sc & 0x7f)}]

    set st 0x[lindex [axi_read $axi [expr {$REG_BASE + 4}] 1] 0]
    set nstar   [expr {$st & 0x7f}]
    set ndrop   [expr {($st >> 8) & 0x7f}]
    set ovf     [expr {($st >> 16) & 0x1}]

    set name [file rootname [file tail $f]]
    puts [format "%-28s stars %3d  dropped %2d  full %d  scroll %+d" \
        $name $nstar $ndrop $ovf $scroll]

    if {$out_csv ne "" && $nstar > 0} {
        set d [axi_read $axi $LIST_BASE [expr {$nstar * 2}]]
        for {set i 0} {$i < $nstar} {incr i} {
            set w0 0x[lindex $d [expr {$i * 2}]]
            set w1 0x[lindex $d [expr {$i * 2 + 1}]]
            lappend rows [format "%s,%d,%d,%d,%d,%d,%d" $name $i \
                [expr {$w0 & 0xffff}] [expr {($w0 >> 16) & 0xffff}] \
                [expr {$w1 & 0xfffff}] [expr {($w1 >> 20) & 0x7f}] $scroll]
        }
    }
    incr n
}

set dt [expr {([clock milliseconds] - $t0) / 1000.0}]
puts [format "\n%d frames in %.1f s = %.2f frames/s" $n $dt [expr {$n / $dt}]]

if {$out_csv ne ""} {
    set fh [open $out_csv w]
    puts $fh "frame,index,x_fix,y_fix,sum_i,npx,scroll"
    foreach r $rows { puts $fh $r }
    close $fh
    puts "star lists -> $out_csv  ([llength $rows] stars)"
}

# Hand the controls back to the keys on the way out.
axi_write $axi [expr {$REG_BASE + 0x20}] [list 00000000]
close_hw_manager
puts "INFO: STREAM COMPLETE"
