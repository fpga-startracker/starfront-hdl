"""Bit-exact software model of the starfront centroiding pipeline.

This is the specification the RTL implements, written so that every number in
it is the number the hardware carries: integers of a stated width, shifts
instead of divisions, no floating point anywhere in the data path. The only
floats are in `build_lut`, which is evaluated once at build time and baked into
the bitstream as a table.

Why a model at all: the accuracy question ("how close is the centroid?") needs
thousands of frames to answer, and an RTL simulator does about one frame every
ten seconds. So the model answers the accuracy question over the whole DUST set
and `sim/centroid` answers the fidelity question - does the RTL agree with the
model, pixel for pixel - over a handful of frames. Together those two cover
what a single tool cannot.

Pipeline, following Panousopoulos et al., *HW/SW co-design on embedded SoC FPGA
for star tracking optimization in space applications*, J Real-Time Image Proc
21:16 (2024), section 3:

    1024x1024 codes
      -> bin 4x4            paper 4.1, mean over an N x N region, N = 2^n
      -> linearise          8-bit code -> 12-bit light, see `build_lut`
      -> background         running median and MAD, two time constants
      -> seed + grow        paper 4.2, region growing inside a fixed RoI
      -> centre of gravity  paper 4.4, relative coordinates then absolute
      -> star list

The one place this departs from the paper is the shape of the region growing.
The paper keeps the image in RAM and walks a stack; that needs random access to
a frame store and a variable number of cycles per cluster. Here the RoI is a
9x9 window that already exists as registers, so the same 8-connected region is
obtained by four rounds of dilation against the threshold mask - combinational,
fixed latency, and provably the same set (four rounds from the centre reach
every pixel of a 9x9). See docs/centroiding.md.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

SRC_W = 1024            # display image the sensor/screen presents
SRC_H = 1024
BIN_N = 4               # paper 4.1: N x N mean, N = 2^n
IMG_W = SRC_W // BIN_N  # 256, one DUST sensor pixel per binned pixel
IMG_H = SRC_H // BIN_N

WIN = 9                 # RoI side, odd. Reach 4 covers the smear tail (-5..+2)
HALF = WIN // 2

PIX_BITS = 12           # linearised pixel width, matching the paper's 12-bit path
PIX_MAX = (1 << PIX_BITS) - 1

FRAC = 8                # fractional bits of the centroid, 1/256 of a binned pixel
                        # = 1/64 of a display pixel

N_STAR_MAX = 64         # star list depth


# ---------------------------------------------------------------------------
# Input transfer function
# ---------------------------------------------------------------------------

def build_lut() -> np.ndarray:
    """8-bit display code -> 12-bit linear light. 256 entries, baked into the ROM.

    The images are sRGB-encoded on purpose: `display_encode.py` writes
    `code = 255 * srgb_oetf(T)` so that a monitor showing them emits light
    proportional to T. A camera looking at that monitor measures T. A centroid
    is a first moment of light, so the pipeline has to work in T as well - and
    when the image is fed to the FPGA digitally rather than through a screen and
    a lens, this table is what stands in for the monitor.

    Skipping it is not a small effect. sRGB has a slope of about 2.4 at the top
    end, so it flattens a star's core relative to its wings and pulls the
    centroid outward; over the DUST set that alone costs roughly a factor of two
    in centroid error.

    12 bits out, not 8: the background sits near code 35, which is T = 0.017.
    Rounding that to 8 bits would leave the entire faint end of the scene inside
    four code values.
    """
    c = np.arange(256, dtype=np.float64) / 255.0
    lin = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    return np.round(lin * PIX_MAX).astype(np.int32)


LUT = build_lut()


# ---------------------------------------------------------------------------
# Parameters. These are the RTL's generics; the defaults are what it is built
# with, and evaluate.py sweeps them.
# ---------------------------------------------------------------------------

@dataclass
class Params:
    # Background trackers. Both are sign-LMS median followers: add or subtract a
    # fixed step according to which side of the estimate the sample fell on.
    # That converges to the median rather than the mean, which is the whole
    # point - a star must not drag the background up behind it. Cost is a
    # comparator and an adder, no window and no sort.
    bg_frac: int = 6        # fractional bits of the code-domain accumulators
    bg_lin_frac: int = 10   # fractional bits of the frame-background accumulator
    step_bg: int = 8        # per-column background step, in accumulator LSB
    step_mad: int = 4       # MAD step
    step_lin: int = 1       # frame background step. 1/1024 of a code value per
                            # pixel, so it moves at most 64 counts in a frame -
                            # slow enough that where the raster ends cannot bias
                            # it, which a faster one very much is not.

    # Thresholds, in quarter-sigma units above the local median, where one sigma
    # is 1.4826 * MAD. The paper uses a high threshold to seed a region and a
    # lower one to grow it.
    k_seed_q: int = 20      # 5.00 sigma - starts a cluster
    k_grow_q: int = 12      # 3.00 sigma - joins one, and the cut the truth uses
    floor_code: int = 2     # absolute floor on (threshold - background), codes

    # Which pixels of the RoI carry weight in the centre of gravity.
    #   0        the grown region only - a blob centroid
    #   1..HALF  a fixed square of this half-width about the seed
    #
    # The grown region is the default, because that is what a threshold-and-
    # label front end produces and it is what the dataset's detector-side truth
    # (display_blob_*) is built from. A fixed square scores about 2.5x worse
    # against that truth, for the simple reason that it is measuring something
    # else: it weights every pixel of the square, including a neighbouring
    # star's wing and a patch of sky the blob would have excluded.
    #
    # The fixed square is not a worse centroider - it is the one the dataset's
    # display_x / display_y is computed with, and `evaluate.py --centroider`
    # scores it that way, on windows placed where the truth places them, where
    # it agrees to a few hundredths of a pixel. But that comparison hands the
    # algorithm the answer it is looking for. A detector has to find its own
    # window, and then the blob is the better shape.
    cg_half: int = 0        # 0 = the grown region

    # What is subtracted from each weighted pixel.
    #   0  a global linear follower (bg_lin) - one number for the whole frame.
    #      This is what the RTL did until 2026-09-12; kept so the old figures
    #      can be reproduced, the hardware no longer implements it.
    #   1  the per-column code background at the seed's column, through the
    #      linearising table. What the RTL does.
    #   2  the same, with the follower's fractional bits interpolated between
    #      two table entries. Measured: 0.002 px better than 1, not built.
    #
    # The dataset's blob truth subtracts the *local* 21x21 median, linearised.
    # A DUST frame is vignetted from code 84 on one side of the disc to 58 on
    # the other, which in linear light is a factor of two; a global number is
    # right in the middle and wrong by up to a hundred counts at either edge,
    # where a wing pixel's true excess over the sky is thirty or forty. The
    # per-column follower already tracks that median to within half a code, so
    # linearising it is one more table lookup and no new state. Median error
    # 0.482 -> 0.401 display px over the 381-frame sample; see
    # docs/centroiding.md section 3.
    cg_bg: int = 1

    # Deviation follower: 0 one global MAD, 1 one per column like the
    # background. Measured and rejected: the median error does not move and
    # completeness drops four points, because a per-column follower sees 256
    # samples a frame instead of 65536 and settles high. Not in the RTL.
    mad_col: int = 0

    # Quality gate applied to the grown region.
    min_npx: int = 4        # a real star fills at least this many binned pixels
    min_sum: int = 256      # and carries at least this much light

    # Circular field of view. The DUST optics illuminate a disc of radius ~120
    # px on a 256 px detector, so a quarter of every frame can never hold a star
    # and its rim is a steep gradient that a local threshold will happily seed
    # on. 0 disables the mask.
    fov_cx: int = 128
    fov_cy: int = 128
    fov_r: int = 122

    # Cold-start values, matching bg_track.v's reset state.
    prime_bg: int = 64
    prime_mad: int = 2
    prime_lin: int = 230

    n_star_max: int = N_STAR_MAX


DEFAULT = Params()


# ---------------------------------------------------------------------------
# Stage 1: binning (paper 4.1)
# ---------------------------------------------------------------------------

def bin_nxn(src: np.ndarray, n: int = BIN_N) -> np.ndarray:
    """Mean of every n x n region, truncated - an adder tree and a shift.

    On the DUST display images this is exactly invertible: each sensor pixel was
    written as a solid n x n block, so the mean of a block is the block's value
    and binning recovers the 256x256 sensor grid with no error at all. That is
    why the hardware can store a frame as 256x256 and still claim to process the
    full 1024x1024 image - it replays each stored pixel n times per axis and the
    binner puts it back.
    """
    h, w = src.shape
    assert h % n == 0 and w % n == 0
    acc = src.reshape(h // n, n, w // n, n).astype(np.int32).sum(axis=(1, 3))
    return acc >> (2 * int(math.log2(n)))


# ---------------------------------------------------------------------------
# Stage 2/3: linearise, and follow the background along the raster
# ---------------------------------------------------------------------------

@dataclass
class TrackerState:
    """Carried from frame to frame, exactly as the registers and RAM are in
    hardware. Nothing here is reset between frames: the sky does not change much
    in 40 ms, so the estimate the last frame ended on is the best one this frame
    can start from."""
    bg_col: np.ndarray | None = None    # per-column accumulator, code domain
    mad: int = 0                        # global accumulator, code domain
    mad_col: np.ndarray | None = None   # per-column accumulator, if mad_col
    bg_lin: int = 0                     # global accumulator, linear domain
    primed: bool = False


def fov_mask(p: Params, h: int = IMG_H, w: int = IMG_W) -> np.ndarray:
    """Pixels the optics actually illuminate.

    The DUST lens fills a disc of radius ~120 on a 256 px detector, so a fifth
    of every frame is unlit and can never hold a star. In hardware this is one
    squared-distance compare against a constant.
    """
    if p.fov_r <= 0:
        return np.ones((h, w), dtype=bool)
    yy, xx = np.mgrid[0:h, 0:w]
    return ((xx - p.fov_cx) ** 2 + (yy - p.fov_cy) ** 2) <= p.fov_r ** 2


def run_trackers(code: np.ndarray, lin: np.ndarray, p: Params,
                 st: TrackerState
                 ) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """One raster pass of the background followers.

    Returns four images holding, for each pixel, the state each follower was
    left in after that pixel was consumed - which is exactly what the hardware
    register or RAM word contains at that moment:

      bg_post   per-column background, code domain, integer codes
      mad_post  global median absolute deviation, code domain, as the raw
                accumulator with `bg_frac` fractional bits - the deviation is
                between one and two codes and rounding it to an integer there
                throws away a third of the threshold
      lin_post  global linear background follower
      acc_post  the per-column accumulator itself, `bg_frac` fractional bits

    All three are sign-LMS median followers: step up or down by a fixed amount
    depending on which side of the estimate the sample fell. They converge to a
    median rather than a mean, which is the entire point - the mean of a
    neighbourhood containing a star is not the background under that star, and
    the whole job here is to not let a star lift its own baseline.

    **The background is tracked per column, not along the raster.** The DUST
    field is vignetted from about code 84 on the left of the disc to 58 on the
    right, so a follower running along the raster hits a 26-code cliff at every
    line wrap and spends the next hundred columns climbing back. It never
    settles, and the residual it leaves behind is a lag rather than noise, which
    inflates the MAD to about 6 codes - three times the truth. Down a column the
    same background moves by a tenth of a code per row and one estimate per
    column tracks it with nothing left over. That single change is the
    difference between a threshold 30 codes above the background and the 9 the
    dataset's own truth uses.

    The MAD follower is global because after per-column subtraction the residual
    really is stationary noise, and a global one sees 65536 samples a frame
    instead of 256.

    Detection runs on the 8-bit code and weighting on the 12-bit linear value on
    purpose. The encoding is close to logarithmic, which is what makes the noise
    about the same size everywhere in code space - so one median-plus-MAD rule
    holds across a frame spanning two decades of brightness, and the thresholds
    it produces land within a code of the ones the dataset computed from the
    real sensor data. Light, though, adds linearly, and a first moment of
    anything but light is not a centroid.
    """
    sh = p.bg_frac
    sh_l = p.bg_lin_frac

    flat_c = code.reshape(-1)
    flat_l = lin.reshape(-1)
    h, w = code.shape

    if not st.primed:
        # The same constants bg_track.v resets to, so the model and the RTL
        # agree from a cold start instead of only once both have settled. A
        # column climbs to a real sky level in well under one frame at the
        # default step, and the linear follower starts within a few counts.
        st.bg_col = np.full(w, p.prime_bg << sh, dtype=np.int64)
        st.mad = p.prime_mad << sh
        st.mad_col = np.full(w, p.prime_mad << sh, dtype=np.int64)
        st.bg_lin = p.prime_lin << sh_l
        st.primed = True

    bg_col = st.bg_col
    mad_col = st.mad_col
    per_col_mad = bool(p.mad_col)
    mad, bg_lin = st.mad, st.bg_lin
    step, step_m, step_l = p.step_bg, p.step_mad, p.step_lin
    mad_min = 1 << sh

    # Only estimate the background where there is an image. A column crosses the
    # rim of the illuminated disc twice, and that is a 67-code step: a follower
    # that has to climb it spends most of a frame below the true background,
    # leaving a residual that is lag rather than noise and a MAD nine times too
    # large. Gated to the disc, a column sees nothing but sky, drifting a tenth
    # of a code per row - and because the vignetting is radial, the value a
    # column leaves at the bottom of the disc is the one it needs at the top of
    # the next frame.
    gate = fov_mask(p, h, w).reshape(-1)

    bg_post = np.empty(h * w, dtype=np.int32)
    acc_post = np.empty(h * w, dtype=np.int32)
    mad_post = np.empty(h * w, dtype=np.int32)
    lin_post = np.empty(h * w, dtype=np.int32)

    i = 0
    for y in range(h):
        for x in range(w):
            c = int(flat_c[i])
            acc = int(bg_col[x])
            b = acc >> sh
            if per_col_mad:
                mad = int(mad_col[x])
            m = mad >> sh
            d = c - b if c > b else b - c

            if gate[i]:
                acc += step if c > b else -step
                bg_col[x] = acc
                mad += step_m if d > m else -step_m
                if mad < mad_min:
                    mad = mad_min
                if per_col_mad:
                    mad_col[x] = mad

            v = int(flat_l[i])
            bg_lin += step_l if v > (bg_lin >> sh_l) else -step_l

            bg_post[i] = acc >> sh
            acc_post[i] = acc
            mad_post[i] = mad
            lin_post[i] = bg_lin >> sh_l
            i += 1

    st.bg_lin = bg_lin
    if not per_col_mad:
        st.mad = mad

    return (bg_post.reshape(h, w), mad_post.reshape(h, w), lin_post.reshape(h, w),
            acc_post.reshape(h, w))


def thresholds(bg: np.ndarray, mad_acc: np.ndarray, p: Params
               ) -> tuple[np.ndarray, np.ndarray]:
    """Seed and grow levels from a background and a MAD accumulator, in codes.

    sigma = 1.4826 * MAD, and k is carried in quarter-sigma units, so the margin
    is k * 1.4826 * mad / 4. In hardware 1.4826 is 1519 / 1024, right to a part
    in 10^5 and one multiplier wide; the accumulator's fractional bits are
    carried all the way through and only dropped at the end.

    Two levels, as in the paper: a pixel must clear the seed level to start a
    cluster and only the grow level to join one. Detection wants to be sure, and
    a shape wants to be complete - they are not the same question. The DUST
    truth cuts its boxes at 3 sigma, so that is what the grow level is set to,
    which makes the pixel sets directly comparable.
    """
    sig = (mad_acc.astype(np.int64) * 1519) >> 10        # sigma, bg_frac bits
    shift = 2 + p.bg_frac
    ms = np.maximum((p.k_seed_q * sig) >> shift, p.floor_code)
    mg = np.maximum((p.k_grow_q * sig) >> shift, p.floor_code)
    return (bg + ms).astype(np.int32), (bg + mg).astype(np.int32)


def lin_of_bg_acc(acc: int, frac_bits: int, interp: bool) -> int:
    """Linear light for a code-domain background accumulator.

    Integer part through the table; with `interp` the fractional bits pick a
    point on the chord to the next entry. The chord slope is the table's local
    difference, at most 79 counts at the top of the range, so in hardware this
    is a 7 x 6 bit product and a shift - the model is that same arithmetic.
    """
    b = acc >> frac_bits
    if b >= 255:
        return int(LUT[255])
    lo = int(LUT[b])
    if not interp:
        return lo
    f = acc & ((1 << frac_bits) - 1)
    return lo + (((int(LUT[b + 1]) - lo) * f) >> frac_bits)


# ---------------------------------------------------------------------------
# Stage 4/5: seed, grow, centre of gravity
# ---------------------------------------------------------------------------

def _dilate8(m: np.ndarray) -> np.ndarray:
    """One round of 8-connected dilation of a boolean window."""
    o = m.copy()
    o[:-1, :] |= m[1:, :]
    o[1:, :] |= m[:-1, :]
    o[:, :-1] |= m[:, 1:]
    o[:, 1:] |= m[:, :-1]
    o[:-1, :-1] |= m[1:, 1:]
    o[:-1, 1:] |= m[1:, :-1]
    o[1:, :-1] |= m[:-1, 1:]
    o[1:, 1:] |= m[:-1, :-1]
    return o


def grow_region(mask: np.ndarray) -> np.ndarray:
    """8-connected component of `mask` containing its centre pixel.

    HALF rounds of dilation, each one intersected with the mask. Every pixel of
    a WIN x WIN window is within HALF steps of the centre under 8-connectivity,
    so this is not an approximation to region growing - it is the same set the
    paper's stack-based walk would return, restricted to the RoI, and it costs a
    fixed HALF levels of AND-OR logic instead of a variable number of cycles.
    """
    reg = np.zeros_like(mask)
    reg[HALF, HALF] = True
    for _ in range(HALF):
        reg |= _dilate8(reg) & mask
    return reg


@dataclass
class Star:
    x_fix: int          # binned-pixel x, FRAC fractional bits (unsigned 8.8)
    y_fix: int
    sum_i: int          # background-subtracted linear intensity of the region
    npx: int            # pixels in the region
    peak: int           # brightest linear value in the region
    seed_x: int         # integer position of the seed pixel
    seed_y: int

    @property
    def x(self) -> float:
        return self.x_fix / (1 << FRAC)

    @property
    def y(self) -> float:
        return self.y_fix / (1 << FRAC)

    @property
    def display(self) -> tuple[float, float]:
        """Binned coordinates -> display pixels: display = dust * 4 + 1.5."""
        return (self.x * BIN_N + (BIN_N - 1) / 2.0,
                self.y * BIN_N + (BIN_N - 1) / 2.0)


@dataclass
class FrameResult:
    stars: list[Star] = field(default_factory=list)
    overflow: bool = False
    bg_code: int = 0
    mad_code: int = 0
    bg_lin: int = 0


def _seed_mask(lin: np.ndarray, code: np.ndarray, thr_seed: np.ndarray,
               p: Params) -> np.ndarray:
    """Where a cluster may start: a strict local maximum over the RoI, above the
    seed threshold, inside the field of view.

    The tie-break is the same one the camera-side detector uses: strictly
    greater than every neighbour that precedes the centre in raster order, and
    greater or equal to every one that follows. A plain strict maximum drops
    saturated stars, whose cores are flat; a plain >= reports a flat core as
    several stars.
    """
    from numpy.lib.stride_tricks import sliding_window_view

    h, w = lin.shape
    v = sliding_window_view(lin, (WIN, WIN)).reshape(
        h - WIN + 1, w - WIN + 1, WIN * WIN)
    mid = WIN * WIN // 2
    centre = v[:, :, mid]

    before = (centre[:, :, None] > v[:, :, :mid]).all(axis=2)
    after = (centre[:, :, None] >= v[:, :, mid + 1:]).all(axis=2)

    ok = np.zeros((h, w), dtype=bool)
    ok[HALF:h - HALF, HALF:w - HALF] = before & after
    ok &= code > thr_seed

    if p.fov_r > 0:
        yy, xx = np.mgrid[0:h, 0:w]
        ok &= ((xx - p.fov_cx) ** 2 + (yy - p.fov_cy) ** 2) <= p.fov_r ** 2

    return ok


def _at_window(img: np.ndarray, dy: int, dx: int) -> np.ndarray:
    """Re-index a per-pixel tracker output by window centre.

    A window centred on (cy, cx) is complete only once the pixel at
    (cy + HALF, cx + HALF) has been consumed, so that is the moment whose
    tracker state the hardware reads. The background is read at the centre's own
    column, because there is one estimate per column and the centre's is the
    right one; the MAD is global, so it is simply the value in force at that
    moment. Rows past the bottom edge clamp, which only affects centres that the
    seed mask has already excluded.
    """
    h, w = img.shape
    out = np.zeros_like(img)
    ys = np.clip(np.arange(h) + dy, 0, h - 1)
    xs = np.clip(np.arange(w) + dx, 0, w - 1)
    out[:, :] = img[np.ix_(ys, xs)]
    return out


def detect(code: np.ndarray, p: Params = DEFAULT,
           st: TrackerState | None = None) -> FrameResult:
    """Run one frame of 8-bit codes through the pipeline.

    The frame can be any size: the bench's binned 256x256 DUST grid, or the
    camera's 640x480 luminance with `fov_r = 0`. Everything that follows takes
    its geometry from the array.
    """
    if st is None:
        st = TrackerState()

    lin = LUT[code]
    bg_post, mad_post, lin_post, acc_post = run_trackers(code, lin, p, st)

    # Tracker state as of the moment each window closes.
    bg_at = _at_window(bg_post, HALF, 0)
    acc_at = _at_window(acc_post, HALF, 0)
    mad_at = _at_window(mad_post, HALF, 0 if p.mad_col else HALF)
    bglin_at = _at_window(lin_post, HALF, HALF)

    thr_seed, thr_grow = thresholds(bg_at, mad_at, p)
    seeds = _seed_mask(lin, code, thr_seed, p)

    res = FrameResult(bg_code=int(np.median(bg_post)),
                      mad_code=st.mad,
                      bg_lin=st.bg_lin >> p.bg_lin_frac)

    gy, gx = np.mgrid[0:WIN, 0:WIN]
    ys, xs = np.nonzero(seeds)

    for cy, cx in zip(ys.tolist(), xs.tolist()):
        if len(res.stars) >= p.n_star_max:
            res.overflow = True
            break

        y0, x0 = cy - HALF, cx - HALF
        wc = code[y0:y0 + WIN, x0:x0 + WIN]
        wl = lin[y0:y0 + WIN, x0:x0 + WIN]

        region = grow_region(wc > int(thr_grow[cy, cx]))
        npx = int(region.sum())
        if npx < p.min_npx:
            continue

        weight_mask = region if p.cg_half <= 0 else (
            (np.abs(gx - HALF) <= p.cg_half) & (np.abs(gy - HALF) <= p.cg_half))

        if p.cg_bg == 0:
            bl = int(bglin_at[cy, cx])
        else:
            bl = lin_of_bg_acc(int(acc_at[cy, cx]), p.bg_frac, p.cg_bg == 2)
        q = np.where(weight_mask, np.maximum(wl - bl, 0), 0).astype(np.int64)

        sum_i = int(q.sum())
        if sum_i < p.min_sum:
            continue

        sum_x = int((q * gx).sum())
        sum_y = int((q * gy).sum())

        # One extra fractional bit, then round to FRAC. Truncating alone would
        # bias every centroid by half an LSB toward the window's top left.
        qx = ((sum_x << (FRAC + 1)) // sum_i + 1) >> 1
        qy = ((sum_y << (FRAC + 1)) // sum_i + 1) >> 1

        res.stars.append(Star(
            x_fix=(x0 << FRAC) + qx,
            y_fix=(y0 << FRAC) + qy,
            sum_i=sum_i,
            npx=npx,
            peak=int(wl[HALF, HALF]),
            seed_x=cx, seed_y=cy,
        ))

    return res


def detect_source(src: np.ndarray, p: Params = DEFAULT,
                  st: TrackerState | None = None) -> FrameResult:
    """Whole chain from a 1024x1024 display image."""
    return detect(bin_nxn(src).astype(np.int32), p, st)


# ---------------------------------------------------------------------------
# Helpers shared by the bench scripts
# ---------------------------------------------------------------------------

def load_png(path) -> np.ndarray:
    from PIL import Image
    with Image.open(path) as im:
        return np.asarray(im.convert("L"), dtype=np.int32)


def warm_detect(code: np.ndarray, p: Params = DEFAULT, passes: int = 4) -> FrameResult:
    """Detect with the trackers settled, which is what a replayed frame sees.

    The hardware carries its background registers across frame boundaries and
    never resets them between frames, so the steady state is what it spends
    almost all of its time in; a cold pass describes only the first frame after
    power-up.

    Four passes, because that is what it takes. A column near the rim of the
    illuminated disc has only a few dozen rows inside the field of view, and the
    follower only steps on those, so it reaches a real sky level several frames
    after a column through the middle does. Measured over frames from every
    session, completeness climbs from 62% at two passes to 70% at four and stops
    there. On the board that settling is four frames at 24 a second - a sixth of
    a second after reset, and then it stays settled.
    """
    st = TrackerState()
    res = None
    for _ in range(passes):
        res = detect(code, p, st)
    return res
