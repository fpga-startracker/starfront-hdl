"""Runner for the star detector tests.

    cd sim/star && python test_runner_star.py
"""

import os
from pathlib import Path

try:
    from cocotb_tools.runner import get_runner
except ImportError:  # cocotb < 2.0
    from cocotb.runner import get_runner


def test_star_runner():
    sim = os.getenv("SIM", "icarus")
    rtl = Path(__file__).resolve().parent.parent.parent / "rtl"

    runner = get_runner(sim)
    runner.build(
        sources=[rtl / "line_buffer.v", rtl / "star_detect.v"],
        hdl_toplevel="star_detect",
        defines={"SIM": 1},
        always=True,
        waves=True,
    )
    runner.test(hdl_toplevel="star_detect", test_module="test_star")


if __name__ == "__main__":
    test_star_runner()
