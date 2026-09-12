"""Runner for the centroid pipeline tests.

    cd sim/centroid && ../../.venv/bin/python test_runner_centroid.py

Set STARFRONT_DATA to point at a DUST_display_set directory to run the real
frames as well; without it only the synthetic tests run.

Set STARFRONT_GEOM=cam to build the detector the way the camera variant does -
640x480, 10/9-bit coordinates, 18-bit list entries, no field-of-view mask - and
run the synthetic test at that size. The DUST frame test does not apply there.
"""

import os
from pathlib import Path

try:
    from cocotb_tools.runner import get_runner
except ImportError:  # cocotb < 2.0
    from cocotb.runner import get_runner


def test_centroid_runner():
    sim = os.getenv("SIM", "icarus")
    rtl = Path(__file__).resolve().parent.parent.parent / "rtl"

    cam = os.getenv("STARFRONT_GEOM", "") == "cam"
    params = ({"IMG_W": 640, "IMG_H": 480, "XW": 10, "YW": 9, "CW": 18,
               "FOV_R": 0, "FOV_CX": 320, "FOV_CY": 240} if cam else {})

    runner = get_runner(sim)
    runner.build(
        parameters=params,
        sources=[
            rtl / "pix_lut.v",
            rtl / "line_buffer.v",
            rtl / "bg_track.v",
            rtl / "region_grow.v",
            rtl / "cg_engine.v",
            rtl / "star_centroid.v",
        ],
        hdl_toplevel="star_centroid",
        defines={"SIM": 1},
        always=True,
        waves=True,
    )
    runner.test(hdl_toplevel="star_centroid", test_module="test_centroid")


if __name__ == "__main__":
    test_centroid_runner()
