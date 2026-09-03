#!/usr/bin/env bash
# Build a bitstream from a clean checkout.
#
#   ./scripts/build.sh                    create the tracker project only
#   ./scripts/build.sh impl               build the tracker variant
#   ./scripts/build.sh impl bringup       build the camera bring-up variant
#   ./scripts/build.sh impl tracker       explicit
#   ./scripts/build.sh impl all           build both, one after the other
#
# Variants:
#   bringup   camera bring-up only, milestones M0-M4
#   tracker   the above plus the streaming star detector, M5
#
# Set VIVADO to override the tool path.
#
# Vivado batch mode exits 0 even when a Tcl error aborts the script part way
# through, so success is decided by the marker create_project.tcl prints on its
# last line, not by the exit code.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIVADO="${VIVADO:-/tools/Xilinx/2025.2/Vivado/bin/vivado}"
BUILD_DIR="$REPO_DIR/build"
MODE="${1:-}"
VARIANT="${2:-tracker}"

build_one() {
    local variant="$1"
    local log="$BUILD_DIR/vivado_${variant}.log"

    echo "=== $variant ==="
    "$VIVADO" -mode batch -nojournal \
        -log "$log" \
        -source "$REPO_DIR/scripts/create_project.tcl" \
        -tclargs "$MODE" "$variant" || true

    if ! grep -q "INFO: BUILD COMPLETE" "$log"; then
        echo "BUILD FAILED ($variant) - the Tcl script did not run to completion." >&2
        echo "First error in $log:" >&2
        grep -m 3 -E "^ERROR" "$log" >&2 || echo "  (no ERROR line; check the log)" >&2
        exit 1
    fi

    if [ "$MODE" = "impl" ]; then
        for f in "$BUILD_DIR/starfront_${variant}.bit" \
                 "$BUILD_DIR/starfront_${variant}.ltx"; do
            if [ ! -f "$f" ]; then
                echo "BUILD FAILED ($variant) - expected artefact missing: $f" >&2
                exit 1
            fi
        done
        echo "OK - $BUILD_DIR/starfront_${variant}.bit"
    else
        echo "OK - $variant project created, not built"
    fi
}

# create_project -force deletes and recreates build/<project>/ from scratch. If
# the Vivado GUI has that project open it keeps its own in-memory copy, then
# writes it back over the freshly generated one - which is how a project that
# built perfectly ended up missing six of its eighteen sources, and how a GUI
# left open across a build ends up reporting "Synthesis Failed: <top>.dcp does
# not exist" for files the build had already replaced.
if pgrep -f "Vivado/bin/vivado" >/dev/null 2>&1 && \
   ! pgrep -f "Vivado/bin/vivado.*-mode batch" >/dev/null 2>&1; then
    if [ "${ALLOW_GUI:-0}" != "1" ]; then
        echo "REFUSING TO BUILD - a Vivado session that is not this script is running." >&2
        echo "" >&2
        echo "This build regenerates build/<project>/ from scratch. Close the project" >&2
        echo "in the GUI first (File > Close Project), or quit Vivado, then run again." >&2
        echo "" >&2
        echo "Set ALLOW_GUI=1 to override if you are sure it has nothing open here." >&2
        exit 1
    fi
    echo "WARNING: another Vivado session is running; ALLOW_GUI=1 was set." >&2
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ "$VARIANT" = "all" ]; then
    build_one bringup
    build_one tracker
else
    build_one "$VARIANT"
fi
