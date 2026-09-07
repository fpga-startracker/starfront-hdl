"""cocotb tests for sccb_master, driven against ov7670_sccb_slave_model.

The read path is the reason this module exists: on hardware, reading back
PID = 0x76 / VER = 0x73 is the single check that says the camera is powered,
wired correctly and talking. These tests make sure the master implements the
two-phase read the OV7670 actually expects before it is trusted on a board.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

CLK_PERIOD_NS = 40  # 25 MHz


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())


async def reset(dut):
    dut.rst.value = 1
    dut.start.value = 0
    dut.rw.value = 0
    dut.sub_addr.value = 0
    dut.wr_data.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 10)


async def transaction(dut, rw, sub_addr, wr_data=0, timeout_cycles=20000):
    """Issue one SCCB transaction and wait for done."""
    dut.rw.value = rw
    dut.sub_addr.value = sub_addr
    dut.wr_data.value = wr_data
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if dut.done.value == 1:
            return int(dut.rd_data.value)

    raise TimeoutError(
        f"SCCB transaction (rw={rw}, sub=0x{sub_addr:02X}) never completed; "
        f"master stuck in state {int(dut.dbg_state.value)}"
    )


@cocotb.test()
async def test_write_reaches_slave(dut):
    """A 3-phase write lands the right value at the right sub-address."""
    await start_clock(dut)
    await reset(dut)

    await transaction(dut, rw=0, sub_addr=0x3A, wr_data=0xA5)

    assert int(dut.slave_id_byte.value) == 0x42, (
        f"device address should be 0x42 for a write, got "
        f"0x{int(dut.slave_id_byte.value):02X}"
    )
    assert int(dut.slave_last_sub.value) == 0x3A
    assert int(dut.slave_last_data.value) == 0xA5


@cocotb.test()
async def test_read_product_id(dut):
    """The two-phase read returns the OV7670 PID and VER."""
    await start_clock(dut)
    await reset(dut)

    pid = await transaction(dut, rw=1, sub_addr=0x0A)
    assert pid == 0x76, f"PID should be 0x76, got 0x{pid:02X}"
    assert int(dut.slave_id_byte.value) == 0x43, (
        "the read phase must re-address the slave with 0x43"
    )

    ver = await transaction(dut, rw=1, sub_addr=0x0B)
    assert ver == 0x73, f"VER should be 0x73, got 0x{ver:02X}"


@cocotb.test()
async def test_write_then_read_back(dut):
    """Write a register, read it back, and get the same byte."""
    await start_clock(dut)
    await reset(dut)

    for value in (0x01, 0xFF, 0x00, 0x5A):
        await transaction(dut, rw=0, sub_addr=0x11, wr_data=value)
        read_back = await transaction(dut, rw=1, sub_addr=0x11)
        assert read_back == value, (
            f"wrote 0x{value:02X} to CLKRC, read back 0x{read_back:02X}"
        )


@cocotb.test()
async def test_busy_and_idle(dut):
    """busy tracks the transaction, and the master returns to idle after it."""
    await start_clock(dut)
    await reset(dut)

    assert dut.busy.value == 0, "master should be idle after reset"

    dut.rw.value = 1
    dut.sub_addr.value = 0x0A
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    await RisingEdge(dut.clk)

    assert dut.busy.value == 1, "busy should assert once a transaction starts"

    for _ in range(20000):
        await RisingEdge(dut.clk)
        if dut.done.value == 1:
            break
    else:
        raise TimeoutError("transaction never completed")

    await ClockCycles(dut.clk, 2)
    assert dut.busy.value == 0, "busy should drop once the transaction ends"
