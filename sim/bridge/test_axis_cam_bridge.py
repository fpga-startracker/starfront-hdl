"""cocotb tests for axis_cam_bridge.

Verifies:
  1. Magic sync sequence (0xAA55AA55) triggers emu_vsync pulse.
  2. AXI-Stream flow control (tready handshake during line buffer receive).
  3. Continuous 1280-cycle emu_href burst at 25 MHz after full line is received.
  4. Automatic grayscale expansion (640 luminance bytes -> 1280 {Y, 0x80} output bytes).
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

CLK_PERIOD_NS = 40  # 25 MHz


async def setup_dut(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    dut.rst.value = 1
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.gray_input.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    # Wait until DUT is out of reset and asserts tready
    while dut.s_axis_tready.value != 1:
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)


async def send_sync_word(dut):
    """Send the 4-byte magic word 0xAA 0x55 0xAA 0x55."""
    magic = [0xAA, 0x55, 0xAA, 0x55]
    for b in magic:
        dut.s_axis_tdata.value = b
        dut.s_axis_tvalid.value = 1
        while True:
            await RisingEdge(dut.clk)
            if dut.s_axis_tready.value == 1:
                break
        await FallingEdge(dut.clk)
    dut.s_axis_tvalid.value = 0


async def send_axi_bytes(dut, byte_list):
    """Stream bytes into DUT with proper AXI-Stream backpressure handling."""
    for b in byte_list:
        dut.s_axis_tdata.value = b
        dut.s_axis_tvalid.value = 1
        while True:
            await RisingEdge(dut.clk)
            if dut.s_axis_tready.value == 1:
                break
        await FallingEdge(dut.clk)
    dut.s_axis_tvalid.value = 0


@cocotb.test()
async def test_sync_word_triggers_vsync(dut):
    """Sending the 4-byte magic word causes emu_vsync to pulse high."""
    await setup_dut(dut)

    assert dut.emu_vsync.value == 0, "vsync should start low"
    await send_sync_word(dut)

    # Wait for vsync to go high
    vsync_seen = False
    for _ in range(50):
        await FallingEdge(dut.clk)
        if dut.emu_vsync.value == 1:
            vsync_seen = True
            break

    assert vsync_seen, "emu_vsync did not assert after magic word"

    # Count vsync pulse duration
    pulse_len = 0
    while dut.emu_vsync.value == 1:
        pulse_len += 1
        await FallingEdge(dut.clk)

    assert pulse_len >= 90, f"vsync pulse too short: {pulse_len} cycles"


@cocotb.test()
async def test_line_burst_rgb565(dut):
    """1280 bytes of RGB565 streamed in should burst out as exactly 1280 HREF cycles."""
    await setup_dut(dut)
    dut.gray_input.value = 0

    await send_sync_word(dut)

    # Wait until vsync finishes and DUT enters ST_RX_LINE (tready = 1)
    for _ in range(300):
        await FallingEdge(dut.clk)
        if dut.s_axis_tready.value == 1 and dut.emu_vsync.value == 0:
            break

    assert dut.s_axis_tready.value == 1, "DUT not ready to receive line"

    # Send 1280 bytes of test data
    test_line = [(i & 0xFF) for i in range(1280)]
    await send_axi_bytes(dut, test_line)

    # Wait for emu_href to rise on FallingEdge
    for _ in range(50):
        await FallingEdge(dut.clk)
        if dut.emu_href.value == 1:
            break

    assert dut.emu_href.value == 1, "emu_href did not assert after line received"

    # Sample exactly on FallingEdge for each clock of active HREF
    received_bytes = []
    while dut.emu_href.value == 1:
        received_bytes.append(int(dut.emu_data.value))
        await FallingEdge(dut.clk)

    assert len(received_bytes) == 1280, (
        f"expected 1280 HREF cycles, got {len(received_bytes)}"
    )
    # Check data content
    for idx, (expected, actual) in enumerate(zip(test_line, received_bytes)):
        assert expected == actual, (
            f"mismatch at byte {idx}: expected 0x{expected:02X}, got 0x{actual:02X}"
        )


@cocotb.test()
async def test_grayscale_expansion(dut):
    """640 bytes of grayscale Y should automatically expand to 1280 {Y, 0x80} bytes on HREF."""
    await setup_dut(dut)
    dut.gray_input.value = 1

    await send_sync_word(dut)

    # Wait until vsync finishes and DUT is ready for line 0
    for _ in range(300):
        await FallingEdge(dut.clk)
        if dut.s_axis_tready.value == 1 and dut.emu_vsync.value == 0:
            break

    # Send 640 bytes of luminance
    test_luma = [(i * 3) & 0xFF for i in range(640)]
    await send_axi_bytes(dut, test_luma)

    # Wait for emu_href to rise on FallingEdge
    for _ in range(50):
        await FallingEdge(dut.clk)
        if dut.emu_href.value == 1:
            break

    assert dut.emu_href.value == 1, "emu_href did not assert after 640 luma bytes"

    # Capture 1280 output bytes on FallingEdge
    out_bytes = []
    while dut.emu_href.value == 1:
        out_bytes.append(int(dut.emu_data.value))
        await FallingEdge(dut.clk)

    assert len(out_bytes) == 1280, f"expected 1280 output bytes, got {len(out_bytes)}"

    # Verify each pixel is {Y, 0x80}
    for pix_idx in range(640):
        y_val = out_bytes[pix_idx * 2]
        uv_val = out_bytes[pix_idx * 2 + 1]
        assert y_val == test_luma[pix_idx], (
            f"pixel {pix_idx}: expected Y=0x{test_luma[pix_idx]:02X}, got 0x{y_val:02X}"
        )
        assert uv_val == 0x80, (
            f"pixel {pix_idx}: expected neutral UV=0x80, got 0x{uv_val:02X}"
        )
