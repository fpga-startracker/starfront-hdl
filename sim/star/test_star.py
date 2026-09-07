"""cocotb tests for star_detect, the streaming full-resolution star finder.

The detector never sees a whole frame - it works from a five row window slid
along the pixel stream - so these tests feed synthetic frames pixel by pixel in
raster order and check what comes out at the frame boundary.

What is actually being pinned down:
  * a bright spot is found, at the right coordinates;
  * a saturated star, whose core is flat, is reported once and not as a
    cluster of adjacent peaks - which is what a plain >= comparison would do;
  * the adaptive threshold follows the previous frame, so a dim frame does not
    fill up with noise detections.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

CLK_NS = 40
W, H = 64, 40
BACKGROUND = 10
MIN_THRESH = 40


def blank_frame():
    return [[BACKGROUND] * W for _ in range(H)]


def put_star(frame, x, y, peak, halo=None):
    """A star: bright core with a dimmer ring, the way a defocused point looks."""
    if halo is None:
        halo = peak // 3
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if 0 <= y + dy < H and 0 <= x + dx < W:
                frame[y + dy][x + dx] = max(frame[y + dy][x + dx], halo)
    frame[y][x] = peak


async def setup(dut):
    cocotb.start_soon(Clock(dut.pclk, CLK_NS, unit="ns").start())
    dut.rst.value = 1
    dut.pix_valid.value = 0
    dut.pix_x.value = 0
    dut.pix_y.value = 0
    dut.pix_luma.value = 0
    dut.frame_start.value = 0
    await ClockCycles(dut.pclk, 5)
    dut.rst.value = 0
    await ClockCycles(dut.pclk, 5)


async def send_frame(dut, frame):
    """One frame, raster order, with a gap between lines like HREF blanking."""
    for y in range(H):
        for x in range(W):
            dut.pix_valid.value = 1
            dut.pix_x.value = x
            dut.pix_y.value = y
            dut.pix_luma.value = frame[y][x]
            await RisingEdge(dut.pclk)
        dut.pix_valid.value = 0
        await ClockCycles(dut.pclk, 3)


async def end_frame(dut):
    """Pulse frame_start, which publishes the frame that just finished."""
    dut.frame_start.value = 1
    await RisingEdge(dut.pclk)
    dut.frame_start.value = 0
    await FallingEdge(dut.pclk)


@cocotb.test()
async def test_finds_a_single_star(dut):
    """One bright spot is found once, at its own coordinates."""
    await setup(dut)
    await end_frame(dut)

    frame = blank_frame()
    put_star(frame, 20, 15, peak=200)

    await send_frame(dut, frame)
    await end_frame(dut)

    count = int(dut.star_count.value)
    assert count == 1, f"expected exactly one star, got {count}"
    assert int(dut.bright_x.value) == 20, f"x should be 20, got {int(dut.bright_x.value)}"
    assert int(dut.bright_y.value) == 15, f"y should be 15, got {int(dut.bright_y.value)}"
    assert int(dut.frame_max.value) == 200


@cocotb.test()
async def test_finds_several_and_picks_the_brightest(dut):
    """Three stars are counted, and the brightest one is the one reported."""
    await setup(dut)
    await end_frame(dut)

    frame = blank_frame()
    put_star(frame, 12, 10, peak=120)
    put_star(frame, 40, 18, peak=220)      # the brightest
    put_star(frame, 25, 30, peak=150)

    await send_frame(dut, frame)
    await end_frame(dut)

    count = int(dut.star_count.value)
    assert count == 3, f"expected three stars, got {count}"
    assert int(dut.bright_x.value) == 40 and int(dut.bright_y.value) == 18, (
        f"brightest should be (40, 18), got "
        f"({int(dut.bright_x.value)}, {int(dut.bright_y.value)})"
    )


@cocotb.test()
async def test_saturated_core_counts_once(dut):
    """A flat-topped star is one detection, not a plateau of them."""
    await setup(dut)
    await end_frame(dut)

    frame = blank_frame()
    # A 3x3 core all at 255 - exactly what a bright star clips to
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            frame[20 + dy][30 + dx] = 255
    for dy in (-2, 2):
        for dx in range(-2, 3):
            frame[20 + dy][30 + dx] = 90
            frame[20 + dx][30 + dy] = 90

    await send_frame(dut, frame)
    await end_frame(dut)

    count = int(dut.star_count.value)
    assert count == 1, (
        f"a saturated 3x3 core should be one star, got {count} - the raster "
        f"tie-break in the peak test is not working"
    )


@cocotb.test()
async def test_threshold_follows_the_scene(dut):
    """The threshold is half the previous frame's peak, with a floor."""
    await setup(dut)
    await end_frame(dut)

    # A dark frame: nothing above the floor, so the floor is what is used
    await send_frame(dut, blank_frame())
    await end_frame(dut)
    assert int(dut.threshold.value) == MIN_THRESH, (
        f"a dark frame should leave the threshold at its floor, got "
        f"{int(dut.threshold.value)}"
    )
    assert int(dut.star_count.value) == 0, "a flat frame has no stars"

    # A bright frame: the threshold should rise to half its peak
    frame = blank_frame()
    put_star(frame, 20, 15, peak=200)
    await send_frame(dut, frame)
    await end_frame(dut)
    assert int(dut.threshold.value) == 100, (
        f"threshold should be 200/2, got {int(dut.threshold.value)}"
    )


@cocotb.test()
async def test_dim_star_is_rejected_once_threshold_rises(dut):
    """A star below half the frame peak is not reported."""
    await setup(dut)
    await end_frame(dut)

    frame = blank_frame()
    put_star(frame, 20, 15, peak=240)      # sets the threshold to 120
    put_star(frame, 45, 25, peak=80)       # below it on the next frame
    await send_frame(dut, frame)
    await end_frame(dut)
    assert int(dut.star_count.value) == 2, "both are above the floor on frame one"

    await send_frame(dut, frame)
    await end_frame(dut)
    assert int(dut.star_count.value) == 1, (
        f"with the threshold at 120 only the bright star should survive, got "
        f"{int(dut.star_count.value)}"
    )
