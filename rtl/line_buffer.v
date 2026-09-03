`timescale 1ns / 1ps

//============================================================================
// Module: line_buffer
// Description: One scan line of delay, with a combinational read.
//
//   A chain of these gives simultaneous access to several rows of a raster
//   without ever storing a whole frame: 640 x 8 bits is 5 Kbit, so a five-row
//   window costs four of them against the 48 BRAM tiles a full frame needs.
//
//   The read is combinational (distributed RAM) on purpose. With a registered
//   read the chain skews by one column per stage and every row has to be
//   re-aligned with its own delay pipeline - a whole class of off-by-one bugs
//   that simply does not exist this way. Four of these cost roughly 320 LUTs.
//============================================================================

module line_buffer #(
    parameter integer WIDTH = 8,
    parameter integer DEPTH = 640
) (
    input  wire             clk,
    input  wire             we,
    input  wire [9:0]       addr,
    input  wire [WIDTH-1:0] din,
    output wire [WIDTH-1:0] dout    // combinational: previous line, same column
);

    (* ram_style = "distributed" *) reg [WIDTH-1:0] mem [0:DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = {WIDTH{1'b0}};
    end

    assign dout = mem[addr];

    always @(posedge clk) begin
        if (we)
            mem[addr] <= din;
    end

endmodule
