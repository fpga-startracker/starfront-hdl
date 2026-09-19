#!/usr/bin/env bash
# Stream frames into the board over JTAG and read the star list back.
#
#   ./scripts/stream_video.sh build/stream            play them all
#   ./scripts/stream_video.sh build/stream 50         play the first 50
#   ./scripts/stream_video.sh build/stream 50 out.csv and save what came back
#
# The bench bitstream has to be loaded first:
#   ./scripts/program.sh bench
#
# Expect a few frames a second. This is JTAG, not a video link - the AX7010 has
# no route from PL to bulk storage at all (the 32 MB QSPI flash is on PS MIO and
# the Zynq Quad-SPI controller is MIO-only), so a megabyte of image has to be
# shifted down the debug cable a kilobyte at a time. The detector still runs at
# 24 fps on whatever is loaded; what arrives slowly is new content.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIVADO="${VIVADO:-/tools/Xilinx/2025.2/Vivado/bin/vivado}"
DIR="${1:-}"
COUNT="${2:-0}"
OUT="${3:-}"

if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
    echo "usage: $0 <frame-dir> [count] [out.csv]" >&2
    echo "  make a frame directory with: uv run bench/export_stream.py" >&2
    exit 1
fi

# Same guard as build.sh and program.sh: two Vivado sessions cannot share the
# JTAG cable, and the failure looks like a dead board rather than a busy one.
if pgrep -f "Vivado/bin/vivado" >/dev/null 2>&1 && \
   ! pgrep -f "Vivado/bin/vivado.*-mode batch" >/dev/null 2>&1; then
    if [ "${ALLOW_GUI:-0}" != "1" ]; then
        echo "REFUSING TO STREAM - another Vivado session is running and will be" >&2
        echo "holding the JTAG cable. Close it, or set ALLOW_GUI=1." >&2
        exit 1
    fi
fi

LOG="$REPO_DIR/build/stream.log"
mkdir -p "$REPO_DIR/build"

"$VIVADO" -mode batch -nojournal -log "$LOG" \
    -source "$REPO_DIR/scripts/feed_video.tcl" \
    -tclargs "$DIR" "$COUNT" "$OUT" || true

if ! grep -q "INFO: STREAM COMPLETE" "$LOG"; then
    echo "STREAM FAILED - see $LOG" >&2
    grep -m 5 -E "^ERROR" "$LOG" >&2 || true
    exit 1
fi
grep -E "^INFO: using|frames in|star lists|stars " "$LOG" || true
