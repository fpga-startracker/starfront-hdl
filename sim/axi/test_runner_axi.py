"""Runner for the host interface tests.

    cd sim/axi && ../../.venv/bin/python test_runner_axi.py
"""

import os
from pathlib import Path

try:
    from cocotb_tools.runner import get_runner
except ImportError:  # cocotb < 2.0
    from cocotb.runner import get_runner


def test_axi_runner():
    sim = os.getenv("SIM", "icarus")
    rtl = Path(__file__).resolve().parent.parent.parent / "rtl"

    runner = get_runner(sim)
    runner.build(
        sources=[rtl / "axi_bench_if.v"],
        hdl_toplevel="axi_bench_if",
        defines={"SIM": 1},
        always=True,
        waves=True,
    )
    runner.test(hdl_toplevel="axi_bench_if", test_module="test_axi")


if __name__ == "__main__":
    test_axi_runner()
