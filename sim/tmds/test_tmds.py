"""cocotb tests for tmds_encoder.

The TMDS encoder is the one genuinely new block in the display path, and a
subtly wrong DC-balancing branch produces a picture that looks fine for a few
seconds and then falls apart. So rather than eyeballing waveforms these tests
decode every encoded word back to the original byte, and check the two
properties the DVI specification actually promises: bounded running disparity
and at most five transitions per word.

Sampling convention: drive `din`, wait for the rising edge that captures it,
then read `dout` on the following falling edge, when the register output has
settled. That is exactly one input byte per clock, with no words skipped -
which matters for the disparity test, since the encoder balances a word
against the ones around it.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

CLK_PERIOD_NS = 40

CONTROL_TOKENS = {
    0b00: 0b1101010100,
    0b01: 0b0010101011,
    0b10: 0b0101010100,
    0b11: 0b1010101011,
}


def tmds_decode(word):
    """Inverse of the DVI 1.0 encoder - recovers the source byte."""
    q = [(word >> i) & 1 for i in range(10)]
    data = [b ^ 1 for b in q[0:8]] if q[9] else q[0:8]

    out = [0] * 8
    out[0] = data[0]
    for i in range(1, 8):
        xor = data[i] ^ data[i - 1]
        out[i] = xor if q[8] else xor ^ 1

    return sum(bit << i for i, bit in enumerate(out))


def transitions(word):
    return sum(((word >> i) & 1) != ((word >> (i + 1)) & 1) for i in range(9))


def disparity(word):
    ones = bin(word & 0x3FF).count("1")
    return ones - (10 - ones)


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())


async def reset(dut):
    dut.rst.value = 1
    dut.de.value = 0
    dut.c.value = 0
    dut.din.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await FallingEdge(dut.clk)


async def encode(dut, value):
    """Feed one byte through the encoder and return the word it produced."""
    dut.din.value = value
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    return int(dut.dout.value)


@cocotb.test()
async def test_control_tokens(dut):
    """Blanking sends the four fixed control tokens."""
    await start_clock(dut)
    await reset(dut)

    dut.de.value = 0
    for ctrl, expected in CONTROL_TOKENS.items():
        dut.c.value = ctrl
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        got = int(dut.dout.value)
        assert got == expected, (
            f"c={ctrl:02b} should encode to {expected:010b}, got {got:010b}"
        )


@cocotb.test()
async def test_encoding_is_reversible(dut):
    """Every byte survives an encode/decode round trip."""
    await start_clock(dut)
    await reset(dut)

    dut.de.value = 1
    dut.c.value = 0

    for value in range(256):
        word = await encode(dut, value)
        decoded = tmds_decode(word)
        assert decoded == value, (
            f"encoded 0x{value:02X} as {word:010b}, which decodes to 0x{decoded:02X}"
        )


@cocotb.test()
async def test_dc_balance_and_transitions(dut):
    """Running disparity stays bounded and no word has more than 5 transitions."""
    await start_clock(dut)
    await reset(dut)

    dut.de.value = 1
    dut.c.value = 0

    # A constant byte is the worst case for DC balance: an encoder that never
    # inverts would drift without limit here.
    patterns = [0xFF] * 64 + [0x00] * 64 + [0xAA, 0x55] * 32 + list(range(256))

    running = 0
    worst = 0
    for value in patterns:
        word = await encode(dut, value)

        n_trans = transitions(word)
        assert n_trans <= 5, (
            f"0x{value:02X} encoded to {word:010b} with {n_trans} transitions "
            f"(DVI allows at most 5)"
        )

        running += disparity(word)
        worst = max(worst, abs(running))
        assert abs(running) <= 10, (
            f"running disparity ran away to {running} while encoding 0x{value:02X}"
        )

    dut._log.info("worst accumulated disparity over %d words: %d", len(patterns), worst)


@cocotb.test()
async def test_blanking_resets_disparity(dut):
    """Leaving active video clears the running disparity, per the spec."""
    await start_clock(dut)
    await reset(dut)

    dut.de.value = 1
    dut.c.value = 0
    for _ in range(32):
        await encode(dut, 0xFF)

    dut.de.value = 0
    await ClockCycles(dut.clk, 4)
    await FallingEdge(dut.clk)

    # Straight back into video: the first word must be encoded as if the
    # disparity were zero, i.e. the same word a freshly reset encoder produces.
    dut.de.value = 1
    after_blank = await encode(dut, 0xF0)

    await reset(dut)
    dut.de.value = 1
    dut.c.value = 0
    after_reset = await encode(dut, 0xF0)

    assert after_blank == after_reset, (
        f"blanking should reset disparity: {after_blank:010b} vs {after_reset:010b}"
    )
