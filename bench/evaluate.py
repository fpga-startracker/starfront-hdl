"""Score the centroiding model against the DUST display set.

    uv run bench/evaluate.py --limit 100
    uv run bench/evaluate.py --stride 10 --out build/eval.csv
    uv run bench/evaluate.py --cg-half 0        # blob centroid instead of 7x7

The set ships two ground truths per star and they answer different questions:

  display_x, display_y            centre of mass over a fixed 7x7 window with the
                                  frame background subtracted. No threshold is
                                  involved, so this measures the centroider on
                                  its own.
  display_blob_x, display_blob_y  centre of mass over the pixels of an
                                  8-connected blob cut at the star's own local
                                  median + 3 MAD-sigma. This measures the
                                  centroider *and* the threshold, and any
                                  detector whose threshold differs from that one
                                  will differ here no matter how exact its
                                  arithmetic is.

Both are reported. Quoting one without saying which is meaningless - they differ
from each other by about 0.1 px in x because of the sensor's smear tail.

Read DATA_DESCRIPTION.md in the set first: 223 of the 1378 frames have no truth
at all, some frames contain the Earth's limb, and the truth itself is only good
to p95 ~0.095 display px through this display path.
"""
from __future__ import annotations

import argparse
import csv
import sys
from dataclasses import replace
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from starfront_model import (BIN_N, DEFAULT, HALF, WIN, Params, bin_nxn,  # noqa: E402
                             load_png, warm_detect)

DEFAULT_DATA = Path.home() / "Downloads/DUST_display_set(1)/DUST_display_set"

# A detection is paired with a truth row if it lands within this many display
# pixels. One binned pixel is four display pixels, so this is loose enough to
# pair up a badly biased centroid and still far tighter than the spacing of any
# two catalogued stars in the set.
MATCH_RADIUS = 6.0

# Brightness bands for the completeness table, in sensor DN at the star's peak.
# The set's own advice is to filter on peak_dn: below about 40 DN a star is at
# the noise floor and no threshold detector will find it reliably.
BANDS = [(0, 50), (50, 80), (80, 150), (150, 400), (400, 10 ** 9)]


def read_truth(path: Path) -> list[dict]:
    """Truth rows worth scoring against, filtered as the dataset advises."""
    rows = []
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            if not r.get("display_blob_x"):
                continue           # star never cleared its own local threshold
            if r.get("box_truncated") == "1":
                continue           # blob hit the reach limit, may be incomplete
            try:
                if float(r["box_fill"]) < 0.3:
                    continue       # limb streaks and other non-star blobs
            except (KeyError, ValueError):
                continue
            rows.append(r)
    return rows


def score_frame(code_bin: np.ndarray, truth: list[dict], p: Params):
    res = warm_detect(code_bin, p)
    det = (np.array([s.display for s in res.stars], dtype=np.float64)
           if res.stars else np.zeros((0, 2)))

    used = np.zeros(len(det), dtype=bool)
    recs = []

    for r in truth:
        tx, ty = float(r["display_blob_x"]), float(r["display_blob_y"])
        if len(det) == 0:
            continue
        d = np.hypot(det[:, 0] - tx, det[:, 1] - ty)
        d[used] = np.inf
        j = int(np.argmin(d))
        if d[j] > MATCH_RADIUS:
            continue
        used[j] = True
        recs.append((
            float(r["peak_dn"]),
            d[j],
            float(np.hypot(det[j, 0] - float(r["display_x"]),
                           det[j, 1] - float(r["display_y"]))),
            det[j, 0] - tx, det[j, 1] - ty,
        ))

    return {
        "n_truth": len(truth),
        "n_det": len(det),
        "n_hit": len(recs),
        "n_false": int((~used).sum()),
        "overflow": res.overflow,
        "recs": recs,
        "band_truth": [sum(1 for r in truth if lo <= float(r["peak_dn"]) < hi)
                       for lo, hi in BANDS],
    }


def stats(a: np.ndarray) -> str:
    if a.size == 0:
        return "no matches"
    return (f"n {a.size:>6}   mean {a.mean():.4f}   median {np.median(a):.4f}   "
            f"p95 {np.percentile(a, 95):.4f}   p99 {np.percentile(a, 99):.4f}   "
            f"max {a.max():.4f}")


def centroider_only(names, img_dir: Path, truth_dir: Path, half: int) -> int:
    """Centre of gravity alone, on the windows the truth used.

    Every integer width in the pipeline is exercised - the 12-bit linearising
    table, the background subtraction, the accumulators, the rounded fixed-point
    divide - but the window is placed where `export_display.py` placed it, so
    the only thing being measured is the arithmetic. Anything above a few
    hundredths of a pixel here is a bug, not a design choice.
    """
    from starfront_model import LUT

    gy, gx = np.mgrid[0:2 * half + 1, 0:2 * half + 1]
    errs = []

    for name in names:
        truth = read_truth(truth_dir / f"{name}.csv")
        if not truth:
            continue
        code = bin_nxn(load_png(img_dir / f"{name}.png")).astype(np.int32)
        lin = LUT[code].astype(np.int64)
        bg = int(np.median(lin))          # the truth's own frame-median convention

        for r in truth:
            xi, yi = round(float(r["corr_x"])), round(float(r["corr_y"]))
            if not (half <= xi < 256 - half and half <= yi < 256 - half):
                continue
            w = lin[yi - half:yi + half + 1, xi - half:xi + half + 1]
            q = np.maximum(w - bg, 0)
            si = int(q.sum())
            if si <= 0:
                continue
            qx = ((int((q * gx).sum()) << 9) // si + 1) >> 1
            qy = ((int((q * gy).sum()) << 9) // si + 1) >> 1
            cx = (((xi - half) << 8) + qx) / 256.0 * BIN_N + (BIN_N - 1) / 2.0
            cy = (((yi - half) << 8) + qy) / 256.0 * BIN_N + (BIN_N - 1) / 2.0
            errs.append(np.hypot(cx - float(r["display_x"]),
                                 cy - float(r["display_y"])))

    e = np.array(errs)
    print()
    print("=" * 78)
    print(f"centre of gravity alone, {2 * half + 1}x{2 * half + 1} window placed at the "
          f"truth's own position")
    print(f"  vs display_*    {stats(e)}")
    print(f"  one fixed-point LSB is {4.0 / 256:.5f} display px")
    print("=" * 78)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", type=Path, default=DEFAULT_DATA)
    ap.add_argument("--limit", type=int, default=0, help="frames to score, 0 = all")
    ap.add_argument("--stride", type=int, default=1,
                    help="take every Nth frame, to sample the whole set cheaply")
    ap.add_argument("--out", type=Path, default=None, help="per-frame CSV")
    ap.add_argument("--k-seed", type=int, default=None, help="seed level, quarter sigma")
    ap.add_argument("--k-grow", type=int, default=None, help="grow level, quarter sigma")
    ap.add_argument("--cg-half", type=int, default=None,
                    help="centroid window half-width; 0 = the grown blob")
    ap.add_argument("--min-npx", type=int, default=None)
    ap.add_argument("--min-sum", type=int, default=None)
    ap.add_argument("--fov-r", type=int, default=None)
    ap.add_argument("--cg-bg", type=int, default=None,
                    help="background under the centroid weights: 0 global "
                         "linear follower, 1 per-column median linearised, "
                         "2 the same interpolated")
    ap.add_argument("--mad-col", type=int, default=None,
                    help="deviation follower: 0 global (default), 1 per column")
    ap.add_argument("--centroider", action="store_true",
                    help="score the centre-of-gravity arithmetic alone: place a "
                         "fixed window where the truth places its own (the "
                         "rounded astrometric position) and compare with "
                         "display_x / display_y. This is the paper's section "
                         "5.3.1 comparison - hardware against software on "
                         "identical clusters - and it says nothing about "
                         "detection, because detection has been skipped.")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    p = DEFAULT
    for name, val in (("k_seed_q", a.k_seed), ("k_grow_q", a.k_grow),
                      ("cg_half", a.cg_half), ("min_npx", a.min_npx),
                      ("min_sum", a.min_sum), ("fov_r", a.fov_r),
                      ("cg_bg", a.cg_bg), ("mad_col", a.mad_col)):
        if val is not None:
            p = replace(p, **{name: val})

    img_dir, truth_dir = a.data / "images", a.data / "truth"
    if not img_dir.is_dir():
        print(f"no images under {img_dir}", file=sys.stderr)
        return 2

    names = sorted(q.stem for q in img_dir.glob("*.png"))[::a.stride]
    if a.limit:
        names = names[:a.limit]

    if a.centroider:
        return centroider_only(names, img_dir, truth_dir,
                               p.cg_half if p.cg_half > 0 else 3)

    recs: list[tuple] = []
    band_truth = [0] * len(BANDS)
    tot_truth = tot_hit = tot_det = tot_false = frames = overflows = 0
    rows_out = []

    for i, name in enumerate(names):
        truth = read_truth(truth_dir / f"{name}.csv")
        if not truth:
            continue
        code = bin_nxn(load_png(img_dir / f"{name}.png")).astype(np.int32)
        s = score_frame(code, truth, p)

        recs += s["recs"]
        band_truth = [x + y for x, y in zip(band_truth, s["band_truth"])]
        tot_truth += s["n_truth"]
        tot_hit += s["n_hit"]
        tot_det += s["n_det"]
        tot_false += s["n_false"]
        overflows += int(s["overflow"])
        frames += 1

        rows_out.append({
            "name": name, "n_truth": s["n_truth"], "n_det": s["n_det"],
            "n_hit": s["n_hit"], "n_false": s["n_false"],
            "overflow": int(s["overflow"]),
            "mean_err_blob": (float(np.mean([r[1] for r in s["recs"]]))
                              if s["recs"] else ""),
            "mean_err_win": (float(np.mean([r[2] for r in s["recs"]]))
                             if s["recs"] else ""),
        })

        if not a.quiet and (i % 25 == 0 or i == len(names) - 1):
            print(f"  [{i + 1}/{len(names)}] {name[:52]:<52} "
                  f"{s['n_hit']}/{s['n_truth']} matched, {s['n_false']} extra",
                  flush=True)

    if not recs:
        print("nothing matched", file=sys.stderr)
        return 1

    arr = np.array(recs)
    peak, e_blob, e_win, dx, dy = (arr[:, 0], arr[:, 1], arr[:, 2],
                                   arr[:, 3], arr[:, 4])

    print()
    print("=" * 78)
    print(f"frames scored           {frames} of {len(names)} "
          f"({len(names) - frames} had no usable truth)")
    print(f"truth stars             {tot_truth}")
    print(f"detections              {tot_det}"
          + (f"   ({overflows} frames hit the {p.n_star_max}-star list limit)"
             if overflows else ""))
    print(f"matched                 {tot_hit}  "
          f"({100.0 * tot_hit / tot_truth:.1f}% of truth)")
    print(f"unmatched detections    {tot_false}  "
          f"({100.0 * tot_false / tot_det:.1f}% of detections, "
          f"{tot_false / frames:.1f} per frame)")

    print()
    print("completeness by star brightness")
    print(f"  {'peak DN':>14}   {'truth':>7} {'found':>7}   {'%':>6}   "
          f"{'median err (7x7)':>17}")
    for (lo, hi), nt in zip(BANDS, band_truth):
        m = (peak >= lo) & (peak < hi)
        hi_s = "inf" if hi > 10 ** 8 else str(hi)
        med = f"{np.median(e_win[m]):.4f}" if m.any() else "-"
        print(f"  {lo:>6} - {hi_s:>5}   {nt:>7} {int(m.sum()):>7}   "
              f"{100.0 * m.sum() / nt if nt else 0:>5.1f}%   {med:>17}")

    print()
    print("centroid error, display pixels (4 display px = 1 binned px = 1 DUST px)")
    print(f"  vs display_*      (7x7, threshold free)  {stats(e_win)}")
    print(f"  vs display_blob_* (blob, 3 sigma cut)    {stats(e_blob)}")
    bright = peak >= 100
    if bright.any():
        print(f"  vs display_*, peak_dn >= 100             {stats(e_win[bright])}")
    print(f"  systematic offset vs display_blob_*      "
          f"dx {dx.mean():+.4f}   dy {dy.mean():+.4f}")

    print()
    print(f"parameters   bin {BIN_N}   RoI {WIN}x{WIN}   "
          f"cg {'blob' if p.cg_half <= 0 else f'{2 * p.cg_half + 1}x{2 * p.cg_half + 1}'}"
          f"   k_seed {p.k_seed_q / 4:.2f}s   k_grow {p.k_grow_q / 4:.2f}s")
    print(f"             min_npx {p.min_npx}   min_sum {p.min_sum}   "
          f"fov_r {p.fov_r}   frac bits {8}   grow rounds {HALF}   "
          f"cg_bg {('global', 'column', 'column+interp')[p.cg_bg]}   "
          f"mad {'column' if p.mad_col else 'global'}")
    print("=" * 78)

    if a.out:
        a.out.parent.mkdir(parents=True, exist_ok=True)
        with open(a.out, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows_out[0].keys()))
            w.writeheader()
            w.writerows(rows_out)
        print(f"per-frame results -> {a.out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
