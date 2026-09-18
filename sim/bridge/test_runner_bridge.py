"""Runner for the axis_cam_bridge cocotb tests.

    cd sim/bridge && python test_runner_bridge.py
"""

import os
from pathlib import Path

try:
    from cocotb_tools.runner import get_runner
except ImportError:
    from cocotb.runner import get_runner


def test_bridge_runner():
    sim = os.getenv("SIM", "icarus")

    here = Path(__file__).resolve().parent
    repo = here.parent.parent

    runner = get_runner(sim)
    runner.build(
        sources=[
            repo / "rtl" / "axis_cam_bridge.v",
        ],
        hdl_toplevel="axis_cam_bridge",
        defines={"SIM": 1},
        always=True,
        waves=True,
    )
    runner.test(hdl_toplevel="axis_cam_bridge", test_module="test_axis_cam_bridge")


if __name__ == "__main__":
    test_bridge_runner()
