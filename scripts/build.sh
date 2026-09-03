#!/usr/bin/env bash
# Build the bitstream from a clean checkout.
#
#   ./scripts/build.sh          create the project only
#   ./scripts/build.sh impl     create the project, synthesise, implement, write bitstream
#
# Set VIVADO to override the tool path.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIVADO="${VIVADO:-/tools/Xilinx/2025.2/Vivado/bin/vivado}"
BUILD_DIR="$REPO_DIR/build"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

exec "$VIVADO" -mode batch -nojournal \
    -log "$BUILD_DIR/vivado.log" \
    -source "$REPO_DIR/scripts/create_project.tcl" \
    -tclargs "${1:-}"
