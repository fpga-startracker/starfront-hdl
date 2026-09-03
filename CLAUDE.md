# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

Star tracker front end on an **ALINX AX7010** (Zynq-7000 `xc7z010clg400-1`).
Current goal is camera bring-up: an **OV7670** on expansion header J11, with a
live 640×480 image out of the board's HDMI connector. Verilog, PL-only (no Zynq
PS), Vivado 2025.2, simulated with cocotb + Icarus Verilog.

Milestones M0–M5 all pass on hardware: live OV7670 video over HDMI, and a
streaming star detector that tracks bright points at the camera's full 640×480.
See `docs/bringup_checklist.md` for the status table and the pass criteria.

The design builds as **two variants** from one source tree, selected by the
`ENABLE_STARS` parameter on `top_starfront`: `bringup` (M0–M4, camera only) and
`tracker` (adds M5). They are separate Vivado projects and separate bitstreams
under `build/`.

## Commands

```bash
./scripts/build.sh impl bringup   # camera bring-up only
./scripts/build.sh impl tracker   # + star detector
./scripts/build.sh impl all       # both

./scripts/program.sh <variant>       # bringup | tracker

uv sync                           # cocotb + numpy + pytest into .venv
cd sim/<subsystem> && ../../.venv/bin/python test_runner_<subsystem>.py
```

Simulation subsystems: `tmds`, `sccb`, `vga`, `capture`, `star`. Reports land in
`build/starfront_<variant>_timing.rpt` and `..._utilization.rpt`.

`build.sh` decides success from the `INFO: BUILD COMPLETE` marker, not the exit
code — Vivado batch mode exits 0 even when a Tcl error aborts the script.

Note: plain `cd` misbehaves in this user's zsh. Use `env -C <dir> <cmd>` from
tool calls.

## Board facts that drive the design

These are the ones that repeatedly matter; the full tables are in
`docs/ax7010_pinout.md`.

- **50 MHz** PL clock on **U18**, not 100 MHz.
- **No VGA connector.** HDMI is **raw TMDS out of PL bank 34** with no encoder
  chip, so `dvi_tx` does the 8b/10b encoding and the 10:1 serialisation itself.
  `hdmi_out_en` (V16) must be driven high or the sink gets no +5 V.
- **No UART reachable from PL** — the USB serial port is on PS MIO. Debug goes
  through `status_overlay` on the HDMI screen, four LEDs and an ILA.
- **LEDs and keys are active low.**
- The camera lives on **J11**, whose only MRCC pin in reach is **K17** — that is
  why PCLK is pinned there and must stay there.

## Architecture

```
top_starfront   (parameter ENABLE_STARS)
├── clk_wiz_0         MMCM: 50 MHz -> 125 MHz (clk_ser) + 25 MHz (clk_pix)
├── sccb_master       SCCB with read; exposes _out/_oe/_in, IOBUF is in the top
├── sccb_probe        reset, read PID/VER, write+read-back, retry ~2 Hz
├── ov7670_init       94-register table; color_bar is an input, so KEY3 re-runs
│   └── ov7670_registers
├── cam_activity      coarse PCLK/HREF/VSYNC/data activity
├── cam_stream_probe  bytes/line, lines/frame, PCLK frequency, frames/sec
├── cam_capture       RGB444 3-stage pipeline, 2:1 downsample to 320x240
├── fb_mem            inferred dual-clock block RAM, 320x240 x 12 bit
├── fb_reader         2x pixel doubling, RGB444 -> RGB888
├── cam_pixel_stream  full 640x480 tap: one pixel per strobe + luminance   [M5]
├── star_detect       5x5 window, peak + centroid, adaptive threshold      [M5]
│   └── line_buffer   x4, distributed RAM - no block RAM at all
├── vga_sync_gen      640x480 @ 60 Hz timing, both sync polarities
├── status_overlay    hex digits via hex_font, plus a flag row of blocks
├── key_debounce      x2  KEY2 (overlay) and KEY3 (colour bars)
└── dvi_tx
    ├── tmds_encoder   x3   DVI 1.0 8b/10b
    └── oserdes_10to1  x4   OSERDESE2 master/slave pair per lane
```

**SCCB ownership** passes from `sccb_probe` to `ov7670_init` when
`probe_locked` goes high, which happens the moment the camera returns the right
product ID. Until then the probe keeps retrying, so the camera can be plugged in
with the bitstream already running.

**Clock domains:** `clk_pix` (25 MHz, display and control), `clk_ser` (125 MHz,
TMDS serialisers only), `cam_pclk` (25 MHz from the camera, capture and the
stream probe). The XDC declares `sys_clk` and `cam_pclk` asynchronous; crossings
go through `cdc_sync`, a toggle handshake in `cam_stream_probe`, and the
dual-clock block RAM in `fb_mem`.

**Why the star detector streams:** buffering a 640x480 frame at 8 bits needs 75
BRAM tiles and the 7z010 has 60, so the detector works from a five-row sliding
window instead - four line buffers, ~20 Kbit, in LUTs. That is what lets it run
at the camera's full resolution while the display path settles for a quarter of
it. Block RAM is the binding resource here; see the headroom table in
`docs/bringup_checklist.md` before adding anything that needs it.

**Display pipeline latency:** both pixel sources are arranged to have exactly
one clock of latency — the block RAM registers its output, and the overlay is
registered in the top to match — so the sync signals are delayed once and stay
aligned with either source.

## Conventions

`docs/verilog_conventions.md` is the full document. In short: lowercase
`snake_case` signals, `UPPER_CASE` constants and states, `_n` suffix for active
low, `_reg` suffix for the register behind an output port, tri-states split into
`_oe` / `_out` / `_in` with the buffer in the top level, sized literals
everywhere, synchronous reset, `localparam` states.

## Things that will bite

`docs/ov7670_notes.md` has the full list with explanations. The ones that cost
the most time on the predecessor project:

1. Never read `ov7670_data` combinationally inside a `posedge pclk` block — use
   a three-cycle register pipeline, or you get rainbow noise.
2. A partial register init gives wrong colour. The colour matrix, `COM13 = 0xC0`
   and the magic `0xB0 = 0x84` are all required.
3. Keep `COM3 = 0x00`; the FPGA does the downsampling, not the sensor.
4. Skip the first pixel of each line, or you get a coloured left edge.
5. `0x70 = 0xBA` turns on the sensor's colour bars, which splits "is it the
   FPGA or the camera?" in one step.

For the star tracker specifically: the 94-register consumer profile enables AGC,
AEC, AWB, gamma and denoise, and **all five are wrong for photographing stars**.
M5 needs its own profile — see the last section of `docs/ov7670_notes.md`.

## Simulation

Testbench models live in `sim/models/`. `ov7670_sccb_slave_model.v` implements
both the 3-phase write and the 2-phase-write/2-phase-read pair, over a real
tri-state bus with a pull-up; it uses blocking assignments deliberately, since
the ordering inside each edge handler is what makes it correct.

When adding tests, sample registered outputs on the **falling** edge after the
capturing rising edge. Reading immediately after `RisingEdge` is ambiguous with
non-blocking assignments, and doubling up edges silently skips values — which is
exactly how the first version of the TMDS disparity test produced a false
failure.
