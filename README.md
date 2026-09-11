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
| M4 | 320×240 RGB565 / grayscale frame buffer → live image on HDMI | **passed on hardware** |
| M5 | Streaming star detection at the camera's full 640×480 | **passed on hardware** |
| M6 | Sub-pixel centroid, multiple markers, astro register profile | not started |

**Camera bring-up is complete, and the star detector works.** As of 2026-09-04
the board captures live video from an OV7670 on header J11 and displays it over
HDMI at 640×480 @ 60 Hz, and the streaming detector picks bright points out of
the camera's full-resolution stream and tracks them live. Everything meets
timing with 0 critical warnings, and the simulation suite passes 20/20.

## Two build variants

One source tree, two bitstreams, so the plain camera bring-up stays available
for demonstration without rebuilding it every time the star work moves.

| Variant | Contains | `ENABLE_STARS` |
|---|---|---|
| `bringup` | camera bring-up only, M0–M4 | 0 |
| `tracker` | the above plus the streaming star detector, M5 | 1 |

```bash
./scripts/build.sh impl bringup     # -> build/starfront_bringup.bit
./scripts/build.sh impl tracker     # -> build/starfront_tracker.bit
./scripts/build.sh impl all         # both

./scripts/program.sh bringup
./scripts/open_gui.sh bringup       # open the GUI on a checked project
```

## Quick start

```bash
# Build both bitstreams (Vivado 2025.2)
./scripts/build.sh impl all

# Load one over the board's USB JTAG (works from any directory)
./scripts/program.sh tracker

# Run the simulations (Icarus Verilog + cocotb)
uv sync
for s in tmds sccb vga capture star; do
  (cd sim/$s && ../../.venv/bin/python test_runner_$s.py)
done
```

On the board: KEY1 resets, KEY2 held shows the status numbers over a live
image, KEY3 toggles the sensor between RGB565 and YUV422 grayscale output.
The grayscale mode is the astro-friendly option: it keeps only luminance and is
used when the detector wants one 8-bit brightness sample per pixel instead of a
full 16-bit colour word.

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
constraints/  ax7010_starfront.xdc - pins and timing
sim/          cocotb testbenches (tmds, sccb, vga) and models
scripts/      create_project.tcl, build.sh, program.sh, open_gui.sh
docs/         pinout, wiring, OV7670 notes, bring-up checklist, conventions
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
