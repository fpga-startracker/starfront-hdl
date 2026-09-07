`timescale 1ns / 1ps

//============================================================================
// Module: fb_reader
// Description: Turns display coordinates into frame buffer reads, with 2x
//              pixel doubling so the 320x240 buffer fills the 640x480 screen.
//
//   Ported from the Basys 3 vga_controller, minus the sync generator (which
//   lives separately here) and with the RGB565 channels expanded to the 8-bit
//   ones the TMDS encoder wants.
//
//   Latency is one clock: fb_addr_rd is combinational from the pixel position,
//   and the block RAM registers its output. The top level delays hsync, vsync
//   and de by the same clock so everything stays aligned.
//============================================================================

module fb_reader (
    input  wire [9:0]  pixel_x,
    input  wire [9:0]  pixel_y,
    input  wire        active,       // already delayed to match fb_data_rd

    output wire [16:0] fb_addr_rd,
    input  wire [15:0] fb_data_rd,   // {R[4:0], G[5:0], B[4:0]}

    output wire [7:0]  r,
    output wire [7:0]  g,
    output wire [7:0]  b
);

    //------------------------------------------------------------------------
    // Pixel doubling: each buffer pixel covers a 2x2 block on screen
    //------------------------------------------------------------------------
    wire [8:0] logical_x = pixel_x[9:1];   // 0..319
    wire [8:0] logical_y = pixel_y[9:1];   // 0..239

    //------------------------------------------------------------------------
    // addr = y * 320 + x, as (y << 8) + (y << 6) + x so no multiplier is used
    //------------------------------------------------------------------------
    wire [16:0] logical_y_ext = {8'b0, logical_y};

    assign fb_addr_rd = (logical_y_ext << 8) + (logical_y_ext << 6)
                      + {8'b0, logical_x};

    //------------------------------------------------------------------------
    // RGB565 -> RGB888. The top bits are replicated into the low ones so that
    // an all-ones channel maps to 0xFF rather than 0xF8, which would otherwise
    // stop white from ever being white.
    //------------------------------------------------------------------------
    wire [4:0] r5 = fb_data_rd[15:11];
    wire [5:0] g6 = fb_data_rd[10:5];
    wire [4:0] b5 = fb_data_rd[4:0];

    assign r = active ? {r5, r5[4:2]} : 8'h00;
    assign g = active ? {g6, g6[5:4]} : 8'h00;
    assign b = active ? {b5, b5[4:2]} : 8'h00;

endmodule
