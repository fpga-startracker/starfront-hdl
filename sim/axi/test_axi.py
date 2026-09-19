"""axi_bench_if against a hand-driven AXI4 master.

The host interface is the one part of the bench that cannot be tried without a
board, so it is worth being sure of the parts that can: that a burst write lands
in the frame store at the right addresses, that a burst read of the star list
comes back in the right order and packing, that the registers report what they
are given, and that the control bits pulse rather than stick.

Everything drives the AXI channels directly rather than through a BFM, so what
is exercised is the handshake this design actually has to satisfy.

**Phase convention: every helper here is entered and left just after a falling
edge.** A signal read at that point is the settled value for the cycle that is
about to end, and a transfer therefore happens at the rising edge in the middle
of an `await FallingEdge`. Getting this wrong does not fail cleanly - the first
version sampled ready straight after the rising edge, which is a race between
the old state and the new, and it passed one test, hung on another, and changed
which one depending on what had run before it.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

FB_BASE = 0x0_0000
LIST_BASE = 0x1_0000
REG_BASE = 0x2_0000
MAGIC = 0x53544652

LIMIT = 300          # cycles before a wait is called a hang


async def step(dut):
    """One cycle, landing just after the next falling edge."""
    await FallingEdge(dut.aclk)


async def hs(dut, ready, what, limit=LIMIT):
    """Wait for `ready`, then step past the transfer edge.

    Bounded, because a testbench that hangs tells you nothing and one that fails
    tells you where.
    """
    for _ in range(limit):
        if int(ready.value):
            await step(dut)
            return
        await step(dut)
    raise AssertionError(
        f"{what} never asserted in {limit} cycles "
        f"(wstate={int(dut.wstate.value)} rstate={int(dut.rstate.value)} "
        f"aresetn={int(dut.aresetn.value)})")


async def reset(dut):
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    dut.aresetn.value = 0
    for sig in ("s_awvalid", "s_wvalid", "s_wlast", "s_bready",
                "s_arvalid", "s_rready"):
        getattr(dut, sig).value = 0
    dut.s_awaddr.value = 0
    dut.s_awlen.value = 0
    dut.s_wdata.value = 0
    dut.s_wstrb.value = 0xF
    dut.s_araddr.value = 0
    dut.s_arlen.value = 0
    for s in ("sl_x", "sl_y", "sl_sum", "sl_npx", "star_count", "dropped",
              "overflow", "frame_count", "fps", "bg_code", "thr_code",
              "mad_acc", "scroll_x", "play_buf"):
        getattr(dut, s).value = 0
    for _ in range(4):
        await RisingEdge(dut.aclk)
    dut.aresetn.value = 1
    await step(dut)
    await step(dut)
    assert int(dut.wstate.value) == 0 and int(dut.rstate.value) == 0, \
        "reset did not return both channel state machines to idle"


async def axi_write(dut, addr, words):
    """One INCR burst.

    Returns the (addr, data) pairs the frame store saw and the per-cycle
    (swap_req, host_step) trace, so a test can check a control pulse without
    forking a watcher of its own - a spare coroutine left running across tests
    is what turned an assertion failure into a hang the first time round.
    """
    seen = []
    pulses = []

    async def watch():
        while True:
            await FallingEdge(dut.aclk)
            if int(dut.fb_we.value):
                seen.append((int(dut.fb_addr.value), int(dut.fb_data.value)))
            pulses.append((int(dut.swap_req.value), int(dut.host_step.value)))

    task = cocotb.start_soon(watch())

    dut.s_awaddr.value = addr
    dut.s_awlen.value = len(words) - 1
    dut.s_awvalid.value = 1
    await hs(dut, dut.s_awready, "awready")
    dut.s_awvalid.value = 0

    for i, w in enumerate(words):
        dut.s_wdata.value = w
        dut.s_wlast.value = 1 if i == len(words) - 1 else 0
        dut.s_wvalid.value = 1
        await hs(dut, dut.s_wready, "wready")
    dut.s_wvalid.value = 0
    dut.s_wlast.value = 0

    dut.s_bready.value = 1
    await hs(dut, dut.s_bvalid, "bvalid")
    dut.s_bready.value = 0

    await step(dut)
    task.kill()
    return seen, pulses


async def axi_read(dut, addr, n):
    """One INCR read burst."""
    out = []
    dut.s_araddr.value = addr
    dut.s_arlen.value = n - 1
    dut.s_arvalid.value = 1
    await hs(dut, dut.s_arready, "arready")
    dut.s_arvalid.value = 0

    dut.s_rready.value = 1
    got_last = False
    for beat in range(n):
        for _ in range(LIMIT):
            if int(dut.s_rvalid.value):
                break
            await step(dut)
        else:
            raise AssertionError(f"rvalid never asserted for beat {beat}")
        out.append(int(dut.s_rdata.value))
        got_last = bool(int(dut.s_rlast.value))
        await step(dut)
    dut.s_rready.value = 0

    assert got_last, "rlast never asserted on the final beat"
    assert len(out) == n
    return out


@cocotb.test()
async def test_frame_store_burst(dut):
    """A 256-word burst must land as 256 consecutive words at the right offset."""
    await reset(dut)

    words = [(0x11000000 + i) & 0xFFFFFFFF for i in range(256)]
    seen, _ = await axi_write(dut, FB_BASE + 0x400, words)

    assert len(seen) == 256, f"{len(seen)} words reached the store, expected 256"
    for i, (a, d) in enumerate(seen):
        assert a == 0x100 + i, f"beat {i} wrote address {a}, expected {0x100 + i}"
        assert d == words[i], f"beat {i} wrote {d:08x}, expected {words[i]:08x}"


@cocotb.test()
async def test_register_read(dut):
    """The status registers report what the detector gives them."""
    await reset(dut)

    dut.star_count.value = 57
    dut.dropped.value = 3
    dut.overflow.value = 1
    dut.frame_count.value = 0x1234
    dut.fps.value = 24
    dut.bg_code.value = 0x45
    dut.thr_code.value = 0x51
    dut.mad_acc.value = 0x004C
    await step(dut)

    r = await axi_read(dut, REG_BASE, 6)

    assert r[0] == MAGIC, f"magic read {r[0]:08x}"
    assert r[1] & 0x7F == 57, f"star_count field {r[1]:08x}"
    assert (r[1] >> 8) & 0x7F == 3, f"dropped field {r[1]:08x}"
    assert (r[1] >> 16) & 1 == 1, f"overflow field {r[1]:08x}"
    assert r[2] == 0x1234
    assert r[3] & 0xFF == 0x45
    assert (r[3] >> 8) & 0xFF == 0x51
    assert (r[3] >> 16) & 0x3FFF == 0x004C
    assert r[4] == 24


@cocotb.test()
async def test_star_list_read(dut):
    """Two words a star, and the packing must survive the round trip."""
    await reset(dut)

    async def feed():
        # Stand in for the star list: entry i is a recognisable pattern. Driven
        # just after the rising edge so it has settled well before the reader
        # samples rdata at the falling one - two coroutines on the same trigger
        # have no defined order between them.
        while True:
            await RisingEdge(dut.aclk)
            await Timer(1, unit="ns")
            a = int(dut.sl_addr.value)
            dut.sl_x.value = 0x1000 + a
            dut.sl_y.value = 0x2000 + a
            dut.sl_sum.value = 0x30000 + a
            dut.sl_npx.value = (a + 4) & 0x7F

    feeder = cocotb.start_soon(feed())
    r = await axi_read(dut, LIST_BASE, 8)
    feeder.kill()

    for i in range(4):
        w0, w1 = r[i * 2], r[i * 2 + 1]
        assert w0 & 0xFFFF == 0x1000 + i, f"star {i} x: {w0:08x}"
        assert (w0 >> 16) & 0xFFFF == 0x2000 + i, f"star {i} y: {w0:08x}"
        assert w1 & 0xFFFFF == 0x30000 + i, f"star {i} sum: {w1:08x}"
        assert (w1 >> 20) & 0x7F == (i + 4), f"star {i} npx: {w1:08x}"


@cocotb.test()
async def test_control_bits(dut):
    """swap and step are one-cycle pulses; the mode bits hold."""
    await reset(dut)

    _, pulses = await axi_write(dut, REG_BASE + 0x20, [0b11011])
    for _ in range(4):
        await step(dut)

    swaps = sum(p[0] for p in pulses)
    steps = sum(p[1] for p in pulses)
    assert swaps == 1, f"swap_req asserted for {swaps} cycles, expected 1"
    assert steps == 1, f"host_step asserted for {steps} cycles, expected 1"
    assert int(dut.swap_req.value) == 0, "swap_req still set several cycles later"
    assert int(dut.host_scroll_en.value) == 1
    assert int(dut.host_override.value) == 1
    assert int(dut.host_hold.value) == 0

    await axi_write(dut, REG_BASE + 0x20, [0])
    await step(dut)
    assert int(dut.host_override.value) == 0, "mode bits must clear when written 0"


@cocotb.test()
async def test_back_to_back_bursts(dut):
    """Two bursts with no gap: the second must not inherit the first's address."""
    await reset(dut)

    a, _ = await axi_write(dut, FB_BASE + 0x000, [0xAAAA0000 + i for i in range(16)])
    b, _ = await axi_write(dut, FB_BASE + 0x100, [0xBBBB0000 + i for i in range(16)])

    assert [x[0] for x in a] == list(range(0, 16))
    assert [x[0] for x in b] == list(range(64, 80))


@cocotb.test()
async def test_unmapped_region(dut):
    """A read outside the map says so rather than returning plausible zeros."""
    await reset(dut)
    r = await axi_read(dut, 0x9_0000, 2)
    assert r[0] == 0xDEADBEEF, f"unmapped read returned {r[0]:08x}"
