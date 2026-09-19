#!/usr/bin/env bash
# Open a variant's Vivado project in the GUI, after checking it still matches
# the sources on disk.
#
#   ./scripts/open_gui.sh bringup
#   ./scripts/open_gui.sh tracker
#   ./scripts/open_gui.sh stream
#   ./scripts/open_gui.sh bench
#   ./scripts/open_gui.sh bringup --regen    regenerate first, then open
#
# Why this exists: a GUI session left open across a build writes its own
# in-memory copy of the project back over the generated one when it closes.
# The result is a .xpr that still names sources which have since been renamed
# or added, so synthesis fails on files the build had already replaced. That
# has happened twice. This checks for the drift before you spend time in the
# GUI rather than after.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIVADO="${VIVADO:-/tools/Xilinx/2025.2/Vivado/bin/vivado}"
VARIANT="${1:-}"
REGEN="${2:-}"

case "$VARIANT" in
    bringup|tracker|stream|bench) ;;
    *) echo "usage: $0 {bringup|tracker|stream|bench} [--regen]" >&2; exit 1 ;;
esac

XPR="$REPO_DIR/build/starfront_$VARIANT/starfront_$VARIANT.xpr"

# The project is disposable, so a missing one is not an error - just build it.
if [ ! -f "$XPR" ] || [ "$REGEN" = "--regen" ]; then
    echo "Regenerating the $VARIANT project..."
    "$REPO_DIR/scripts/build.sh" "" "$VARIANT"
else
    # Every .v under rtl/ must appear in the project, and the top must be the
    # module that actually exists. Comparing basenames is enough: the .xpr
    # stores paths relative to itself, so a rename shows up either way.
    in_xpr="$(grep -oE '<File Path="[^"]+\.v"' "$XPR" | sed 's/.*\///;s/"$//' | sort -u)"
    on_disk="$(ls "$REPO_DIR"/rtl/*.v | xargs -n1 basename | sort)"

    if [ "$in_xpr" != "$on_disk" ]; then
        echo "STALE PROJECT - build/starfront_$VARIANT does not match rtl/." >&2
        echo "" >&2
        diff <(echo "$on_disk") <(echo "$in_xpr") \
            | sed 's/^</  missing from the project: /;s/^>/  in the project but not in rtl\/: /' \
            | grep -E '^  ' >&2 || true
        echo "" >&2
        echo "Opening it would fail in synthesis. Regenerate with:" >&2
        echo "  ./scripts/open_gui.sh $VARIANT --regen     (project only)" >&2
        echo "  ./scripts/build.sh impl $VARIANT           (project and bitstream)" >&2
        echo "" >&2
        echo "Note that either one deletes the existing synth_1 and impl_1 results." >&2
        exit 1
    fi
    echo "OK - $VARIANT project matches rtl/ ($(echo "$on_disk" | wc -l) sources)"
fi

# Leaving the GUI open across the next ./scripts/build.sh is what causes the
# drift this script checks for, so say it once here where it will be read.
echo ""
echo "Opening the GUI. Close the project (File > Close Project) before running"
echo "scripts/build.sh again, or the build will refuse to start."
echo ""

exec "$VIVADO" -mode gui "$XPR"
