"""Runner for the capture / frame buffer tests.

    cd sim/capture && python test_runner_capture.py
"""

import os
from pathlib import Path

try:
    from cocotb_tools.runner import get_runner
except ImportError:  # cocotb < 2.0
    from cocotb.runner import get_runner


def test_capture_runner():
    sim = os.getenv("SIM", "icarus")

    here = Path(__file__).resolve().parent
    repo = here.parent.parent

    runner = get_runner(sim)
    runner.build(
        sources=[
            repo / "rtl" / "cam_capture.v",
            repo / "rtl" / "fb_mem.v",
            repo / "sim" / "models" / "cam_capture_tb_wrapper.v",
        ],
        hdl_toplevel="cam_capture_tb_wrapper",
        defines={"SIM": 1},
        always=True,
        waves=True,
    )
    runner.test(hdl_toplevel="cam_capture_tb_wrapper", test_module="test_capture")


if __name__ == "__main__":
    test_capture_runner()
