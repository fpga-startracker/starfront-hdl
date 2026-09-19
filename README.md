# starfront-hdl

Star tracker front end on an **ALINX AX7010** (Zynq-7000, `xc7z010clg400-1`),
starting with bringing up an **OV7670** camera and getting a live image out of
the board's HDMI port.

The design is **PL-only** — the Zynq PS is not instantiated, so the bitstream
loads straight over JTAG. Debug happens through the HDMI screen, four LEDs and
an ILA, because the board's USB serial port hangs off PS MIO and is out of reach
of PL logic.

## Where things stand

| | Milestone | Status |
|---|---|---|
| M0 | Repo, project generator, LED blink | **passed on hardware** |
| M1 | 50 MHz → 25 MHz pixel + 125 MHz serial, DVI out over HDMI | **passed on hardware** |
| M2 | SCCB master with **read**, camera ID probe, on-screen status | **passed on hardware** |
| M3 | 94-register camera init + pixel stream geometry probe | **passed on hardware** |
| M4 | 320×240 8-bit luminance frame buffer → live image on HDMI | **passed on hardware** in RGB565; gray build of 2026-09-12 not yet seen on the board |
| M5 | Streaming star detection at the camera's full 640×480 | **passed on hardware** |
| M6 | Sub-pixel centroiding, measured against a real star-field set | **passed on hardware** 2026-09-09, 0.477 px median over JTAG-streamed frames |
| M7 | The centroiding pipeline on the live camera, with a star-field sensor profile | **RTL matches the model bit for bit at 640×480; not yet on the board** |

**Camera bring-up is complete, and the star detector works.** As of 2026-09-04
the board captures live video from an OV7670 on header J11 and displays it over
HDMI at 640×480 @ 60 Hz, and the streaming detector picks bright points out of
the camera's full-resolution stream and tracks them live. Everything meets
timing with 0 critical warnings, and the simulation suite passes 20/20.

## Sub-pixel centroiding

A star tracker's front end has one job: say where each star is, to a fraction of
a pixel. `rtl/star_centroid.v` does that in one pass over the pixel stream -
bin, linearise, follow the background, seed, grow an 8-connected region, take
its centre of gravity to 1/256 of a pixel - following Panousopoulos et al.,
*HW/SW co-design on embedded SoC FPGA for star tracking optimization in space
applications*, J Real-Time Image Proc 21:16 (2024).

Measured against the **DUST** display set, 381 frames across 22 sessions,
9001 catalogued stars:

| | display px | DUST px |
|---|---|---|
| centre of gravity alone, vs `display_*` | **0.008** median | 0.002 |
| whole detector, vs `display_blob_*` | **0.401** median, 2.17 p95 | 0.100 |
| completeness, of stars the dataset itself segments | **69%** | |
| completeness, peak ≥ 400 DN | **90%** | |
| **measured on the board**, 20 frames, before the 2026-09-12 background change | **0.477** median | 0.119 |

On the 7z010 that costs 40% of the LUTs, 16% of the flip-flops and 35 of the 60
block RAMs — 32 of which are the stored frame, not the detector — and meets
timing with 3.5 ns to spare.

The gap between those two rows is the threshold, not the arithmetic - see
[`docs/centroiding.md`](docs/centroiding.md), which also says what was measured
rather than assumed and where the remaining error is.

## Three build variants

One source tree, three bitstreams, so the plain camera bring-up stays available
for demonstration without rebuilding it every time the star work moves.

| Variant | Top | Contains |
|---|---|---|
| `bringup` | `top_starfront` | camera bring-up only, M0–M4 |
| `tracker` | `top_starfront` | the above plus the sub-pixel centroiding pipeline on the live camera and the star-field sensor profile, M7 (`ENABLE_STARS=2`; 1 gives the older M5 peak detector) |
| `bench` | `top_starfront_bench` | no camera: replays stored star fields through the centroiding pipeline and draws the result |

```bash
./scripts/build.sh impl bringup     # -> build/starfront_bringup.bit
./scripts/build.sh impl tracker     # -> build/starfront_tracker.bit
./scripts/build.sh impl bench       # -> build/starfront_bench.bit
./scripts/build.sh impl all         # all three

./scripts/program.sh bench
./scripts/open_gui.sh bringup       # open the GUI on a checked project
```

## Feeding images to the board without a camera

The `bench` variant carries star fields in block RAM and replays them through
the real detector at 24 frames a second, drawing the image, a cross on every
star it found, and the detector's own state as text.

```bash
uv run bench/prepare_frames.py --report      # DUST frames -> build/frames.mem
./scripts/build.sh impl bench                # bakes them into the bitstream
./scripts/program.sh bench
```

On the board: KEY3 scrolls continuously, KEY2 scrolls by one step, KEY4 holds.

**Scrolling is what stands in for video without a host.** Four 256×256 frames is
the absolute ceiling for this part's block RAM — 60 tiles is 2.16 Mbit and a
frame is 512 Kbit — so a stream of genuinely different images has to arrive from
off-chip. Moving the frame that *is* stored does not: the read address is offset
by whole display pixels, and since the binner averages 4×4 blocks, one display
pixel is a quarter of a binned pixel. The detector sees a different binned image
every frame, with different noise under the threshold and a background the
follower has to chase — a slewing sky, which is what a star tracker actually
looks at.

It doubles as the sub-pixel proof, on the board, with no host: press KEY2 four
times and every centroid moves by exactly `0100` in the 8.8 readout. The
individual quarter-steps come out −0.281, −0.250, −0.250, −0.219 — the
**S-curve** of an undersampled centroider, amplitude 0.031 px.

## Streaming frames from a PC, and scoring the board

The bench variant carries a JTAG-to-AXI master, so a host can write new frames
into the store and — the part that matters — **read the star list back**.

```bash
uv run bench/export_stream.py --count 50 --skip-empty   # frames + their truth
./scripts/program.sh bench
./scripts/stream_video.sh build/stream 50 build/hw_stars.csv
uv run bench/score_hardware.py build/hw_stars.csv build/stream/truth.csv
```

That last line scores **the hardware's own centroids** against the dataset, the
same way `bench/evaluate.py` scores the model, so the two numbers are directly
comparable. Measured over 20 frames at 2.65 frames/s: the board gets a median
error of **0.4770** display px against the model's 0.4697 on the same frames,
and the first star of the first frame comes back as the model's answer to the
digit. Until this existed, every accuracy figure here was the model's, tied to
the RTL by two frames in simulation.

Why JTAG and not something faster: the AX7010's 32 MB QSPI flash is wired to
`PS_MIO0..MIO6` and the Zynq's Quad-SPI controller is MIO-only, so a PL-only
design cannot reach it; the only other memory on the PL side is a 512-byte I²C
EEPROM. The debug cable is the only route there is. Expect a few frames a
second of *new* content — the detector still runs at 24 fps on whatever is
loaded.

The store holds the **binned 256×256 sensor grid**, not the 1024×1024 display
image - and that is lossless, because the display image is a 4× block
replication of the sensor grid, so `frame_source` replays each stored pixel four
times per axis and `bin_nxn` puts it back. A sixteenth of the memory, the same
pixels. Changing which frames the board runs means a rebuild (about two
minutes), which is the price of not spending a third of the device on a runtime
transfer path.

Accuracy over the whole 1378-frame set is measured in software instead, by
`bench/evaluate.py`, and `sim/centroid` is what ties the two together - it drives
the RTL with the same pixels and demands the same star list, star for star and
bit for bit.

```bash
uv run bench/evaluate.py --stride 10             # score against the truth
uv run bench/evaluate.py --centroider            # the arithmetic on its own
cd sim/centroid && STARFRONT_DATA=<set> ../../.venv/bin/python test_runner_centroid.py
```

## Quick start

```bash
# Build both bitstreams (Vivado 2025.2)
./scripts/build.sh impl all

# Load one over the board's USB JTAG (works from any directory)
./scripts/program.sh tracker

# Run the simulations (Icarus Verilog + cocotb)
uv sync
for s in tmds sccb vga capture star centroid; do
  (cd sim/$s && ../../.venv/bin/python test_runner_$s.py)
done
```

On the board: KEY1 resets, KEY2 held shows the status numbers over a live
image, KEY3 toggles the sensor's test bars (a gray staircase - the picture is
luminance only), KEY4 steps the sensor window, and KEY2 held + KEY4 swaps
which byte of each YUV422 pair is taken as Y. In the `tracker` build KEY3
instead toggles the star-field sensor profile and KEY2 held + KEY3 steps its
exposure/gain preset.

Then follow [`docs/bringup_checklist.md`](docs/bringup_checklist.md) on the
board, and wire the camera per
[`docs/wiring_ov7670.md`](docs/wiring_ov7670.md).

## Architecture

```
        PL_GCLK 50 MHz (U18)
              |
         +----v------+   clk_ser 125 MHz -----------+
         | clk_wiz_0 |   clk_pix  25 MHz -----+     |   MMCM, VCO 1000 MHz
         |  (MMCM)   |   locked               |     |   /8 -> 125, /40 -> 25
         +----+------+                        |     |
              | clk_pix                       |     |
    +---------v----------+                    |     |
    | sccb_probe         |  reset, read PID / |     |
    | ov7670_init        |  VER, then write   |     |
    |   -> sccb_master   |  the 94-reg table  |     |
    +---------+----------+                    |     |
         SIOC / SIOD                          |     |
              v                               |     |
        +-----------+   XCLK 25 MHz (ODDR) ---+     |
        |  OV7670   |<-----------------------       |
        +-----+-----+                               |
   PCLK / HREF / VSYNC / D[7:0]                     |
              | cam_pclk domain (BUFG)              |
    +---------v----------+                          |
    | cam_activity       |--> alive flags           |
    +--------------------+                          |
                                                    |
    +--------------------+   +--------------------+ |
    | status_overlay     |<--| vga_sync_gen       | |
    | PID / VER / flags  |   | 640x480 @ 60 Hz    | |
    +---------+----------+   +--------------------+ |
              | r, g, b + hsync / vsync / de        |
    +---------v-----------------------------------+ |
    | dvi_tx                                      |<+
    |   3x tmds_encoder  (DVI 1.0 8b/10b)         |
    |   4x oserdes_10to1 (OSERDESE2 master/slave) |
    |   4x OBUFDS -> TMDS_33                      |
    +---------------------+-----------------------+
                          v  HDMI connector (hdmi_out_en = 1)
```

## Layout

```
rtl/          synthesisable Verilog
constraints/  ax7010_starfront.xdc (camera), ax7010_bench.xdc (no camera)
sim/          cocotb testbenches (tmds, sccb, vga, capture, star, centroid)
bench/        the centroiding model, the DUST scorer, the table generators
scripts/      create_project.tcl, build.sh, program.sh, open_gui.sh
docs/         pinout, wiring, OV7670 notes, bring-up checklist, centroiding
build/        generated, not version controlled
```

The Vivado project is never committed — `scripts/create_project.tcl` rebuilds
it, both IP cores included, from `rtl/` and `constraints/`.

## Notes worth reading before touching the RTL

- [`docs/ov7670_notes.md`](docs/ov7670_notes.md) — eight pitfalls carried over
  from a working OV7670 design on a Basys 3, plus the register profile a star
  tracker needs (which is nearly the opposite of the consumer one).
- [`docs/ax7010_pinout.md`](docs/ax7010_pinout.md) — the board facts that shape
  the design: no VGA, no PL-reachable UART, raw TMDS, and where the clock
  capable pins are.
- [`docs/centroiding.md`](docs/centroiding.md) — how the detector works, which
  parts are the paper's and which are not, and what each accuracy number
  actually measures.
