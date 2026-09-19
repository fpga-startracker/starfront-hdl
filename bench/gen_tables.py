"""Generate the two lookup tables the RTL needs, as Verilog.

    uv run bench/gen_tables.py

Writes rtl/pix_lut.v and rtl/char_font.v. Both are checked in - the build must
not depend on Python - but they are generated rather than typed so that the
transfer function in `starfront_model.build_lut` and the one in the bitstream
cannot drift apart. Re-run this after changing either and commit the result.

A `$readmemh` file would have been the obvious alternative and was rejected:
Vivado resolves those relative to a working directory that differs between
batch and GUI runs, and a table that silently reads as all zeroes is a very
expensive kind of bug. An initialised array in the source cannot go missing.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from starfront_model import LUT, PIX_BITS  # noqa: E402

RTL = Path(__file__).resolve().parent.parent / "rtl"

# 5x7 glyphs in an 8x8 cell, left aligned with a blank column each side and a
# blank row underneath, so text drawn edge to edge still has gaps in it. Only
# the characters the status panel uses are filled in; the rest render blank,
# which is a visible bug rather than a silent one.
GLYPHS = {
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
    "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
    "D": ["11100", "10010", "10001", "10001", "10001", "10010", "11100"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
    "G": ["01110", "10001", "10000", "10111", "10001", "10001", "01111"],
    "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    "I": ["01110", "00100", "00100", "00100", "00100", "00100", "01110"],
    "J": ["00111", "00010", "00010", "00010", "00010", "10010", "01100"],
    "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "Q": ["01110", "10001", "10001", "10001", "10101", "10010", "01101"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
    "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
    "W": ["10001", "10001", "10001", "10101", "10101", "11011", "10001"],
    "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
    "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
    "Z": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
    "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
    "=": ["00000", "11111", "00000", "00000", "11111", "00000", "00000"],
    ".": ["00000", "00000", "00000", "00000", "00000", "01100", "01100"],
    ":": ["00000", "01100", "01100", "00000", "01100", "01100", "00000"],
    "/": ["00001", "00010", "00010", "00100", "01000", "01000", "10000"],
    "+": ["00000", "00100", "00100", "11111", "00100", "00100", "00000"],
    "*": ["00000", "10101", "01110", "11111", "01110", "10101", "00000"],
    "<": ["00010", "00100", "01000", "10000", "01000", "00100", "00010"],
    ">": ["01000", "00100", "00010", "00001", "00010", "00100", "01000"],
    "[": ["01110", "01000", "01000", "01000", "01000", "01000", "01110"],
    "]": ["01110", "00010", "00010", "00010", "00010", "00010", "01110"],
    "%": ["11001", "11010", "00010", "00100", "01000", "01011", "10011"],
}

FIRST, LAST = 0x20, 0x5F      # space .. underscore, 64 glyphs


def glyph_bytes(ch: str) -> list[int]:
    rows = GLYPHS.get(ch)
    if rows is None:
        return [0] * 8
    # Left-aligned into an 8-bit row with one blank column at each side, and a
    # blank eighth row for the descender gap.
    return [int(r, 2) << 2 for r in rows] + [0]


def gen_pix_lut() -> str:
    lines = [
        "`timescale 1ns / 1ps",
        "",
        "//" + "=" * 74,
        "// Module: pix_lut",
        "// Description: 8-bit display code -> %d-bit linear light. GENERATED"
        % PIX_BITS,
        "//              by bench/gen_tables.py - edit that, not this.",
        "//",
        "//   The images this design consumes are sRGB encoded, so that a monitor",
        "//   showing them emits light proportional to the scene rather than to a",
        "//   gamma-warped version of it. A centroid is a first moment of light, so",
        "//   the pipeline has to undo the encoding before it weights anything. A",
        "//   camera pointed at the screen does this in the optics; when the image",
        "//   is fed to the FPGA digitally, this table stands in for the monitor.",
        "//",
        "//   Twelve bits out, not eight: the sky background sits near code 35,",
        "//   which is 1.7% of full scale. Rounded to eight bits the entire faint",
        "//   end of the scene would land inside four values.",
        "//",
        "//   The table is strictly increasing, which is what lets the detector",
        "//   keep its line buffers in linear values and still threshold in code",
        "//   space: it simply passes the threshold through the same table.",
        "//",
        "//   Inferred as distributed ROM - 256 x %d bits is %d LUTs, against the"
        % (PIX_BITS, PIX_BITS * 4),
        "//   several hundred a case statement would build.",
        "//" + "=" * 74,
        "",
        "module pix_lut (",
        "    input  wire [7:0]  code,",
        "    output wire [%d:0] lin" % (PIX_BITS - 1),
        ");",
        "",
        '    (* rom_style = "distributed" *) reg [%d:0] tbl [0:255];' % (PIX_BITS - 1),
        "",
        "    initial begin",
    ]
    for i in range(0, 256, 8):
        row = "".join(f" tbl[{i + k:3d}] = {PIX_BITS}'d{int(LUT[i + k]):4d};"
                      for k in range(8))
        lines.append("       " + row)
    lines += [
        "    end",
        "",
        "    assign lin = tbl[code];",
        "",
        "endmodule",
        "",
    ]
    return "\n".join(lines)


def gen_char_font() -> str:
    lines = [
        "`timescale 1ns / 1ps",
        "",
        "//" + "=" * 74,
        "// Module: char_font",
        "// Description: 8x8 glyph ROM, ASCII 0x20 to 0x5F. GENERATED by",
        "//              bench/gen_tables.py - edit that, not this.",
        "//",
        "//   hex_font covers the sixteen hex digits and is what the camera",
        "//   bring-up overlay uses. The centroid bench needs labels as well as",
        "//   numbers - a screen reading STARS 11 is worth more than one reading",
        "//   11 - so this carries the printable upper-case set.",
        "//",
        "//   Bit 7 of `bits` is the leftmost pixel. Glyphs are 5x7 inside the 8x8",
        "//   cell, so text drawn edge to edge still has space between characters.",
        "//   Characters with no glyph render blank, which is a visible mistake",
        "//   rather than a silent one.",
        "//" + "=" * 74,
        "",
        "module char_font (",
        "    input  wire [7:0] ch,       // ASCII; anything outside 0x20-0x5F is blank",
        "    input  wire [2:0] row,      // 0 = top row of the glyph",
        "    output wire [7:0] bits",
        ");",
        "",
        '    (* rom_style = "distributed" *) reg [7:0] tbl [0:511];',
        "",
        "    initial begin",
    ]
    for c in range(FIRST, LAST + 1):
        gb = glyph_bytes(chr(c))
        idx = (c - FIRST) * 8
        name = chr(c) if chr(c) != " " else "space"
        lines.append("        // '%s'" % name)
        lines.append("       " + "".join(f" tbl[{idx + r:3d}] = 8'h{gb[r]:02X};"
                                         for r in range(8)))
    lines += [
        "    end",
        "",
        "    wire in_range = (ch >= 8'h%02X) && (ch <= 8'h%02X);" % (FIRST, LAST),
        "",
        "    // The table starts at 0x%02X, so the glyph index is ch - 0x%02X, not"
        % (FIRST, FIRST),
        "    // ch[5:0]. Those differ by 32 with a wrap, which does not look like a",
        "    // fault - every character still renders, just a different one - so it",
        "    // survives right up until someone reads the screen: STARFRONT came out",
        "    // as 34 2 2/.4, which is exactly S->3, T->4, A->blank, R->2.",
        "    wire [5:0] gidx = ch[5:0] - 6'd%d;" % FIRST,
        "",
        "    assign bits = in_range ? tbl[{gidx, row}] : 8'h00;",
        "",
        "endmodule",
        "",
    ]
    # `addr` above is unused clutter; drop it.
    return "\n".join(x for x in lines if "wire [8:0] addr" not in x)


def main() -> int:
    (RTL / "pix_lut.v").write_text(gen_pix_lut())
    (RTL / "char_font.v").write_text(gen_char_font())
    print(f"wrote {RTL / 'pix_lut.v'}")
    print(f"wrote {RTL / 'char_font.v'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
