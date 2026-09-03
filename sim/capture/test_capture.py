"""cocotb tests for cam_capture writing into fb_mem.

This is the path that produced rainbow noise and coloured left edges on the
predecessor board, so the checks here are deliberately about those two bugs:

  * every captured pixel must carry the RGB565 value of the pixel it came from,
    which only holds if both bytes are read from registers rather than straight
    off the bus (docs/ov7670_notes.md, pitfall 1);
  * pixel 0 of each line must never be written, because the staging registers
    still hold the end of the previous line at that point (pitfall 4).

Frames here are small - the address arithmetic is the same 320-pixel stride the
real design uses, so a small frame simply fills the top-left corner of the
buffer, which is easier to check exhaustively.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

PCLK_PERIOD_NS = 40      # 25 MHz
RD_PERIOD_NS = 40

FB_STRIDE = 320


def src_rgb(x, y):
    """Test pattern: distinct per pixel, and different in all three channels.
    Channel widths follow RGB565."""
    return ((x + y) & 0x1F, (x * 3) & 0x3F, (y * 5 + 1) & 0x1F)


def rgb565_bytes(r, g, b):
    """The two bytes an OV7670 emits for one RGB565 pixel."""
    return (r << 3) | (g >> 3), ((g & 0x07) << 5) | b


def rgb565_word(r, g, b):
    hi, lo = rgb565_bytes(r, g, b)
    return (hi << 8) | lo


async def send_frame(dut, n_pixels, n_lines):
    """Drive one frame the way an OV7670 does: data changes on the PCLK falling
    edge, two bytes per pixel, HREF high for the active part of each line."""
    dut.vsync.value = 1
    dut.href.value = 0
    dut.data.value = 0
    await ClockCycles(dut.pclk, 4)
    dut.vsync.value = 0
    await ClockCycles(dut.pclk, 4)

    for y in range(n_lines):
        await FallingEdge(dut.pclk)
        dut.href.value = 1
        for x in range(n_pixels):
            hi, lo = rgb565_bytes(*src_rgb(x, y))
            dut.data.value = hi                   # byte 1: {R[4:0], G[5:3]}
            await FallingEdge(dut.pclk)
            dut.data.value = lo                   # byte 2: {G[2:0], B[4:0]}
            await FallingEdge(dut.pclk)
        dut.href.value = 0
        await ClockCycles(dut.pclk, 6)

    dut.vsync.value = 1
    await ClockCycles(dut.pclk, 4)
    dut.vsync.value = 0
    await ClockCycles(dut.pclk, 4)


def expected_buffer(n_pixels, n_lines):
    """What should be in the frame buffer: even pixels of even lines, with
    pixel 0 of each line skipped."""
    out = {}
    for y in range(0, n_lines, 2):
        for x in range(0, n_pixels, 2):
            if x < 1:
                continue                       # pixel_active guard
            if x + 1 >= n_pixels:
                continue                       # write lands on the next pixel
            addr = (y // 2) * FB_STRIDE + (x // 2)
            out[addr] = rgb565_word(*src_rgb(x, y))
    return out


async def read_fb(dut, addr):
    """Read one frame buffer word.

    The address has to be in place before the edge that latches it, and the
    registered output is only settled by the following falling edge - reading
    straight after RisingEdge returns the previous address's data.
    """
    dut.rd_addr.value = addr
    await RisingEdge(dut.rd_clk)     # address applied
    await RisingEdge(dut.rd_clk)     # data_rd latches mem[addr]
    await FallingEdge(dut.rd_clk)    # settled
    return int(dut.rd_data.value)


async def setup(dut):
    cocotb.start_soon(Clock(dut.pclk, PCLK_PERIOD_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.rd_clk, RD_PERIOD_NS, unit="ns").start())
    dut.href.value = 0
    dut.vsync.value = 0
    dut.data.value = 0
    dut.rd_addr.value = 0
    await ClockCycles(dut.pclk, 4)


@cocotb.test()
async def test_pixels_land_correctly(dut):
    """Every captured pixel carries the colour of the pixel it came from."""
    n_pixels, n_lines = 32, 8
    await setup(dut)
    await send_frame(dut, n_pixels, n_lines)

    expect = expected_buffer(n_pixels, n_lines)
    assert expect, "test would pass vacuously"

    for addr in sorted(expect):
        got = await read_fb(dut, addr)
        want = expect[addr]
        assert got == want, (
            f"frame buffer[{addr}] = 0x{got:04X}, expected 0x{want:04X} "
            f"(pixel x={(addr % FB_STRIDE) * 2}, y={(addr // FB_STRIDE) * 2})"
        )


@cocotb.test()
async def test_first_pixel_of_each_line_is_skipped(dut):
    """Column 0 is never written - that is the coloured-left-edge guard."""
    n_pixels, n_lines = 32, 8
    await setup(dut)

    written = set()

    async def watch_writes():
        while True:
            await RisingEdge(dut.pclk)
            if dut.cap_wr_en.value == 1:
                written.add(int(dut.cap_addr.value))

    task = cocotb.start_soon(watch_writes())
    await send_frame(dut, n_pixels, n_lines)
    task.cancel()

    assert written, "no writes were issued at all"
    for addr in written:
        assert addr % FB_STRIDE != 0, (
            f"address {addr} is in column 0, which the pixel_active guard "
            f"should have prevented"
        )


@cocotb.test()
async def test_odd_lines_are_dropped(dut):
    """Only even lines are captured - that is the 2:1 vertical downsample."""
    n_pixels, n_lines = 16, 8
    await setup(dut)

    rows = set()

    async def watch_writes():
        while True:
            await RisingEdge(dut.pclk)
            if dut.cap_wr_en.value == 1:
                rows.add(int(dut.cap_addr.value) // FB_STRIDE)

    task = cocotb.start_soon(watch_writes())
    await send_frame(dut, n_pixels, n_lines)
    task.cancel()

    assert rows == set(range(n_lines // 2)), (
        f"expected buffer rows {set(range(n_lines // 2))}, got {rows}"
    )


@cocotb.test()
async def test_vsync_resets_position(dut):
    """A second frame overwrites the first rather than continuing past it."""
    n_pixels, n_lines = 16, 4
    await setup(dut)

    await send_frame(dut, n_pixels, n_lines)
    await send_frame(dut, n_pixels, n_lines)

    expect = expected_buffer(n_pixels, n_lines)
    for addr in sorted(expect):
        got = await read_fb(dut, addr)
        assert got == expect[addr], (
            f"after two frames, buffer[{addr}] = 0x{got:04X}, "
            f"expected 0x{expect[addr]:04X}"
        )
