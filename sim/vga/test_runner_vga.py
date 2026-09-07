"""Runner for the display timing tests.

    cd sim/vga && python test_runner_vga.py
"""

import os
from pathlib import Path

try:
    from cocotb_tools.runner import get_runner
except ImportError:  # cocotb < 2.0
    from cocotb.runner import get_runner


def test_vga_runner():
    sim = os.getenv("SIM", "icarus")

    here = Path(__file__).resolve().parent
    rtl = here.parent.parent / "rtl"

    runner = get_runner(sim)
    runner.build(
        sources=[rtl / "vga_sync_gen.v"],
        hdl_toplevel="vga_sync_gen",
        defines={"SIM": 1},
        always=True,
        waves=True,
    )
    runner.test(hdl_toplevel="vga_sync_gen", test_module="test_vga")


if __name__ == "__main__":
    test_vga_runner()
