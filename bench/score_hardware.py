"""Score what the board reported against the dataset's truth.

    uv run bench/score_hardware.py build/hw_stars.csv build/stream/truth.csv

This closes the gap the accuracy review could not: every figure in
docs/centroiding.md is the software model's, checked against the RTL on two
frames in simulation. These are the hardware's own centroids, over as many
frames as were streamed to it, scored the same way `evaluate.py` scores the
model - same match radius, same target column - so the two numbers mean the
same thing and can be put side by side.

The board reports 8.8 fixed point in binned pixels; the truth is in display
pixels, and display = binned * 4 + 1.5.
"""
from __future__ import annotations

import argparse
import csv
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from starfront_model import BIN_N  # noqa: E402

MATCH_RADIUS = 6.0        # display pixels, the same as evaluate.py


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("hw", type=Path, help="what feed_video.tcl wrote")
    ap.add_argument("truth", type=Path, help="truth.csv from export_stream.py")
    ap.add_argument("--min-peak", type=float, default=0.0,
                    help="only score truth stars at least this bright, in DN")
    a = ap.parse_args()

    hw = defaultdict(list)
    with open(a.hw, newline="") as fh:
        for r in csv.DictReader(fh):
            # The board may be replaying the frame at a scroll offset. That
            # offset is in whole display pixels and shifts the image the other
            # way, so adding it back puts the centroid where the stored frame
            # says it is. y scrolls at a quarter of x, arithmetic shift.
            sx = int(r.get("scroll") or 0)
            sy = sx >> 2
            hw[r["frame"]].append((
                int(r["x_fix"]) / 256.0 * BIN_N + (BIN_N - 1) / 2.0 + sx,
                int(r["y_fix"]) / 256.0 * BIN_N + (BIN_N - 1) / 2.0 + sy,
                int(r["sum_i"]), int(r["npx"]),
            ))

    truth = defaultdict(list)
    with open(a.truth, newline="") as fh:
        for r in csv.DictReader(fh):
            if float(r["peak_dn"]) < a.min_peak:
                continue
            truth[r["frame"]].append((float(r["display_blob_x"]),
                                      float(r["display_blob_y"]),
                                      float(r["peak_dn"])))

    errs, peaks = [], []
    n_truth = n_hit = n_det = n_false = frames = 0

    for frame, rows in sorted(truth.items()):
        det = np.array([[d[0], d[1]] for d in hw.get(frame, [])])
        used = np.zeros(len(det), dtype=bool)
        for tx, ty, pk in rows:
            if len(det) == 0:
                continue
            d = np.hypot(det[:, 0] - tx, det[:, 1] - ty)
            d[used] = np.inf
            j = int(np.argmin(d))
            if d[j] > MATCH_RADIUS:
                continue
            used[j] = True
            n_hit += 1
            errs.append(d[j])
            peaks.append(pk)
        n_truth += len(rows)
        n_det += len(det)
        n_false += int((~used).sum())
        frames += 1

    if not errs:
        print("nothing matched - is the hardware CSV from these frames?",
              file=sys.stderr)
        return 1

    e = np.array(errs)
    p = np.array(peaks)

    print()
    print("=" * 70)
    print(f"frames            {frames}")
    print(f"truth stars       {n_truth}")
    print(f"board detections  {n_det}")
    print(f"matched           {n_hit}  ({100.0 * n_hit / n_truth:.1f}% of truth)")
    print(f"unmatched         {n_false}  ({n_false / frames:.1f} per frame)")
    print()
    print("centroid error measured ON THE BOARD, display pixels, "
          "vs display_blob_*")
    print(f"  n {e.size:>6}   mean {e.mean():.4f}   median {np.median(e):.4f}   "
          f"p95 {np.percentile(e, 95):.4f}   max {e.max():.4f}")
    bright = p >= 100
    if bright.any():
        print(f"  peak_dn >= 100: n {int(bright.sum()):>5}   "
              f"median {np.median(e[bright]):.4f}")
    print()
    print("compare with the model's figures in docs/centroiding.md - they are")
    print("scored the same way, so a difference is a difference in the hardware.")
    print("=" * 70)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
