"""Export DUST frames as a directory of .mem files for streaming to the board.

    uv run bench/export_stream.py --count 50
    uv run bench/export_stream.py --stride 20 --out build/stream

Each file is one frame: 16384 lines of eight hex digits, four pixels a word,
little-endian - the same packing bench/prepare_frames.py writes and the width
the host writes over AXI. scripts/feed_video.tcl plays them in name order.

Alongside them goes truth.csv, the dataset's own answer for the same frames, so
that what the board reports back can be scored against it without going near the
dataset again:

    ./scripts/stream_video.sh build/stream 50 build/hw_stars.csv
    uv run bench/score_hardware.py build/hw_stars.csv build/stream/truth.csv

That is the whole point of the exercise. Until there was a way to read the star
list back, every accuracy figure in this project was the software model's,
checked against the RTL on two frames in simulation.
"""
from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from starfront_model import BIN_N, bin_nxn, load_png  # noqa: E402

DEFAULT_DATA = Path.home() / "Downloads/DUST_display_set(1)/DUST_display_set"
DEFAULT_OUT = Path(__file__).resolve().parent.parent / "build" / "stream"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", type=Path, default=DEFAULT_DATA)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--count", type=int, default=20, help="frames to export")
    ap.add_argument("--stride", type=int, default=1,
                    help="take every Nth frame, to sample the whole set")
    ap.add_argument("--skip-empty", action="store_true",
                    help="skip the 223 frames the dataset has no truth for")
    a = ap.parse_args()

    img_dir, truth_dir = a.data / "images", a.data / "truth"
    if not img_dir.is_dir():
        print(f"no images under {img_dir}", file=sys.stderr)
        return 2

    names = sorted(p.stem for p in img_dir.glob("*.png"))[::a.stride]
    a.out.mkdir(parents=True, exist_ok=True)

    truth_rows = []
    written = 0

    for name in names:
        if written >= a.count:
            break

        rows = []
        tf = truth_dir / f"{name}.csv"
        if tf.is_file():
            with open(tf, newline="") as fh:
                rows = [r for r in csv.DictReader(fh)
                        if r.get("display_blob_x")
                        and r.get("box_truncated") != "1"
                        and float(r.get("box_fill") or 0) >= 0.3]
        if a.skip_empty and not rows:
            continue

        code = bin_nxn(load_png(img_dir / f"{name}.png")).astype(np.uint32)
        flat = code.reshape(-1)
        packed = (flat[0::4] | (flat[1::4] << 8) |
                  (flat[2::4] << 16) | (flat[3::4] << 24))

        # Numbered, not named: the Tcl plays them in name order and the DUST
        # names do not sort into time order on their own.
        stem = f"{written:04d}_{name}"
        (a.out / f"{stem}.mem").write_text(
            "\n".join(f"{int(v):08x}" for v in packed) + "\n")

        for r in rows:
            truth_rows.append({
                "frame": stem,
                "display_blob_x": r["display_blob_x"],
                "display_blob_y": r["display_blob_y"],
                "peak_dn": r["peak_dn"],
            })

        print(f"{stem}   {len(rows)} truth stars")
        written += 1

    with open(a.out / "truth.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["frame", "display_blob_x",
                                           "display_blob_y", "peak_dn"])
        w.writeheader()
        w.writerows(truth_rows)

    size_mb = written * 16384 * 9 / 1e6
    print(f"\n{written} frames ({size_mb:.1f} MB of text) -> {a.out}")
    print(f"{len(truth_rows)} truth stars -> {a.out / 'truth.csv'}")
    print(f"\nstream them with:  ./scripts/stream_video.sh {a.out} {written} "
          f"build/hw_stars.csv")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
