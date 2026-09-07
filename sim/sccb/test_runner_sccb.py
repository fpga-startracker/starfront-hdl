"""Runner for the SCCB master tests.

    cd sim/sccb && python test_runner_sccb.py
    # or: pytest test_runner_sccb.py -s
"""

import os
from pathlib import Path

try:
    from cocotb_tools.runner import get_runner
except ImportError:  # cocotb < 2.0
    from cocotb.runner import get_runner


def test_sccb_runner():
    sim = os.getenv("SIM", "icarus")

    here = Path(__file__).resolve().parent
    repo = here.parent.parent
    rtl = repo / "rtl"
    models = repo / "sim" / "models"

    runner = get_runner(sim)
    runner.build(
        sources=[
            rtl / "cdc_sync.v",
            rtl / "sccb_master.v",
            models / "ov7670_sccb_slave_model.v",
            models / "sccb_tb_wrapper.v",
        ],
        hdl_toplevel="sccb_tb_wrapper",
        defines={"SIM": 1},
        always=True,
        waves=True,
    )
    runner.test(hdl_toplevel="sccb_tb_wrapper", test_module="test_sccb")


if __name__ == "__main__":
    test_sccb_runner()
