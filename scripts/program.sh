#!/usr/bin/env bash
# Load a bitstream onto the AX7010 over its on-board USB JTAG.
#
#   ./scripts/program.sh              the tracker build
#   ./scripts/program.sh bringup      camera bring-up only
#   ./scripts/program.sh tracker
#   ./scripts/program.sh stream       PS AXI-Stream build, no camera
#   ./scripts/program.sh bench        centroiding bench, no camera
#
# Works from any directory: the repository is located from this script's own
# path rather than from the working directory, which a `vivado` shell wrapper
# may well have changed underneath you.
#
# Set the J13 jumper to the JTAG position (the two right-hand pins) first, so
# the PS does not boot from SD or QSPI and reconfigure the PL underneath you.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIVADO="${VIVADO:-/tools/Xilinx/2025.2/Vivado/bin/vivado}"
VARIANT="${1:-tracker}"
BIT="$REPO_DIR/build/starfront_${VARIANT}.bit"

if [ ! -f "$BIT" ]; then
    echo "No bitstream for variant '$VARIANT' at $BIT" >&2
    echo "Build it first:  ./scripts/build.sh impl $VARIANT" >&2
    exit 1
fi

# An open Hardware Manager holds the JTAG target, and a second session cannot
# have it at the same time.
if pgrep -f "Vivado/bin/vivado" >/dev/null 2>&1 && \
   ! pgrep -f "Vivado/bin/vivado.*-mode batch" >/dev/null 2>&1; then
    if [ "${ALLOW_GUI:-0}" != "1" ]; then
        echo "REFUSING TO PROGRAM - another Vivado session is running." >&2
        echo "" >&2
        echo "If its Hardware Manager has the board open, it owns the JTAG cable" >&2
        echo "and this cannot. Close the target there, or program from the GUI." >&2
        echo "" >&2
        echo "Set ALLOW_GUI=1 to override." >&2
        exit 1
    fi
    echo "WARNING: another Vivado session is running; ALLOW_GUI=1 was set." >&2
fi

cd "$REPO_DIR/build"
exec "$VIVADO" -mode batch -nojournal \
    -log "$REPO_DIR/build/program_${VARIANT}.log" \
    -source "$REPO_DIR/scripts/program.tcl" \
    -tclargs "$VARIANT"
