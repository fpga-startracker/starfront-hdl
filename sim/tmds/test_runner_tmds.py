"""Runner for the TMDS encoder tests.

    cd sim/tmds && python test_runner_tmds.py
"""

import os
from pathlib import Path

try:
    from cocotb_tools.runner import get_runner
except ImportError:  # cocotb < 2.0
    from cocotb.runner import get_runner


def test_tmds_runner():
    sim = os.getenv("SIM", "icarus")

    here = Path(__file__).resolve().parent
    rtl = here.parent.parent / "rtl"

    runner = get_runner(sim)
    runner.build(
        sources=[rtl / "tmds_encoder.v"],
        hdl_toplevel="tmds_encoder",
        defines={"SIM": 1},
        always=True,
        waves=True,
    )
    runner.test(hdl_toplevel="tmds_encoder", test_module="test_tmds")


if __name__ == "__main__":
    test_tmds_runner()
