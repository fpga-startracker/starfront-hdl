# OV7670 notes

Carried over from the Basys 3 OV7670→VGA project, which reached a working live
colour image. Everything in the "pitfalls" section below was paid for in days
of debugging there; none of it is obvious from the datasheet.

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

### 7. RGB444 byte order in xRGB mode

With `0x8C = 0x02`, byte 1 is `{x,x,x,x,R[3:0]}` and byte 2 is
`{G[3:0],B[3:0]}`, so the 12-bit pixel is `{byte1[3:0], byte2[7:4], byte2[3:0]}`.
This is **not** the RGB565 order most tutorials describe. If colours look wrong,
suspect the register config (pitfall 2) before the byte order.

### 8. Use the built-in colour bars to split the problem in two

Setting `0x70` from `0x3A` to `0xBA` turns on the sensor's 8-bar test pattern,
which bypasses the image sensor entirely. Correct bars mean the capture path,
frame buffer and display are all fine and any remaining problem is in the
sensor's ISP configuration. Wrong bars mean the problem is in the FPGA.

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
