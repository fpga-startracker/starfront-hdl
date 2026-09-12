"""Pack DUST frames into the memory file the bitstream loads.

    uv run bench/prepare_frames.py                       # the first frame
    uv run bench/prepare_frames.py --index 100 200       # pick them
    uv run bench/prepare_frames.py --name SET_1__2023... # by name
    uv run bench/prepare_frames.py --report              # what is in each frame

Writes build/frames.mem, which frame_source.v reads with $readmemh at
elaboration, so changing which image the board processes means a rebuild - about
two minutes - rather than a host transfer. That is a deliberate trade: a 1 MB
display image is 32 block RAMs on a 7z010 whichever way it arrives, and every
route that could push one in at runtime (JTAG-to-AXI, the Zynq PS) costs more of
the device than the detector does. The frame the board replays is for watching
the thing work; the accuracy numbers come from bench/evaluate.py over the whole
set, and sim/centroid ties the two together by proving the RTL and the model
agree bit for bit.

One frame by default. Vivado builds a second copy of a two-port ROM rather than
using the second port of one block RAM - it does that whatever inference
template you write, because a ROM has no write port to hang the second port on -
so a stored frame costs 32 of the part's 60 tiles and two will not fit.
`--frames 2` is there for a larger device, where the store cycles and the
markers visibly track between consecutive exposures.

The file holds 32-bit words, four pixels each, little-endian - the width the
host writes over AXI and therefore the width the store is.

Each stored frame is the binned 256x256 sensor grid, not the 1024x1024 display
image. That is not a downscale: the display image is a 4x block replication of
the sensor grid, so binning recovers it exactly, and frame_source replays each
stored pixel four times per axis to hand the detector back the full-resolution
image. A sixteenth of the memory, the same pixels.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from starfront_model import DEFAULT, bin_nxn, load_png, warm_detect  # noqa: E402

DEFAULT_DATA = Path.home() / "Downloads/DUST_display_set(1)/DUST_display_set"
DEFAULT_OUT = Path(__file__).resolve().parent.parent / "build" / "frames.mem"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", type=Path, default=DEFAULT_DATA)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--frames", type=int, default=1,
                    help="frames the bitstream holds; must match N_FRAMES")
    ap.add_argument("--index", type=int, nargs="*", default=None,
                    help="indices into the sorted image list")
    ap.add_argument("--name", type=str, nargs="*", default=None,
                    help="frame names, without the .png")
    ap.add_argument("--report", action="store_true",
                    help="also run the model on each frame and say what it found")
    a = ap.parse_args()

    img_dir = a.data / "images"
    if not img_dir.is_dir():
        print(f"no images under {img_dir}", file=sys.stderr)
        return 2

    names = sorted(p.stem for p in img_dir.glob("*.png"))
    if a.name:
        chosen = list(a.name)
    elif a.index:
        chosen = [names[i] for i in a.index]
    else:
        # Consecutive exposures by default, so the field shifts slightly between
        # them and the markers visibly track when the board cycles the store.
        chosen = names[:a.frames]

    if len(chosen) != a.frames:
        print(f"{len(chosen)} frames chosen but --frames says {a.frames}; the "
              f"bitstream will replay the wrong number", file=sys.stderr)
        return 2

    a.out.parent.mkdir(parents=True, exist_ok=True)
    words = []

    for name in chosen:
        code = bin_nxn(load_png(img_dir / f"{name}.png")).astype(np.int32)
        assert code.shape == (256, 256), code.shape
        words.append(code.reshape(-1))

        line = f"{name}"
        truth = a.data / "truth" / f"{name}.csv"
        if truth.is_file():
            with open(truth, newline="") as fh:
                rows = [r for r in csv.DictReader(fh) if r.get("display_blob_x")]
            line += f"   {len(rows)} truth stars"
        if a.report:
            res = warm_detect(code, DEFAULT)
            line += (f"   model finds {len(res.stars)}"
                     f"   bg {res.bg_code}  mad {res.mad_code / 64:.2f}")
        print(line)

    flat = np.concatenate(words).astype(np.uint32)
    # Four pixels per 32-bit word, little-endian, because that is the width the
    # host writes over AXI and therefore the width the store is. Pixel x sits in
    # bits 7:0 of its word, x+1 in 15:8, and so on.
    packed = (flat[0::4] | (flat[1::4] << 8) |
              (flat[2::4] << 16) | (flat[3::4] << 24))
    with open(a.out, "w") as fh:
        fh.write("\n".join(f"{int(v):08x}" for v in packed))
        fh.write("\n")

    # A sidecar naming what went in and hashing it. build.sh checks this before
    # a bench build, because the memory file lives in build/ where the tools
    # also work, and a frame store that silently holds something else produces a
    # picture that looks entirely plausible and is not the data anyone asked
    # for. This has already happened once.
    digest = hashlib.sha256(a.out.read_bytes()).hexdigest()
    a.out.with_suffix(".sha256").write_text(
        f"{digest}  {a.out.name}\n" + "".join(f"# {c}\n" for c in chosen))

    print(f"\n{len(chosen)} frame(s), {flat.size} pixels in {packed.size} words -> {a.out}")
    print(f"sha256 {digest[:16]}... -> {a.out.with_suffix('.sha256').name}")
    print("rebuild with ./scripts/build.sh impl bench to load it into the bitstream")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
