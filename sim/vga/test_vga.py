"""cocotb tests for vga_sync_gen (640x480 @ 60 Hz from a 25 MHz pixel clock).

Ported from the Basys 3 project. The timing numbers are unchanged - what is
new is checking that the active-HIGH sync outputs added for the DVI
transmitter really are the inverse of the VGA-polarity ones, since feeding
dvi_tx the wrong polarity gives a picture that rolls or refuses to sync.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 40  # 25 MHz

H_TOTAL, H_DISPLAY, H_SYNC = 800, 640, 96
V_TOTAL, V_DISPLAY, V_SYNC = 521, 480, 2


async def start_and_reset(dut):
    cocotb.start_soon(Clock(dut.clk_pix, CLK_PERIOD_NS, unit="ns").start())
    dut.rst.value = 1
    await ClockCycles(dut.clk_pix, 5)
    dut.rst.value = 0
    await RisingEdge(dut.clk_pix)


@cocotb.test()
async def test_line_and_frame_length(dut):
    """One line is 800 clocks and one frame is 521 lines."""
    await start_and_reset(dut)

    # Line up on the start of a frame
    while not (int(dut.vga_pixel_x.value) == 0 and int(dut.vga_pixel_y.value) == 0):
        await RisingEdge(dut.clk_pix)

    x_max = 0
    y_max = 0
    frame_ticks = 0
    for _ in range(H_TOTAL * V_TOTAL):
        await RisingEdge(dut.clk_pix)
        x_max = max(x_max, int(dut.vga_pixel_x.value))
        y_max = max(y_max, int(dut.vga_pixel_y.value))
        if dut.vga_frame_tick.value == 1:
            frame_ticks += 1

    assert x_max == H_TOTAL - 1, f"pixel_x should top out at {H_TOTAL - 1}, got {x_max}"
    assert y_max == V_TOTAL - 1, f"pixel_y should top out at {V_TOTAL - 1}, got {y_max}"
    assert frame_ticks == 1, f"expected exactly one frame tick per frame, got {frame_ticks}"


@cocotb.test()
async def test_sync_pulse_widths(dut):
    """HSYNC is 96 clocks and VSYNC is 2 lines, both in the right place."""
    await start_and_reset(dut)

    hsync_high = 0
    vsync_lines = 0
    prev_vsync = 0
    active_pixels = 0

    while not (int(dut.vga_pixel_x.value) == 0 and int(dut.vga_pixel_y.value) == 0):
        await RisingEdge(dut.clk_pix)

    for _ in range(H_TOTAL * V_TOTAL):
        await RisingEdge(dut.clk_pix)
        if int(dut.vga_pixel_y.value) == 0 and dut.vga_hsync_p.value == 1:
            hsync_high += 1
        vsync = int(dut.vga_vsync_p.value)
        if vsync and not prev_vsync:
            vsync_lines = 1
        elif vsync and int(dut.vga_pixel_x.value) == 0:
            vsync_lines += 1
        prev_vsync = vsync
        if dut.vga_active.value == 1:
            active_pixels += 1

    assert hsync_high == H_SYNC, f"HSYNC should be {H_SYNC} clocks, got {hsync_high}"
    assert vsync_lines == V_SYNC, f"VSYNC should be {V_SYNC} lines, got {vsync_lines}"
    assert active_pixels == H_DISPLAY * V_DISPLAY, (
        f"active area should be {H_DISPLAY * V_DISPLAY} pixels, got {active_pixels}"
    )


@cocotb.test()
async def test_sync_polarities_are_opposite(dut):
    """The DVI-polarity outputs are the inverse of the VGA-polarity ones."""
    await start_and_reset(dut)

    for _ in range(H_TOTAL * 4):
        await RisingEdge(dut.clk_pix)
        assert int(dut.vga_hsync.value) == 1 - int(dut.vga_hsync_p.value)
        assert int(dut.vga_vsync.value) == 1 - int(dut.vga_vsync_p.value)
