`timescale 1ns / 1ps

//============================================================================
// Module: fb_mem
// Description: Frame buffer - simple dual-port RAM with independent read and
//              write clocks. This is where the camera domain and the display
//              domain actually meet: capture writes at cam_pclk, the display
//              reads at clk_pix, and the block RAM itself handles the crossing.
//              The XDC declares the two clocks asynchronous for that reason.
//
//   320 x 240 x 8 bit = 614,400 bits. The RGB565 version of this buffer was
//   1,228,800 bits and Vivado mapped it to 48 of the 7z010's 60 RAMB36 tiles -
//   it builds a memory this deep out of 32K x 1 primitives, three per data
//   bit, so the tile count is simply three times the width. Eight bits is
//   24 tiles, which is what made room for the second frame buffer the tearing
//   note in docs/ov7670_notes.md asks for, and for anything M7 needs.
//
//   Unlike the Basys 3 version this is inferred rather than a Block Memory
//   Generator instance: it needs no IP generation step, simulates directly, and
//   Vivado maps it to block RAM just as well. Vivado initialises block RAM to
//   zero, so the screen starts black rather than showing noise.
//============================================================================

module fb_mem #(
    parameter integer ADDR_W = 17,
    parameter integer DATA_W = 8,
    parameter integer DEPTH  = 76800
) (
    // Write port - camera domain
    input  wire              clk_wr,
    input  wire              wr_en,
    input  wire [ADDR_W-1:0] addr_wr,
    input  wire [DATA_W-1:0] data_wr,

    // Read port - pixel domain
    input  wire              clk_rd,
    input  wire [ADDR_W-1:0] addr_rd,
    output reg  [DATA_W-1:0] data_rd
);

    (* ram_style = "block" *) reg [DATA_W-1:0] mem [0:DEPTH-1];

    // Explicit zero fill. Vivado already defaults block RAM to zero, but
    // saying so makes simulation match hardware and turns "this region is
    // never written" into a visibly black band instead of an unknown.
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = {DATA_W{1'b0}};
    end

    always @(posedge clk_wr) begin
        if (wr_en)
            mem[addr_wr] <= data_wr;
    end

    always @(posedge clk_rd) begin
        data_rd <= mem[addr_rd];
    end

endmodule
