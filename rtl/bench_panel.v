`timescale 1ns / 1ps

//============================================================================
// Module: bench_panel
// Description: The text column beside the image: what the detector found and
//              what it is thresholding at.
//
//   The board has no UART reachable from the PL, so the screen is the only
//   place these numbers can appear while the design is running. status_overlay
//   already does this for camera bring-up, but it draws bare hex digits and
//   the reader has to remember which row is which. A centroid bench has more
//   numbers and they are only useful labelled, so this one carries text.
//
//   Ten characters by thirty lines, each cell an 8x8 glyph doubled to 16x16 -
//   large enough to read across a room, which is where the person watching a
//   demonstration usually is.
//
//   Values are hex, matching the rest of the project's overlays. Positions are
//   the raw fixed-point centroid: two digits of binned pixel, a point, then two
//   digits of the fraction, so 6E.80 is 110.5 and the sub-pixel part is visible
//   rather than rounded away - which is the entire claim being demonstrated.
//============================================================================

module bench_panel #(
    parameter integer X0   = 480,      // left edge on screen
    parameter integer COLS = 10,
    parameter integer ROWS = 30
) (
    input  wire [9:0]  pixel_x,
    input  wire [9:0]  pixel_y,

    input  wire [7:0]  star_count,
    input  wire [7:0]  dropped,
    input  wire        overflow,
    input  wire [15:0] frame_count,
    input  wire [7:0]  fps,
    input  wire [7:0]  bg_code,
    input  wire [7:0]  thr_code,
    input  wire [13:0] mad_acc,      // 8.6 fixed point
    input  wire [15:0] best_x,       // 8.8 fixed point, binned pixels
    input  wire [15:0] best_y,
    input  wire [19:0] best_sum,
    input  wire signed [6:0] scroll_x,   // display-pixel read offset

    output wire        in_panel,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b
);

    assign in_panel = (pixel_x >= X0) && (pixel_x < X0 + COLS*16) &&
                      (pixel_y < ROWS*16);

    wire [9:0] px = pixel_x - X0[9:0];
    wire [3:0] col = px[7:4];
    wire [4:0] row = pixel_y[8:4];
    wire [2:0] gx  = px[3:1];
    wire [2:0] gy  = pixel_y[3:1];

    function [7:0] hexc;
        input [3:0] v;
        begin
            hexc = (v < 4'd10) ? (8'h30 + {4'd0, v}) : (8'h41 + {4'd0, v} - 8'd10);
        end
    endfunction

    // Magnitude of the scroll offset, in display pixels, for the readout. One
    // display pixel is a quarter of a binned pixel, so a step of one must move
    // every centroid by 0x40 in the 8.8 readout and by nothing else.
    wire [7:0] smag = scroll_x[6] ? (8'd0 - {{1{scroll_x[6]}}, scroll_x})
                                  : {1'b0, scroll_x};

    reg [COLS*8-1:0] line;

    always @(*) begin
        case (row)
        5'd0:  line = " STARFRONT";
        5'd1:  line = " CENTROID ";
        5'd2:  line = "==========";
        5'd3:  line = {"STARS   ", hexc(star_count[7:4]), hexc(star_count[3:0])};
        5'd4:  line = {"DROP    ", hexc(dropped[7:4]),    hexc(dropped[3:0])};
        5'd5:  line = {"FULL     ", overflow ? "Y" : "N"};
        5'd6:  line = {"FRAME ", hexc(frame_count[15:12]), hexc(frame_count[11:8]),
                                 hexc(frame_count[7:4]),   hexc(frame_count[3:0])};
        5'd7:  line = {"FPS     ", hexc(fps[7:4]), hexc(fps[3:0])};
        5'd8:  line = "          ";
        5'd9:  line = "SKY LEVEL ";
        5'd10: line = {"BG      ", hexc(bg_code[7:4]),  hexc(bg_code[3:0])};
        5'd11: line = {"MAD  ", hexc(mad_acc[13:10]), hexc(mad_acc[9:6]), ".",
                                hexc(mad_acc[5:2]),   hexc({mad_acc[1:0], 2'b00})};
        5'd12: line = {"THRESH  ", hexc(thr_code[7:4]), hexc(thr_code[3:0])};
        5'd13: line = "          ";
        5'd14: line = "BRIGHTEST ";
        5'd15: line = {"X   ", hexc(best_x[15:12]), hexc(best_x[11:8]), ".",
                               hexc(best_x[7:4]),   hexc(best_x[3:0])};
        5'd16: line = {"Y   ", hexc(best_y[15:12]), hexc(best_y[11:8]), ".",
                               hexc(best_y[7:4]),   hexc(best_y[3:0])};
        5'd17: line = {"I    ", hexc(best_sum[19:16]), hexc(best_sum[15:12]),
                                hexc(best_sum[11:8]),  hexc(best_sum[7:4]),
                                hexc(best_sum[3:0])};
        5'd18: line = "          ";
        5'd19: line = {"SCROLL ", scroll_x[6] ? "-" : "+",
                                 hexc(smag[7:4]), hexc(smag[3:0])};
        5'd20: line = "KEY2 STEP ";
        5'd21: line = "KEY3 SCRL ";
        5'd22: line = "KEY4 HOLD ";
        default: line = "          ";
        endcase
    end

    wire [7:0] ch = line[(COLS-1 - col)*8 +: 8];

    wire [7:0] glyph;
    char_font u_font (.ch(ch), .row(gy), .bits(glyph));

    wire on = glyph[3'd7 - gx];

    // A colour per band, so the eye finds the number it wants without reading.
    always @(*) begin
        if (!in_panel) begin
            r = 8'h00; g = 8'h00; b = 8'h00;
        end else if (row < 5'd2) begin
            r = on ? 8'h30 : 8'h08;  g = on ? 8'hF0 : 8'h10;  b = on ? 8'h80 : 8'h20;
        end else if (row < 5'd8) begin
            r = on ? 8'hF0 : 8'h08;  g = on ? 8'hF0 : 8'h08;  b = on ? 8'hF0 : 8'h10;
        end else if (row < 5'd13) begin
            r = on ? 8'h70 : 8'h08;  g = on ? 8'hC0 : 8'h08;  b = on ? 8'hFF : 8'h10;
        end else if (row < 5'd18) begin
            r = on ? 8'hFF : 8'h08;  g = on ? 8'hC0 : 8'h08;  b = on ? 8'h40 : 8'h10;
        end else begin
            r = on ? 8'h90 : 8'h08;  g = on ? 8'h90 : 8'h08;  b = on ? 8'h90 : 8'h10;
        end
    end

endmodule
