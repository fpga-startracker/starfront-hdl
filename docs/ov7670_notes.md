# OV7670 notes

Carried over from the Basys 3 OV7670→VGA project, which reached a working live
colour image. Everything in the "pitfalls" section below was paid for in days
of debugging there; none of it is obvious from the datasheet.

## Runtime grayscale mode is built in

The design has a runtime `gray_mode` select and the top level exposes it on
`KEY3`. In the default state the sensor is configured for RGB565, which matches
the 320×240 frame buffer and the live colour image. When `gray_mode` is asserted
it reconfigures the OV7670 for YUV422 grayscale output (`COM7 = 0x00`,
`COM15 = 0x00`), and the FPGA keeps only the luminance byte for each pixel.

That is the working mode for the astro path: the detector wants one 8-bit
brightness sample per source pixel, not a 16-bit colour word. The design maps
that Y byte back into the existing framebuffer path so the same live image
pipeline still works, while the star engine consumes the full-resolution
luminance stream directly from `cam_pixel_stream`.

The colour-bar test pattern is still in the register ROM and is useful for
bench debugging, but it is not the default bring-up mode in this build. The
project now treats grayscale as the normal scientific mode and RGB565 as the
reference display mode.

## Pitfalls that cost real time on the previous board

### 1. Never read the data bus combinationally while writing the frame buffer

The OV7670 changes `D[7:0]` on the **falling** edge of PCLK (`tPDV` = 5 ns max).
Composing a pixel from `ov7670_data` inside a `posedge pclk` block reads the bus
while it may still be settling, and the result is per-pixel rainbow noise.

The fix is a three-cycle register pipeline: latch byte 1, latch byte 2 and set
a ready flag, then compose the pixel from the two **registered** bytes and write
it. Grayscale hides this bug because it only uses byte 1, which was latched;
colour exposes it immediately.

### 2. A partial register init is not enough

Setting COM7 to RGB and COM15 to 0xD0 does not give correct colour. The sensor
also needs `0x8C = 0x02` for RGB444 xRGB byte order, and it converts YUV to RGB
internally through a programmable matrix (MTX1–MTX6 at 0x4F–0x54, signs in MTXS
at 0x58). Left at defaults the matrix applies YUV coefficients and you get
purple whites and red-as-green.

A working init needs: output format, clock config, colour matrix, the 16 gamma
registers at 0x7A–0x89, AGC/AEC/AWB parameters, the AWB coefficients at
0x43–0x48 / 0x59–0x5E / 0x6C–0x6F, and several undocumented registers —
especially `0xB0 = 0x84`, which every working project sets and nobody can
explain.

### 3. Leave camera-side scaling off

Keep `COM3 = 0x00`. With `COM3 = 0x04` the sensor emits QVGA directly, which
halves the pixels per line; FPGA-side downsampling logic written for VGA then
produces a garbled 160×120 image.

### 4. Skip the first pixel of each line

The register pipeline is one cycle deep, so at the start of a line the staging
registers still hold the end of the previous line. Writing that produces a
coloured artefact down the left edge. Guard the ready flag with
`pixel_num >= 1`.

### 5. COM13 must be 0xC0

`0x3D = 0x88` sets a reserved bit and gives a blue-purple cast. Every working
project uses `0xC0` (gamma enable plus UV saturation auto-adjust).

### 6. Check every pin against the schematic

A single swapped data bit produces subtle, persistent colour errors that cannot
be fixed in logic. Cross-check the whole bus before believing any colour bug.

### 7. Pixel format: RGB565, not RGB444

This project started on RGB444 (`0x8C = 0x02`), inherited from the Basys 3
design, and moved to RGB565 once there was a live picture to look at. Four bits
per channel is sixteen levels: in a dim scene nearly every pixel sits in the
bottom two or three of them, so one LSB of sensor noise is a sixth of the signal
and the image looks like coloured static. RGB565 gives green six bits and red
and blue five.

The switch is one register - `0x8C = 0x00` disables RGB444, and `COM15 = 0xD0`
already selects RGB565 in bits[5:4]. It is not free in memory though: the frame
buffer went from 36 to 48 RAMB36 tiles, and with the ILA that is 54 of the 60
the 7z010 has.

RGB565 byte order (with `TSLB[3] = 0`):

    Byte 1: { R[4:0], G[5:3] }
    Byte 2: { G[2:0], B[4:0] }

so the stored pixel is simply the two bytes concatenated. If the colours come
out scrambled in a way that looks like channels bleeding into each other, try
`TSLB` (`0x3A`) `= 0x0C` to swap the byte order. If they are merely *wrong*
rather than scrambled, it is the register config (pitfall 2), not the order.

### 8. Use the built-in colour bars to split the problem in two - but set the right register

The sensor has a digital test pattern generator that bypasses the pixel array
and the whole analog chain. A clean, stable pattern means the data bus, the
capture pipeline, the frame buffer and the display are all correct, and anything
left is the sensor's ISP or the optics. A speckled pattern means bit errors on
the data bus.

The selector is two bits, **`(SCALING_YSC[7], SCALING_XSC[7])`**:

| Value | Pattern |
|---|---|
| `00` | none |
| `01` | shifting "1" - fine vertical stripes |
| `10` | **8-bar colour bar** |
| `11` | fade-to-gray colour bar |

The Basys 3 project's notes said to set `0x70` (SCALING_XSC) bit 7 for the
colour bars. That is wrong, and confirmed wrong on hardware: it gives the
shifting "1" pattern. The colour bar needs **`0x71` (SCALING_YSC) bit 7**, i.e.
`0x71 = 0xB5`, with `0x70` left at `0x3A`.

The shifting "1" is not useless - it is arguably the better wiring test, since
any bit error breaks its regularity immediately.

### 9. A band of junk down one edge is the window, not the FPGA

HSTART and HSTOP choose which 640 of the sensor's 784 column clocks are emitted.
Put that window over the array's dummy columns and those pixels come out as
garbage - and no FPGA-side work can recover them, because the data was never
there. Four positions that are all exactly 640 wide:

| `hstart_sel` | HSTART / HSTOP / HREF | window starts at | |
|---|---|---|---|
| 0 | `0x16` / `0x04` / `0x80` | 176 | the Basys 3 value - **shows the junk band on this board** |
| 1 | `0x13` / `0x01` / `0xB6` | 158 | Linux `ov7670.c` - **clean, and the default** |
| 2 | `0x12` / `0x00` / `0x80` | 144 | |
| 3 | `0x18` / `0x06` / `0x80` | 192 | |

KEY4 steps through them at runtime and the current selection shows on the
overlay, so finding the right one is a few button presses rather than a rebuild
each time. Confirmed on hardware 2026-09-04: position 0 has the band, position 1
does not.

    HSTART_full = (0x17 << 3) | HREF[2:0]
    HSTOP_full  = (0x18 << 3) | HREF[5:3]
    width       = (HSTOP_full - HSTART_full) mod 784

## Timing numbers (from the OV7670 datasheet)

| Parameter | Value |
|---|---|
| `tPDV` — PCLK falling to data valid | 5 ns max |
| `tSU` — D[7:0] setup to PCLK rising | 15 ns min |
| `tHD` — D[7:0] hold after PCLK rising | 8 ns min |
| SCCB `tSU:STA` / `tHD:STA` / `tSU:STO` | 600 ns min |
| SCCB `tSU:DAT` | 100 ns min |

With `CLKRC = 0x80` the sensor passes XCLK straight through, so **PCLK = XCLK**.
At 25 MHz XCLK that is a 25 MHz PCLK and, because YUV and RGB modes send two
bytes per pixel, a 12.5 Mpixel/s rate. The Basys 3 XDC constrained PCLK at
12.5 MHz, which under-constrained the input path; this project constrains it at
25 MHz (40 ns).

### 10. A band drifting down the screen on fast motion is tearing, not a bug

There is one frame buffer, and the camera writes into it while the display
reads out of it. Where the two pointers cross, the top of the screen shows one
frame and the bottom shows the next, which reads as a horizontal seam. It only
becomes visible when something in shot moves fast enough for the two halves to
disagree.

The seam drifts because the two frame rates are close but not related:

    display frame  800 x 521           = 416,800 clocks = 16.67 ms
    camera frame   784 x 510 x 2 bytes = 799,680 clocks = 31.99 ms

a ratio of 1.919, not 2, so the crossing point walks slowly down the picture.

Removing it properly needs a second frame buffer to capture into while the
first is displayed. That does not fit: RGB565 costs 48 of the 60 BRAM tiles and
two of them would need 96. It becomes affordable at 8 bits per pixel, which is
where the grayscale astro path is heading anyway.

It is worth being clear that this does not matter for the actual application.
Star fields do not move fast, and the centroid engine planned for M5 processes
the pixel stream as it arrives rather than reading this buffer at all - the
frame buffer exists so a human can see what the camera sees.

## Register identity

| Register | Value | Meaning |
|---|---|---|
| `0x0A` PID | `0x76` | product ID |
| `0x0B` VER | `0x73` | version |
| `0x1C` MIDH | `0x7F` | manufacturer ID high |
| `0x1D` MIDL | `0xA2` | manufacturer ID low |

Device address is `0x42` for a write and `0x43` for a read.

## Register profile for star tracking (planned, milestone 5)

The 94-register table from the Basys 3 project is tuned for a pleasant-looking
consumer image, and almost every one of those choices is wrong for photographing
stars. When the astro path is built it needs a **separate** profile:

- **Manual exposure and gain.** `COM8 = 0x00` turns off AGC, AEC and AWB.
  Auto-exposure will happily crush a field of faint stars into black because
  most of the frame is empty. Exposure goes in AECH / AECHH / COM1, gain in
  GAIN / VREF.
- **No auto white balance.** Star colour carries information; AWB destroys it.
- **Linear gamma.** The default gamma curve lifts the noise floor and compresses
  the highlights, which is the opposite of what centroiding wants.
- **De-noise and edge enhancement off** (`COM16`, `DNSTH`, `EDGE`). Both operate
  on small bright features — which is exactly what a star is. Denoise will
  delete them.
- **YUV422 output** (`COM7 = 0x00`), keeping only the Y bytes. That gives a
  true 8-bit luminance image at half the storage of RGB444, and luminance is
  what a centroid algorithm actually consumes.

Also worth stating plainly: the OV7670 is a rolling-shutter consumer sensor with
small pixels and a limited maximum exposure. It is fine for proving the pipeline,
but sensor choice should be revisited before the tracker has to work on real sky.
