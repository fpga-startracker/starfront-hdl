"""star_centroid against the software model, star for star and bit for bit.

The model in bench/starfront_model.py is what the accuracy numbers are measured
with, over hundreds of frames. That only means anything if the hardware computes
the same thing, so this drives the RTL with the same pixels and demands the same
star list - identical count, identical fixed-point coordinates, identical flux.
Nothing here is a tolerance: an integer pipeline either agrees or it has a bug.

Three frames are fed for each case, because the background followers deliberately
carry state across frame boundaries and only the settled state is representative.
The hardware ignores the first frame after reset by design - it starts at the
first frame boundary once bg_track's reset sweep has finished - so the model is
run one time fewer against the same tracker state, and the two must then agree
on the last frame.

A real DUST frame is used when STARFRONT_DATA points at the display set;
otherwise a synthetic field stands in, so the test still runs on a machine that
does not have the data.

With STARFRONT_GEOM=cam the runner builds the DUT at the camera's 640x480 with
the field-of-view mask off, and the synthetic frame is generated at that size
with a flat sky - the model is shape-agnostic, so the same comparison holds.
"""
import os
import sys
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bench"))

from dataclasses import replace  # noqa: E402

from starfront_model import (DEFAULT, TrackerState, bin_nxn,  # noqa: E402
                             detect, load_png)

CAM = os.getenv("STARFRONT_GEOM", "") == "cam"
IMG_W, IMG_H = (640, 480) if CAM else (256, 256)
PARAMS = replace(DEFAULT, fov_r=0, fov_cx=320, fov_cy=240) if CAM else DEFAULT

N_WARM = 3                   # frames fed before the answer is taken; the
                             # hardware skips the first (see above), so two
                             # are tracked
TAIL = 200                   # idle cycles after a frame, to drain the engine


def synthetic_frame(seed: int = 7) -> np.ndarray:
    """A star field with the shape of a DUST frame: vignetted disc, sky noise,
    a handful of stars with the sensor's leftward smear tail. At the camera
    geometry the sky is flat and the field is not masked."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:IMG_H, 0:IMG_W]

    if CAM:
        img = 22.0 + 0.01 * xx + rng.normal(0.0, 1.5, (IMG_H, IMG_W))
        n_stars = 40
    else:
        r = np.hypot(xx - 128, yy - 128)
        img = np.where(r <= 120, 84.0 - 0.11 * (xx - 8), 4.0)
        img += rng.normal(0.0, 1.2, img.shape)
        n_stars = 20

    for _ in range(n_stars):
        sx = int(rng.integers(30, IMG_W - 30))
        sy = int(rng.integers(30, IMG_H - 30))
        amp = float(rng.uniform(40, 160))
        for dy in range(-2, 3):
            for dx in range(-6, 3):
                # symmetric core, exponential tail toward -x
                g = np.exp(-((dx * dx) / 1.6 + (dy * dy) / 1.2))
                t = 0.5 ** (-dx) if dx < 0 else 0.0
                img[sy + dy, sx + dx] += amp * max(g, t * 0.45 * np.exp(-dy * dy / 1.2))

    return np.clip(np.round(img), 0, 255).astype(np.int32)


def real_frame() -> np.ndarray | None:
    root = os.getenv("STARFRONT_DATA")
    if not root:
        return None
    imgs = sorted(Path(root, "images").glob("*.png"))
    if not imgs:
        return None
    return bin_nxn(load_png(imgs[0])).astype(np.int32)


async def feed_frame(dut, code: np.ndarray):
    """One raster of the binned frame, one pixel per clock."""
    dut.in_valid.value = 0
    dut.frame_start.value = 1
    await RisingEdge(dut.clk)
    dut.frame_start.value = 0
    await RisingEdge(dut.clk)

    for y in range(IMG_H):
        for x in range(IMG_W):
            dut.in_valid.value = 1
            dut.in_x.value = x
            dut.in_y.value = y
            dut.in_code.value = int(code[y, x])
            await RisingEdge(dut.clk)

    dut.in_valid.value = 0
    for _ in range(TAIL):
        await RisingEdge(dut.clk)


async def read_list(dut, n: int):
    """The published bank, read through the display port."""
    out = []
    for i in range(n):
        dut.rd_addr.value = i
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)     # settled, and unambiguous with the writes
        out.append((int(dut.rd_x.value), int(dut.rd_y.value),
                    int(dut.rd_sum.value)))
    return out


async def run_case(dut, code: np.ndarray, label: str):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    dut.rst.value = 1
    dut.in_valid.value = 0
    dut.frame_start.value = 0
    dut.rd_addr.value = 0
    dut.fov_ox.value = 0          # the frame source is not scrolling here
    dut.fov_oy.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    for _ in range(N_WARM):
        await feed_frame(dut, code)

    # The count published on the last frame_start belongs to the last frame fed.
    dut.frame_start.value = 1
    await RisingEdge(dut.clk)
    dut.frame_start.value = 0
    await RisingEdge(dut.clk)

    n_hw = int(dut.star_count.value)
    dropped = int(dut.dropped.value)
    hw = await read_list(dut, n_hw)

    st = TrackerState()
    for _ in range(N_WARM - 1):          # the hardware ignores the first frame
        res = detect(code, PARAMS, st)
    sw = [(s.x_fix, s.y_fix, s.sum_i) for s in res.stars]

    dut._log.info(f"{label}: hardware {n_hw} stars ({dropped} dropped), "
                  f"model {len(sw)}")
    for i, (h, s) in enumerate(zip(hw, sw)):
        dut._log.info(f"  [{i:2d}] hw {h[0]:6d} {h[1]:6d} {h[2]:8d}"
                      f"   sw {s[0]:6d} {s[1]:6d} {s[2]:8d}")

    assert dropped == 0, (
        f"{label}: {dropped} seeds were dropped because the centroid engine was "
        f"busy. The model has no such limit, so the two cannot agree; either the "
        f"field is unrealistically crowded or the engine has stalled.")
    assert n_hw == len(sw), (
        f"{label}: hardware found {n_hw} stars, model found {len(sw)}")
    for i, (h, s) in enumerate(zip(hw, sw)):
        assert h == s, (
            f"{label}: star {i} differs - hardware x={h[0]} y={h[1]} sum={h[2]}, "
            f"model x={s[0]} y={s[1]} sum={s[2]}")


@cocotb.test()
async def test_synthetic_field(dut):
    """A synthetic DUST-shaped frame: the RTL must match the model exactly."""
    await run_case(dut, synthetic_frame(), "synthetic")


@cocotb.test(skip=os.getenv("STARFRONT_DATA") is None or CAM)
async def test_real_frame(dut):
    """A real DUST frame, if the display set is available."""
    code = real_frame()
    assert code is not None, "STARFRONT_DATA set but no images found under it"
    await run_case(dut, code, "DUST frame")
