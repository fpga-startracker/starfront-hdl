`timescale 1ns / 1ps

//============================================================================
// Module: hex_font
// Description: 8x8 glyph ROM for the sixteen hex digits, one row at a time.
//
//   Purely combinational. Bit 7 of `bits` is the leftmost pixel of the row.
//   Column 0 and column 7 are blank in every glyph, so digits drawn edge to
//   edge still have space between them - the caller does not need a gap.
//
//   This exists so cam_stream_probe's numbers can be read off the screen as
//   0500 01E0 instead of counted as sixteen lit and unlit squares. On a board
//   with no UART, that difference matters.
//============================================================================

module hex_font (
    input  wire [3:0] value,
    input  wire [2:0] row,      // 0 = top row of the glyph
    output wire [7:0] bits
);

    reg [63:0] glyph;

    always @(*) begin
        case (value)
        4'h0: glyph = 64'h38_44_44_44_44_44_38_00;
        4'h1: glyph = 64'h10_30_10_10_10_10_38_00;
        4'h2: glyph = 64'h38_44_04_08_10_20_7C_00;
        4'h3: glyph = 64'h78_04_04_38_04_04_78_00;
        4'h4: glyph = 64'h0C_14_24_44_7C_04_04_00;
        4'h5: glyph = 64'h7C_40_78_04_04_44_38_00;
        4'h6: glyph = 64'h38_44_40_78_44_44_38_00;
        4'h7: glyph = 64'h7C_04_08_10_20_20_20_00;
        4'h8: glyph = 64'h38_44_44_38_44_44_38_00;
        4'h9: glyph = 64'h38_44_44_3C_04_44_38_00;
        4'hA: glyph = 64'h38_44_44_7C_44_44_44_00;
        4'hB: glyph = 64'h78_44_44_78_44_44_78_00;
        4'hC: glyph = 64'h38_44_40_40_40_44_38_00;
        4'hD: glyph = 64'h70_48_44_44_44_48_70_00;
        4'hE: glyph = 64'h7C_40_40_78_40_40_7C_00;
        4'hF: glyph = 64'h7C_40_40_78_40_40_40_00;
        endcase
    end

    // Row 0 lives in the most significant byte
    wire [5:0] byte_shift = {3'd7 - row, 3'b000};   // (7 - row) * 8

    assign bits = glyph[byte_shift +: 8];

endmodule
