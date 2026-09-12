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
| M4 | Frame buffer + live image | done | capture | **passed 2026-09-04** in RGB565; the YUV422 / 8-bit gray version of 2026-09-12 is not yet seen on hardware |
| M5 | Streaming star detection at full 640×480 | done | star | **passed 2026-09-04** — tracks a phone torch in a dark room |
| M6 | Sub-pixel centroiding, measured against a real star field | done | centroid — RTL matches the model bit for bit | not yet on hardware |

The `bringup` build variant stops after M4; `tracker` adds M5; `bench` is M6 on
its own, with no camera at all.

A live image on screen means M2 and M4 both hold: the image only replaces the
overlay once `init_done` is high, and `init_done` only happens after the ID
probe hands over the SCCB bus. M3's own criterion is the measured geometry -
hold KEY2 and read row 1, which should say `0500 01E0`.

## What the board shows you

**Keys:** KEY1 reset · KEY2 hold to force the status overlay over a live image ·
KEY3 toggle the sensor's 8-bar test pattern · KEY4 step the horizontal window
position (see pitfall 9 in `docs/ov7670_notes.md`) · KEY2 held + KEY4 swap
which byte of each YUV422 pair is taken as luminance (see M4 below).

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
| row 0, red tab | `PID VER`, window selection (+4 while the Y byte is swapped), register read-back | `7673 0101` (`7673 0501` swapped) |
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
| 8-bit luminance frame buffer, 320x240 (`bringup`, `tracker`) | 24 |
| stored star fields, 2 x 256x256 x 8 bit (`bench`) | 32 |
| ILA, 1024 deep x ~93 probe bits | ~3 |
| star detector line buffers | 0 - distributed RAM, ~570 LUTs |
| centroid pipeline: 9x9 window, per-column background, star list | 0 - all distributed RAM |
| **available** | **60** |

The streaming star detector deliberately costs no block RAM: four line buffers
are 20 Kbit and go in LUTs. That is the whole reason it processes at the
camera's full 640x480 while the display path settles for a quarter of that -
buffering a 640x480 frame at 8 bits would need 75 tiles.

The display buffer went from 48 tiles to 24 when the sensor moved to YUV422
and the buffer to 8-bit luminance; that is the headroom a second buffer (to
stop tearing) or a star catalogue would live in. If something needs more, the
next lever is the ILA (bring-up is what it was there for). On the `bench`
variant the lever is `N_FRAMES` - each stored frame is 16 tiles.

Every memory the centroid pipeline needs is deliberately distributed RAM: eight
line buffers of 256 x 12 bits, the binner's 256-word column accumulator, the
256-word per-column background, and a 2 x 64 entry star list. None of them is
more than a few kilobits, and block RAM is what runs out on this part.

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

The sensor runs in YUV422 and only the Y byte of each pixel is kept. Capture
goes into a 320×240 × 8-bit inferred block RAM and is pixel-doubled back to
640×480 for display, the same byte on all three channels. The overlay hands
over to the live image automatically once `init_done` goes high.

1. **Test bars first.** Press KEY3 to switch the sensor to its 8-bar test
   pattern. That re-runs the whole register table, so the screen goes back to
   the overlay for about a tenth of a second and then shows the bars. In
   luminance the eight bars are a **descending gray staircase**: white,
   then progressively darker steps, black on the right. Stable bars in that
   order mean capture, block RAM and display are all correct, and any
   remaining problem is in the sensor's ISP configuration.
2. **If the bars are bright and dark in a jumbled order,** or the live picture
   is a fine vertical comb, the FPGA is keeping the chroma byte instead of the
   luma one. Hold KEY2 and press KEY4 once: that swaps the byte pick
   instantly, and the overlay's window digit on row 0 reads `05` instead of
   `01` while swapped. If that fixes it, make `Y_SECOND_DEFAULT` 1 in
   `top_starfront.v` so the next build comes up right.
3. **Then press KEY3 again** for the live image.

**Pass:** a live grayscale image, with the test bars in the right order. That
completes camera bring-up.

If the bars are right but the live image is wrong, work through pitfalls 2
and 5 in `docs/ov7670_notes.md` — that is the ISP configuration, not the
FPGA. If the bars themselves are wrong, the problem is in the capture path or
the data bus wiring.


## M6 — sub-pixel centroiding

This one has no camera in it. `top_starfront_bench` replays star fields out of
block RAM through the same detector a camera would feed, and draws what it
found. The point is that accuracy needs a known answer, and no camera pointed at
a monitor gives you one repeatably.

```bash
uv run bench/prepare_frames.py --report      # DUST frames -> build/frames.mem
./scripts/build.sh impl bench
./scripts/program.sh bench
```

The screen is the image on the left at 2x, a cross on every star found, and the
detector's own state as text down the right.

1. **The picture appears.** A round star field on the left, text on the right.
   If the field looks like a smooth disc with a few obvious dots and nothing
   else, `build/frames.mem` did not load and you are looking at the synthetic
   pattern `frame_source.v` falls back to. Check the Vivado log for the
   `$readmemh` warning.
2. **STARS is not zero,** and roughly matches what the model says for the same
   frame — `bench/prepare_frames.py --report` prints that number.
3. **DROP is zero.** It counts seeds thrown away because the centroid engine was
   still busy with the previous one. Anything but zero means the field is denser
   than the engine can keep up with, and the star list is incomplete.
4. **The crosses sit on the stars.** This is the whole thing: the marker is
   drawn from the centroid, so a marker that is visibly off its star is a bug in
   the pipeline and not in the display.
5. **FPS reads 0x18** (24). That is one 1024x1024 frame every 42 ms at the
   25 MHz pixel clock, which is the replay rate, not a limit of the detector.

KEY3 toggles continuous scrolling, KEY4 holds the replay so the last result
stays on screen while you read it, and KEY2 scrolls on by a single display pixel
at a time. A host over JTAG can take all three - see section 7.

**Pass:** crosses on the stars, DROP zero, and STARS within a couple of the
number the model reports for the same frame.

### 6. The sub-pixel check, on the board, with no host

Scrolling offsets the frame store's read address by whole *display* pixels, and
the 4x4 binner turns that into quarter-binned-pixel motion. So the centroid
readout has a predictable answer:

1. KEY4 to hold, KEY3 off so it is not scrolling on its own.
2. Note X. For the frame shipped in the bitstream the model predicts `89.6F`
   (it read `89.6C` on the board before the 2026-09-12 background change,
   which moved this star by three LSB).
3. Press KEY2 four times. **X must fall by exactly `0100`** - same fractional
   digits, one lower in the integer part: `88.6F`.

Four steps is a whole binned pixel and is exact for every star in the field
(measured spread 0.002 px). The individual quarter-steps are not, and that is
the interesting part - they go

```
89.6F -> 89.28 -> 88.E7 -> 88.A5 -> 88.6F
   -0.2773  -0.2539  -0.2578  -0.2109
```

which is the **S-curve** of an undersampled centroider, the error the paper
names in section 3.2. Its amplitude here is about 0.04 binned pixels. Seeing that
sequence on the screen is a stronger statement than any single number: it says
the pipeline is resolving a quarter of a pixel, and it says by how much
undersampling bends the answer.

The accuracy numbers themselves come from `bench/evaluate.py` over the whole
1378-frame set, not from the board — see `docs/centroiding.md`. What the board
proves is that the same arithmetic runs in hardware at video rate, and
`sim/centroid` is what proves it is the same arithmetic.


## M6b - streaming frames from a PC, and scoring the board

The bench bitstream carries a JTAG-to-AXI master. A host can write a new frame
into the store and read the star list back out, over the same USB cable that
carries the bitstream. That readback is the point: every accuracy figure in
`docs/centroiding.md` is the software model's, tied to the RTL by two frames in
simulation, and this is what measures the hardware itself.

```bash
uv run bench/export_stream.py --count 50 --skip-empty
./scripts/program.sh bench
./scripts/stream_video.sh build/stream 50 build/hw_stars.csv
uv run bench/score_hardware.py build/hw_stars.csv build/stream/truth.csv
```

1. **The link is checked first.** `feed_video.tcl` reads the magic register and
   refuses to send anything if it does not come back as `53544652`. A wrong
   answer there means either the bitstream is not loaded or Vivado's
   `get_property DATA` returns its words in the other order on this version -
   both of which otherwise look exactly like a stream of black frames.
2. **Each frame prints its own line** with the star count, the drop count and
   whether the list filled up. Compare those with what
   `bench/prepare_frames.py --report` says the model finds.
3. **`score_hardware.py` prints the same statistics `evaluate.py` prints**, over
   the frames actually streamed, so the two can be put side by side. A material
   difference there is a difference in the hardware, not in the scoring.

Expect a few frames a second. This is the debug cable, not a video link: the
AX7010's 32 MB QSPI flash is on `PS_MIO0..MIO6` and the Zynq's Quad-SPI
controller is MIO-only, so a PL-only design cannot reach it, and the only other
PL-side memory is a 512-byte EEPROM. A megabyte of image has to be shifted down
JTAG a kilobyte at a time. The detector still runs at 24 fps on whatever is
loaded - what arrives slowly is new content.

**Measured 2026-09-09:** 20 frames at **2.65 frames/s**, 0 dropped on every
frame, list never full. The board's median centroid error came out 0.4770
display pixels against the model's 0.4697 on the same frames - see
`docs/centroiding.md`. Vivado's `get_property DATA` does return its beats in
reverse, as `axi_read` assumes, and the magic-register check confirmed it before
a byte of image was sent.

Two things bit on the first run and are now handled in the script:

- **`refresh_hw_device -update_hw_probes false` hides the JTAG-AXI master.**
  Without the probes scan there is no `hw_axi` object at all, and the error
  reads as "no master on the device", which is indistinguishable from having
  loaded the wrong bitstream.
- **Turning the scroll off does not zero it.** Whatever it had drifted to keeps
  shifting the image, and an offset that is not a multiple of four resamples the
  binned frame - the board scored 0.599 instead of 0.477 until the script
  stepped the scroll back to zero first.
