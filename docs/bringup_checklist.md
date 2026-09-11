# Bring-up checklist

Work through these in order. Each milestone proves one subsystem, and skipping
ahead just means debugging several unknowns at once — which is the mistake the
Basys 3 project's `Agent.md` warns about at length.

## Status at a glance

| | Milestone | RTL | Verified in sim | Verified on hardware |
|---|---|---|---|---|
| M0 | Toolchain, project generator, LEDs | done | – | **passed 2026-09-04** |
| M1 | Clocking + HDMI output | done | tmds, vga | **passed 2026-09-04** |
| M2 | SCCB read + camera ID probe | done | sccb | **passed 2026-09-04** |
| M3 | Camera init + pixel stream geometry probe | done | – | **passed 2026-09-04** — `0500 01E0` |
| M4 | Frame buffer + live image | done | capture | **passed 2026-09-04** |
| M5 | Streaming star detection at full 640×480 | done | star | **passed 2026-09-04** — tracks a phone torch in a dark room |

The `bringup` build variant stops after M4; `tracker` adds M5.

A live image on screen means M2 and M4 both hold: the image only replaces the
overlay once `init_done` is high, and `init_done` only happens after the ID
probe hands over the SCCB bus. M3's own criterion is the measured geometry -
hold KEY2 and read row 1, which should say `0500 01E0`.

## What the board shows you

**Keys:** KEY1 reset · KEY2 hold to force the status overlay over a live image ·
KEY3 toggle the sensor between RGB565 and YUV422 grayscale output · KEY4 step
the horizontal window position (see pitfall 9 in `docs/ov7670_notes.md`).

The colour-bar pattern remains available in the register ROM for bench debugging,
but the default bring-up flow leaves it off so the board shows the actual camera
output in the active format.

**LEDs (active low — lit means the signal is high):**

| LED | Signal |
|---|---|
| LED1 | heartbeat, ~1.5 Hz — the bitstream is running |
| LED2 | `cam_id_ok` — PID 0x76 and VER 0x73 both read back |
| LED3 | `init_done` — all 94 registers written |
| LED4 | `stream_ok` — 1280 bytes/line and 480 lines/frame |

**The screen** (640×480 over HDMI), drawn by `status_overlay`. Rows 0–2 are
eight large hex digits; row 3 is eight blocks.

| Area | Content | Expect |
|---|---|---|
| banner | red = no camera, amber = camera but bad stream, green = all good | green |
| row 0, red tab | `PID VER`, window selection, register read-back | `7673 0001` |
| row 1, green tab | `bytes/line` then `lines/frame` | `0500 01E0` |
| row 2, blue tab | `PCLK / 100 kHz` then `frames/sec` | `00FA 001E` |
| row 3, amber tab | `id_ok rw_ok init_done stream_ok data href vsync pclk` | all eight lit |
| bottom strip | bar stepping once per frame | moving |

`0500` is 1280 and `01E0` is 480; `00FA` is 250, meaning PCLK is 25.0 MHz.

The overlay shows automatically until `init_done`, then the live image takes
over. Hold KEY2 to bring the numbers back.

A bitstream built before the `hdmi_hpd` pull-up was added to the XDC reports HPD
as 0 regardless — HPD arrives through an open-drain buffer and floats without a
pull-up. That bit has since been dropped from the status row.

**The ILA**, on `clk_pix`, if the screen says the ID read failed:

| Probe | Contents |
|---|---|
| probe0 | `{cam_readback, cam_ver, cam_pid, probe_state}` |
| probe1 | `{0, 0, id_ok, rw_ok, sio_c, sio_d_in, sio_d_oe, sccb_busy}` |
| probe2 | `sccb_master` state |
| probe3 | `{data, href, vsync, pclk}` activity |

## M0 — toolchain and board

1. `./scripts/build.sh impl` completes and writes `build/starfront_bringup.bit`.
2. Program it over JTAG (Vivado Hardware Manager, or `program_hw_devices`).
3. **Pass:** LED1 blinks at roughly 1.5 Hz.

If nothing blinks, the problem is the JTAG cable, board power or the boot mode
jumper — not the design.

## M1 — clocking and HDMI

Do this with **no camera connected**. It is the largest piece of new logic in
the project and it is much easier to debug on its own.

1. Connect a monitor to the HDMI socket.
2. **Pass:** a stable picture with the banner, four block rows and a moving
   sweep bar, and the monitor's OSD reporting **640×480 @ 60 Hz**.

If the monitor reports no signal:

- Measure **+5 V on HDMI connector pin 18**. That comes from the TPS2051B gated
  by `hdmi_out_en` (V16). No 5 V means the enable polarity is inverted — flip
  `assign hdmi_out_en` in the top level.
- Check LED2. No MMCM lock means the 50 MHz oscillator or the `clk_wiz_0`
  configuration is wrong.
- Check the ILA is reachable over JTAG; if it is, the bitstream is running and
  the problem is downstream of the fabric.

If the picture rolls or tears, suspect sync polarity: `dvi_tx` needs the
**active-high** sync signals (`vga_hsync_p` / `vga_vsync_p`), not the VGA ones.

## M2 — SCCB and camera identity

This is the milestone that answers "is the camera actually there?".

1. Power the board down. Wire the camera per `wiring_ov7670.md`, including the
   pull-up check.
2. Power up.
3. **Pass:** the banner turns green, LED3 lights, and rows 1 and 2 read
   `0111 0110` and `0111 0011`.

`sccb_probe` re-runs the whole sequence about twice a second, so the camera can
be plugged in while the bitstream is already running and the banner will turn
green on its own.

### If the banner stays red

Read the PID row first — the value tells you which failure it is.

| PID row shows | Meaning | What to check |
|---|---|---|
| `1111 1111` (0xFF) | nothing is pulling SIO_D low | camera unpowered, SIOD not connected, or SIOC/SIOD swapped |
| `0000 0000` (0x00) | SIO_D is stuck low | short to ground, or a missing pull-up with something else driving |
| garbage, changes each probe | bus is marginal | pull-ups too weak, wires too long, or SIOC/SIOD crossed |
| `0111 0110` but VER wrong | reads work, the sub-address write does not | check the ILA for the second phase of the read |

Then, in order:

1. Measure 3.3 V at the camera module itself, not at the header.
2. Measure the pull-ups: SIOC and SIOD to 3.3 V should be a few kΩ, not open.
3. Check that XCLK is present on J11 pin 36 — the OV7670's SCCB block will not
   respond without a clock. LED4 (`pclk_alive`) lighting up is indirect proof
   that XCLK is reaching the sensor.
4. Put the ILA on probe2 and trigger on `sccb_busy` rising to see the actual
   bus waveform.

### If the ID reads but row 3 is not `0000 0001`

Reads work and writes do not. Check that SIO_D is not being held by something
else on the bus, and that the module has no series resistor on SIOD that
prevents the FPGA pulling it fully low.

## Close the project in the GUI before building

`create_project -force` deletes and recreates `build/<project>/`. If the Vivado
GUI has that project open it holds its own copy in memory and writes it back
over the generated one, which produces two confusing failures:

- the GUI reports `Synthesis Failed: <top>.dcp does not exist`, for files the
  build had already replaced underneath it;
- the `.xpr` on disk ends up as whatever the GUI remembered, which is how a
  project that had just built all eighteen sources came to list only twelve.

The second failure is the nastier one, because the GUI writes the project back
**when it closes**, which can be hours after the build it invalidated. A GUI
left open all morning turned a working `bringup` project into one that still
named `top_starfront_bringup.v`, months-old file list and all, long after the
rename to `top_starfront.v` had been built, programmed and committed.

`scripts/build.sh` and `scripts/program.sh` refuse to run while another Vivado
session is open. `scripts/open_gui.sh <variant>` compares the project against
`rtl/` before opening it, so drift is caught in a second rather than in a
synthesis run:

```bash
./scripts/open_gui.sh bringup            # opens it, or explains what drifted
./scripts/open_gui.sh bringup --regen    # rebuild the project first
```

Regenerating discards `synth_1` and `impl_1`, but never the bitstream: the build
copies `.bit` and `.ltx` up into `build/` precisely so `program.sh` survives it.

## Resource headroom

Block RAM is the binding constraint on this part, and it is nearly all frame
buffer:

| | tiles |
|---|---|
| RGB565 frame buffer, 320x240 x 16 bit | 48 |
| ILA, 1024 deep x ~93 probe bits | ~3 |
| star detector line buffers | 0 - distributed RAM, ~570 LUTs |
| **available** | **60** |

The streaming star detector deliberately costs no block RAM: four line buffers
are 20 Kbit and go in LUTs. That is the whole reason it processes at the
camera's full 640x480 while the display path settles for a quarter of that -
buffering a 640x480 frame at 8 bits would need 75 tiles.

If something needs more block RAM, in order: shrink or drop the ILA (bring-up
is what it was there for), then move the display buffer to 8-bit grayscale,
which roughly halves it.

## M3 — camera init and pixel stream geometry

Once the ID probe succeeds it parks and hands the SCCB bus to `ov7670_init`,
which writes the 94-register table. Hold KEY2 and read row 1 and row 2.

**Pass:** row 1 reads `0500 01E0` and row 2 reads `00FA 001E`, and LED3 and LED4
are both lit.

| Row 1 shows | Meaning |
|---|---|
| `0500 01E0` | VGA, two bytes per pixel — correct |
| `0280 00F0` | camera-side scaling is on (`COM3 = 0x04`) — pitfall 3 |
| `0500 00F0` | right line length, half the lines — check VSYNC wiring |
| `0000 0000` | HREF or VSYNC never toggles — check those two wires |
| changes every frame | the pixel bus is unstable — shorten the wires, check grounds |

If row 2 reads `007D` instead of `00FA`, PCLK is 12.5 MHz: `CLKRC` is dividing
by two.

## M4 — frame buffer and live image

Capture goes into a 320×240 × 12-bit inferred block RAM and is pixel-doubled
back to 640×480 for display. The overlay hands over to the live image
automatically once `init_done` goes high.

1. **Toggle the image format.** Press KEY3 to switch between the normal RGB565
   image and the YUV422 grayscale mode. The register table re-runs, so the
   screen drops back to the overlay for a short moment and then resumes with the
   new format.
2. **Confirm the image is stable in both modes.** The same FPGA path handles
   both, so a stable picture in either mode means the capture, block RAM and
   display pipeline are correct.

**Pass:** a live image in either RGB565 or YUV422 grayscale. That completes
camera bring-up.

If the image is wrong only in RGB565, work through pitfalls 2, 5 and 7 in
`docs/ov7670_notes.md` — that is the ISP configuration, not the FPGA. If the
image is wrong in both formats, the problem is in the capture path or the data
bus wiring.
