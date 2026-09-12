# Star centroiding

How the detector finds stars and where its accuracy comes from, what it was
measured against, and which parts of it are the paper's and which are not.

The reference is Panousopoulos, Papaloukas, Leon, Soudris, Koumandakis and
Lentaris, *HW/SW co-design on embedded SoC FPGA for star tracking optimization
in space applications*, Journal of Real-Time Image Processing **21**:16 (2024).
Section numbers below are theirs.

---

## 1. The pipeline

```
1024x1024 8-bit display codes
   │
   ├─ bin_nxn        4x4 mean                          paper 4.1
   ├─ pix_lut        8-bit code -> 12-bit linear light
   ├─ bg_track       per-column median, global MAD, two thresholds, and the
   │                 same median linearised for the weights
   ├─ 8 line buffers 9x9 region of interest in registers
   ├─ seed test      local maximum, above threshold, inside the field of view
   ├─ region_grow    8-connected component of the RoI                paper 4.2
   ├─ cg_engine      centre of gravity, 8 fractional bits            paper 4.4
   └─ star list      up to 64 per frame, double buffered
```

One pixel per clock throughout, no frame store, fixed latency. On a 7z010 at
25 MHz that is 24 frames a second of 1024x1024, which is the replay rate of
`frame_source`, not a limit of the detector.

---

## 2. What is taken from the paper, and what is not

**Taken.** The overall chain - bin, threshold, cluster, centre of gravity - is
theirs, as is the word-length argument in section 3.3: accumulate against
coordinates relative to the window's top left corner and add the absolute
position back at the end, so the multipliers are four bits wide instead of
eight. The two-level threshold (a high one to start a cluster, a lower one to
grow it) is section 4.2. The fixed-point divide with a small number of
fractional bits is section 4.4.2, though this uses eight fractional bits where
they use four - their target is 0.1 pixels of a 2048-wide sensor and this one
is chasing a hundredth of a DUST pixel.

**Not taken - region growing.** Their clustering keeps the image in RAM, walks a
stack of candidate pixels, and marks an "examined" bitmap. That needs random
access to a frame store, a stack, and a variable number of cycles per cluster.
Here the region of interest is 9x9 and already sits in registers, so the
8-connected component containing the seed is obtained by four rounds of
dilation intersected with the threshold mask (`region_grow.v`). This is not an
approximation: every pixel of a 9x9 window is within four steps of the centre
under 8-connectivity, so the iteration has reached its fixed point after four
rounds and the set is the one the stack would have returned. It is
combinational, about eight levels of logic, and fits inside the cycle that
captures the cluster.

**Not taken - Fast Gaussian Fitting.** Section 4.5 is a single-precision
floating-point Cholesky decomposition of a 5x5 system. On their Zynq-7020 it
takes 13 DSPs for the logarithm alone and runs at 1 Mcluster/s. The 7z010 in
this project has 80 DSPs total and 17 600 LUTs, and the measurement below says
the arithmetic is not what limits accuracy here anyway - the threshold is. FGF
would be the right next step on a larger part.

**Not in the paper - the background estimator.** Their threshold is a value the
PS writes over AXI4-Lite. That is fine for a lens looking at a black sky; the
DUST field is vignetted from code 84 on one side of the illuminated disc to 58
on the other and carries airglow on top, so a single number over-thresholds one
edge and under-thresholds the middle. `bg_track.v` follows it instead.

---

## 3. The background estimator

Three sign-LMS median followers: step up or down by a fixed amount according to
which side of the estimate the sample fell on. They converge to a median rather
than a mean, which is the point - a star must not be allowed to lift its own
baseline - and each costs a comparator and an adder.

**Per column, not along the raster.** This is the single change that made the
detector work. A follower running along the raster meets a 26-code cliff at
every line wrap and spends the next hundred columns climbing it; it never
settles, and the residual it leaves is lag rather than noise. Measured, that
put the deviation estimate at 6 codes against a true 1, and the threshold 30
codes above the background where the dataset's own truth puts it 9. One
estimate per column sees a background that moves a tenth of a code per row, and
tracks the dataset's 21x21 local median to within half a code.

**Gated to the illuminated disc.** A column crosses the rim twice and that is a
67-code step no follower can climb. Gated, a column sees only sky, and because
the vignetting is radial the value a column leaves at the bottom of the disc is
very nearly the one it needs at the top of the next frame.

**Detection in code space, weighting in linear light.** The images are sRGB
encoded, which is close enough to logarithmic that the noise is about the same
size everywhere in a frame spanning two decades of brightness - so one
median-plus-MAD rule holds across the whole field, and the thresholds it
produces land within a code of the ones the dataset computed from real sensor
data. Light, though, adds linearly, and a first moment of anything but light is
not a centroid, so `pix_lut` linearises before the weights are taken. Skipping it costs almost exactly a factor of two: replacing the table with a
plain ramp moves the median error from 0.479 to 0.931 display pixels. It also
*raises* the match rate slightly, from 67% to 72% - the flattened cores make
more faint stars clear the threshold, and every one of them lands in the wrong
place.

Threshold: `background + k * 1.4826 * MAD`, with k = 5 sigma to start a cluster
and 3 sigma to grow one. The grow level matches the cut the dataset's own boxes
use, so the pixel sets are directly comparable.

**The weights are measured against the same local median, linearised.** The
centre of gravity subtracts a background from every pixel it weights, and
until 2026-09-12 that background was a separate global follower - one number
for the whole frame. That was the largest single error in the pipeline. The
vignetting that is a 26-code spread in code space is a factor of two in
linear light, so a frame-wide value sat about a hundred counts wrong at either
side of the disc, where a wing pixel's real excess over the sky is thirty or
forty: on the bright side the wings were over-weighted, on the dark side they
were clipped to zero and faint stars failed the flux gate altogether. The
dataset's own blob truth subtracts the local 21x21 median converted to linear
light (`display_encode.py`, `blob_centroid`), and the per-column follower
already tracks that median to within half a code, so the fix is to put the
centre column's median through the same 256-entry table the pixels go through.
Median error 0.482 -> 0.401 display px, completeness 65.4% -> 68.8%, no new
state. Interpolating the follower's fractional bits between two table entries
was measured as well and is worth 0.002 px, which does not buy a multiplier.

---

## 4. Accuracy

Scored by `bench/evaluate.py` against the DUST display set, 381 frames sampled
across all 22 sessions, 9001 catalogued stars.

### The centroider on its own

`uv run bench/evaluate.py --centroider` places a fixed window where the dataset
places its own and compares with `display_x` / `display_y`, which is a
threshold-free truth. This exercises every integer width in the design - the
12-bit table, the background subtraction, the accumulators, the rounded divide -
and nothing else.

| | display px |
| --- | --- |
| median | **0.0076** |
| p95 | 0.0325 |
| max | 3.70 |
| one fixed-point LSB | 0.0156 |

Half an LSB at the median. Read it for what it is: a self-consistency check that
says no width was got wrong, not an accuracy measurement - doing the reference's
own arithmetic in higher precision *should* come out at the quantisation floor,
and the interesting result would have been any other answer. Note also that this
path is a third implementation, written inline in `evaluate.py`; it shares no
code with `starfront_model.detect` and is not the path `sim/centroid` checks
against the RTL. The 3.7 px maximum is a handful of stars whose window at the
rounded astrometric position is not the window the dataset used.

### The detector end to end

Scored against `display_blob_x` / `display_blob_y`, the dataset's
threshold-and-label truth, which is what a detector front end should be compared
with.

| | display px | DUST px |
| --- | --- | --- |
| median | 0.401 | 0.100 |
| mean | 0.635 | 0.159 |
| p95 | 2.17 | 0.54 |
| systematic offset | dx +0.07, dy -0.01 | |

(Before the linearised column background of 2026-09-12 the median was 0.482
and the mean 0.707 on the same frames.)

Completeness, by the star's peak signal in sensor DN:

| peak DN | truth stars | found | |
| --- | --- | --- | --- |
| 0-50 | 3219 | 1593 | 49% |
| 50-80 | 2808 | 2167 | 77% |
| 80-150 | 1561 | 1321 | 85% |
| 150-400 | 1125 | 855 | 76% |
| 400+ | 288 | 258 | **90%** |

**The denominator here is not every catalogued star.** It is the 80.4% of them
that got a blob at all and survived the dataset's own advised filters
(`box_truncated == 0`, `box_fill >= 0.3`). Against every catalogued star in
these frames the figure is 68.8% x 0.804 = **55.3%**. Both numbers are true and
they answer different questions; the 69% is the fair one for a detector, since
the excluded rows are stars the dataset itself could not segment.

Unmatched detections run at about 22 a frame against 24 catalogued stars - more
than half of everything reported. Some are real sources the astrometric solution
did not catalogue and some are noise; the dataset gives no way to tell them
apart, so they are reported rather than tuned away. A star identification stage
downstream has to be able to live with that ratio.

### Measured on the board

`bench/score_hardware.py`, over 20 frames streamed to the hardware over JTAG and
the star lists read back, against exactly the same truth and with exactly the
same matching rule the model is scored with. **These figures are from
2026-09-09, with the global linear background**; the linearised column
background has passed the bit-exact simulation against the model on a real
frame but has not yet been re-scored on the board, so the model's 0.401 is the
current claim and the row below is the last hardware measurement.

| | board | model, same 20 frames |
| --- | --- | --- |
| matched | 607 of 797 (76.2%) | 611 of 797 (76.7%) |
| median error | **0.4770** | 0.4697 |
| mean | 0.7160 | 0.7031 |
| p95 | 2.2665 | 2.2293 |
| peak_dn >= 100, median | 0.4266 | - |

Eight thousandths of a display pixel apart at the median. The first star of the
first frame comes back as `x_fix 28298, y_fix 2506, npx 14`, which is the
model's answer to the digit; the flux differs by 14 counts in 9962 because the
board reached that frame by streaming the one before it while the model warms up
on four passes of the same frame, so their frame-background followers are one
count apart.

That is what the whole three-layer verification was for, and it is now measured
rather than argued: the model's figures over hundreds of frames describe the
hardware.

Streaming ran at 2.65 frames a second - 64 KB an AXI burst at a time down the
JTAG cable. The detector itself is unaffected and still runs at 24 fps on
whatever is loaded.

### Reading these numbers honestly

The gap between 0.008 px for the centroider and 0.48 px for the detector is
entirely the threshold. The dataset's truth cuts each blob at *that star's own*
local median plus 3 MAD-sigma over a 21x21 window; any detector whose threshold
differs by a code includes or excludes a wing pixel and lands somewhere else.
Feed the pipeline the dataset's own per-star thresholds and the error drops to a
median of **0.197** display pixels, with the remainder being the 9x9 window
against the dataset's reach-15 blob.

So: **0.008 px is what the arithmetic does, 0.20 px is what the algorithm does
given a perfect threshold, and 0.40 px is what the whole thing does having had
to estimate the threshold itself.** The last number is the honest one for a
detector, and the middle one says where the remaining error lives. It was
0.48 until the weights were measured against the local background rather than
a global one - that gap was not the threshold at all, and it is closed.

### What these numbers do not say

- **The full-set figures are still the model's.** The board has now been scored
  directly, and agrees to 0.008 px at the median - but over 20 frames from one
  session, not 381 across all 22. The claim that the model describes the
  hardware is measured; the claim that 20 frames represent the set is not. That frame carries 57 stars and exercises the
  thresholds, the region growing, the divide and the list, so it is a strong
  sample; it is still one frame in 1378. The test also compares position and
  flux only, because the star list has no read port for the pixel count.
- **The mean is optimistic by about a fifth.** A truth star with no detection
  within 6 display pixels counts as *not found* rather than as a large error, so
  the error distribution is truncated. Widening the match radius to 24 px adds
  only 5 pairs in 419 and leaves the median at 0.486, but pulls the mean from
  0.745 to 0.887. Quote the median.
- **No arcseconds.** A star tracker specification is angular, and the display set
  does not state the DUST field of view, so 0.120 DUST pixels cannot be
  converted. The paper's own pixel-domain requirement is a maximum centroiding
  error of 0.25 px, which this meets at the median and not at the p95.
- **The 0.095 px floor quoted in the dataset does not apply here.** That is the
  error its display encoding injects against *physical sensor* truth.
  `display_blob_*` is defined on the very image this design consumes, so there is
  no encoding floor between the two - the only floor is the fixed-point LSB.

---

## 5. Choices that were measured, not assumed

| Question | Answer | Evidence |
| --- | --- | --- |
| Window size | 9x9 | 13x9 and 15x9 changed the error by under 0.01 px; the smear tail is covered by the grow, not the window |
| Weight the blob or a fixed square? | the blob | a fixed 7x7 scores 2.3x worse on the median against `display_blob_*`, because it is measuring something else |
| Linearise the input? | yes | a plain ramp instead moves the median from 0.479 to 0.931 px |
| Track background per column? | yes | per-raster gives a threshold 30 codes up where truth says 9 |
| Fractional bits | 8 | 4 (the paper's) is 0.0625 binned px = 0.25 display px, coarser than the answer |
| Seed / grow thresholds | 5 sigma / 3 sigma | swept; 3 sigma grow matches the truth's own cut and minimises error. Re-swept after the background change: 2.5 sigma 0.468, 3 sigma 0.401, 3.5 sigma 0.426, and the sign of the x offset flips across it (-0.11, +0.07, +0.25) as the smear tail is let in or cut off |
| Background under the weights | the column median, linearised | the global linear follower scored 0.482; the centre column's median through the table 0.401; the same with the accumulator's fractional bits interpolated 0.399 |
| MAD per column, like the background? | no, keep it global | median unchanged (0.398) but completeness fell 68.8% -> 64.9% and the x offset grew +0.07 -> +0.17: a per-column deviation sees 256 samples a frame instead of 65536 and settles high |
| Columns per accumulate cycle | 2 | two stars can be five columns apart, and a slower engine drops one of them |
| Warm-up frames after reset | 4 | completeness climbs 62% -> 70% from two frames to four, then stops |
| Zero the scroll before a scored run | yes | an offset that is not a multiple of four resamples the binned image; at -19 the board's median error went 0.477 -> 0.599 |

---

## 6. Verification

Three layers, because no single tool covers it:

- `bench/starfront_model.py` is a bit-exact integer model - shifts, no floating
  point in the data path. It is what the accuracy numbers above are measured
  with, over hundreds of frames, at about a second a frame. It scores each frame
  with the background followers settled, four passes in, because that is the
  state the hardware spends all but its first sixth of a second in.
- `sim/centroid` drives the RTL with the same pixels and demands the same star
  list: identical count, identical fixed-point coordinates, identical flux.
  Nothing there is a tolerance. It runs a synthetic field always and a real DUST
  frame when `STARFRONT_DATA` points at the display set.
- The `bench` bitstream runs the same RTL on the board at 24 frames a second and
  draws what it found.
- `bench/score_hardware.py` scores the star lists the board reports over JTAG
  against the same DUST truth, the same way, so the hardware's own number can be
  put beside the model's.

The middle layer is what makes the first one mean anything about the hardware;
the last one removes the need to take it on trust.

---

## 7. Resources

Measured, for the `bench` variant, which includes the frame store, the display
path, the DVI transmitter and the ILA. 7z010: 17 600 LUT, 35 200 FF, 60 BRAM36,
80 DSP.

| | used | % |
| --- | --- | --- |
| LUT | 8507 | 48 |
| flip-flop | 7663 | 22 |
| block RAM | 37.5 | 62 |
| DSP | 2 | 2.5 |

WNS +1.725 ns on the 25 MHz pixel clock, all constraints met, zero failing
endpoints - but that is 38.3 ns of a 40 ns period, so **Fmax is about 26 MHz and
the margin is 4%**, where `bringup` has 12.6 ns of slack on the same clock. (It
was +3.6 ns before the linearised column background; the worst path did not
change, the placement did.) That path runs from the scroll offset register
through the field-of-view mask into the seed decision, and from there through
the capture cycle's two-column accumulate into the divider's hold register -
38 ns, of which 22 is routing. It is the chain the detector deliberately buys
cycles with, alongside the eighty-comparator peak test and `region_grow`'s four
dilation rounds. It passes, and there is no room to add anything on this clock
without registering the seed decision first.

The frame store dominates the block RAM: 32 of those 37.5 tiles, holding **two**
256x256 buffers so a frame arriving over JTAG cannot tear the one on screen.

Getting it to 16 tiles a buffer took two goes at the same lesson. As a read-only
ROM with two read ports, Vivado builds a *second copy* of the whole memory
rather than using the second port - it does that whatever inference template is
written, because a ROM has no write port to hang the second port's logic on, so
one frame cost 32 tiles and two would not fit. Giving the store a real write
port for the host fixes that. Then the write and the replay read used *different
addresses in the same always block*, which is not a block RAM port at all - a
port has one address bus - and the memory came out as 69 tiles of the 60 this
part has. Muxing the address made it a port.

Every memory the detector itself needs - eight line buffers, the binner's column
accumulator, the per-column background, the star list - is distributed RAM. None
of them is more than a few kilobits and block RAM is what runs out on this part.

---

## 8. Where this goes next

- **Threshold.** The measurement says this is where the remaining error is:
  0.40 px with the estimated threshold against 0.20 with the truth's own. A
  per-column deviation estimate has been tried and does not help (section 5).
  What is left is the *level*, not the noise: the truth's median is local in
  both axes (21x21 about the star) and the column follower is local in x only,
  so airglow structure and the halos of neighbouring stars along a column are
  what it cannot follow. A two-dimensional local estimate - the ring of the 9x9
  window, which is already in registers - is the next thing to measure.
- **Detection of faint stars.** Half the stars below 50 DN are missed. Seeding
  on a 3x3 sum of the window rather than the single centre pixel raises the
  detection SNR by about the square root of the pixel count; the window is
  already there and the centroid can still be taken on the raw pixels.
- **Fast Gaussian Fitting.** Section 4.5 of the paper, on a part with the DSPs
  for it. The measurement above says it would only pay once the threshold is
  fixed.
- **More than one cluster in flight.** The engine holds one; a second seed
  within five columns is dropped and counted. It is zero on real frames now, but
  a denser field would need a queue.
- **The camera path.** `star_centroid` takes a generic binned pixel stream,
  and `cam_pixel_stream` now delivers the sensor's own 8-bit Y (YUV422, see
  pitfall 11 in `docs/ov7670_notes.md`), which is the right input. Two things
  stand in the way of just wiring them together: `star_centroid` and
  `bin_nxn` carry 8-bit coordinates, so they stop at 256x256 where the camera
  is 640x480; and the rest of the astro register profile - manual exposure,
  linear gamma, denoise off - is still the consumer one. See the last section
  of `docs/ov7670_notes.md`.
