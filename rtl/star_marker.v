`timescale 1ns / 1ps

//============================================================================
// Module: star_marker
// Description: Draws a cross on every detected star as the raster goes past.
//
//   Testing 640 pixels against 64 stars is 64 comparators the design cannot
//   afford, and a marker bitmap is a block RAM that has to be cleared every
//   frame - 65536 writes into 1.3 ms of vertical blanking, which does not fit.
//
//   So the list is filtered once per line instead. Horizontal blanking is 160
//   clocks and the whole list is 64 entries, so the entire list is walked
//   during the blank and the handful of stars that touch the next line are
//   latched into eight slots. The active line then needs eight comparators.
//   Nothing is stored per pixel and nothing has to be cleared.
//
//   Eight slots because that is what a line ever needs: the stars are spread
//   over 240 rows and a marker is nine pixels tall, so a line seeing more than
//   eight is a field far denser than a star tracker would ever be pointed at.
//   Past eight the extras go undrawn, which costs a marker on the screen and
//   nothing in the star list itself.
//
//   The centre of the cross is left open so the star stays visible underneath
//   it - the point of the display is to see whether the marker is on the star.
//============================================================================

module star_marker #(
    parameter integer CROP_X0 = 8,     // first detector column shown
    parameter integer CROP_Y0 = 8,
    parameter integer CROP_W  = 240,   // detector pixels shown
    parameter integer CROP_H  = 240,
    parameter integer SCALE_SHIFT = 1, // screen = detector << this: 1 for the
                                       // bench's 2x, 0 for the camera's 1:1
    parameter integer CW      = 16,    // list entry width
    parameter integer FRAC    = 8,     // of which fractional bits
    parameter integer ARM_IN  = 3,     // gap at the centre, screen pixels
    parameter integer ARM_OUT = 9,
    parameter integer H_ACTIVE = 640
) (
    input  wire        clk,
    input  wire        rst,

    input  wire [9:0]  pixel_x,        // raster counter, 0 .. H_TOTAL-1
    input  wire [9:0]  pixel_y,

    input  wire [6:0]    star_count,
    output wire [5:0]    rd_addr,      // combinational read of the star list
    input  wire [CW-1:0] rd_x,         // detector coordinates, FRAC fractional bits
    input  wire [CW-1:0] rd_y,

    output wire        mark
);

    localparam integer NSLOT = 8;

    // Screen position of a star: drop the fraction, shift the crop origin away,
    // double. The fraction is deliberately dropped - a marker is drawn on a
    // pixel grid and a quarter-pixel centroid has nowhere to go on it.
    wire [CW-FRAC-1:0] bx = rd_x[CW-1:FRAC];
    wire [CW-FRAC-1:0] by = rd_y[CW-1:FRAC];
    wire       in_crop = (bx >= CROP_X0) && (bx < CROP_X0 + CROP_W) &&
                         (by >= CROP_Y0) && (by < CROP_Y0 + CROP_H);
    wire [9:0] bx10 = bx;                 // zero-extended
    wire [9:0] by10 = by;
    wire [9:0] sx_scr = (bx10 - CROP_X0) << SCALE_SHIFT;
    wire [9:0] sy_scr = (by10 - CROP_Y0) << SCALE_SHIFT;

    //------------------------------------------------------------------------
    // Walk the list during horizontal blanking, for the line about to start
    //------------------------------------------------------------------------
    reg [6:0]  scan_i    = 7'd0;
    reg        scanning  = 1'b0;
    reg [2:0]  nslot     = 3'd0;
    reg [NSLOT-1:0] slot_valid = {NSLOT{1'b0}};
    reg [9:0]  slot_x [0:NSLOT-1];
    reg [9:0]  slot_y [0:NSLOT-1];

    assign rd_addr = scan_i[5:0];

    wire [9:0] next_row = pixel_y + 10'd1;
    wire [9:0] dy_next  = (sy_scr > next_row) ? (sy_scr - next_row)
                                              : (next_row - sy_scr);
    wire       touches  = in_crop && (dy_next <= ARM_OUT);

    integer k;

    always @(posedge clk) begin
        if (rst) begin
            scanning   <= 1'b0;
            slot_valid <= {NSLOT{1'b0}};
        end else if (pixel_x == H_ACTIVE[9:0]) begin
            scan_i     <= 7'd0;
            nslot      <= 3'd0;
            slot_valid <= {NSLOT{1'b0}};
            scanning   <= 1'b1;
        end else if (scanning) begin
            if (scan_i >= star_count) begin
                scanning <= 1'b0;
            end else begin
                if (touches && (nslot != NSLOT[2:0] - 3'd1 || !slot_valid[NSLOT-1])) begin
                    slot_x[nslot]     <= sx_scr;
                    slot_y[nslot]     <= sy_scr;
                    slot_valid[nslot] <= 1'b1;
                    if (nslot != NSLOT[2:0] - 3'd1)
                        nslot <= nslot + 3'd1;
                end
                scan_i <= scan_i + 7'd1;
            end
        end
    end

    //------------------------------------------------------------------------
    // Draw
    //------------------------------------------------------------------------
    reg hit;

    always @(*) begin
        hit = 1'b0;
        for (k = 0; k < NSLOT; k = k + 1) begin
            if (slot_valid[k]) begin
                if ((pixel_y == slot_y[k]) &&
                    (((pixel_x > slot_x[k]) &&
                      (pixel_x - slot_x[k] >= ARM_IN) &&
                      (pixel_x - slot_x[k] <= ARM_OUT)) ||
                     ((pixel_x < slot_x[k]) &&
                      (slot_x[k] - pixel_x >= ARM_IN) &&
                      (slot_x[k] - pixel_x <= ARM_OUT))))
                    hit = 1'b1;

                if ((pixel_x == slot_x[k]) &&
                    (((pixel_y > slot_y[k]) &&
                      (pixel_y - slot_y[k] >= ARM_IN) &&
                      (pixel_y - slot_y[k] <= ARM_OUT)) ||
                     ((pixel_y < slot_y[k]) &&
                      (slot_y[k] - pixel_y >= ARM_IN) &&
                      (slot_y[k] - pixel_y <= ARM_OUT))))
                    hit = 1'b1;
            end
        end
    end

    assign mark = hit;

endmodule
