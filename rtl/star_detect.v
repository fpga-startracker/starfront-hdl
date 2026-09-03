`timescale 1ns / 1ps

//============================================================================
// Module: star_detect
// Description: Streaming star finder. Runs at the camera's full 640x480 as
//              the pixels arrive, with four line buffers and no frame store.
//
//   Why streaming: a star lands on one to three pixels, and centroid precision
//   comes from how many of them get measured. The 2:1 downsample feeding the
//   display throws away three pixels in four, which would throw away most of
//   the sky. Buffering a full 640x480 frame is not an option either - eight
//   bits deep it needs 75 BRAM tiles and the 7z010 has 60. Processing the
//   stream as it arrives costs four line buffers, about 20 Kbit.
//
//   Pipeline:
//     luma ─► 4x line_buffer ─► 5x5 window ─► peak test ─► centroid sums
//
//   Threshold is adaptive: half of the brightest pixel seen in the previous
//   frame, with a floor so that a dark frame does not turn sensor noise into a
//   sky full of stars. That needs no tuning knob and follows the scene.
//
//   Peak test uses a raster tie-break - strictly greater than the neighbours
//   that come before the centre, greater or equal to those after. A plain
//   strict maximum would miss saturated stars, whose cores are flat at 255,
//   and a plain >= would report a whole plateau as several stars.
//
//   Centroid sums subtract the threshold first, so background does not drag
//   the result toward the middle of the window. sum_dx / sum_i is the
//   sub-pixel offset; the division itself is left to a later stage, which can
//   take its time between frames.
//
// Clock domain: cam_pclk. Results are latched at the frame boundary and
// published with a toggle handshake, the same pattern as cam_stream_probe.
//============================================================================

module star_detect #(
    parameter integer MIN_THRESH = 40      // floor, keeps noise out of a dark frame
) (
    input  wire        pclk,
    input  wire        rst,

    // Full resolution pixel stream
    input  wire        pix_valid,
    input  wire [9:0]  pix_x,
    input  wire [9:0]  pix_y,
    input  wire [7:0]  pix_luma,
    input  wire        frame_start,

    // Per-frame results, stable between frame_start pulses
    output reg  [7:0]  star_count,
    output reg  [7:0]  threshold,
    output reg  [7:0]  frame_max,
    output reg  [9:0]  bright_x,
    output reg  [9:0]  bright_y,
    output reg  [12:0] bright_sum,
    output reg         result_tog       // toggles once per frame, for the CDC
);

    localparam integer N_STAR_MAX = 255;

    //------------------------------------------------------------------------
    // Four line buffers: rows y-1 .. y-4 at the current column
    //------------------------------------------------------------------------
    wire [7:0] row1, row2, row3, row4;   // y-1 .. y-4

    line_buffer u_lb0 (.clk(pclk), .we(pix_valid), .addr(pix_x), .din(pix_luma), .dout(row1));
    line_buffer u_lb1 (.clk(pclk), .we(pix_valid), .addr(pix_x), .din(row1),     .dout(row2));
    line_buffer u_lb2 (.clk(pclk), .we(pix_valid), .addr(pix_x), .din(row2),     .dout(row3));
    line_buffer u_lb3 (.clk(pclk), .we(pix_valid), .addr(pix_x), .din(row3),     .dout(row4));

    //------------------------------------------------------------------------
    // 5x5 window, w[r*5 + c]. Row 0 is the oldest line (y-4), column 0 is the
    // leftmost (x-4); new pixels enter at the right. Centre is w[12].
    //------------------------------------------------------------------------
    reg [7:0] w [0:24];

    reg [9:0] cx        = 10'd0;
    reg [9:0] cy        = 10'd0;
    reg       win_ready = 1'b0;

    integer r, k;

    always @(posedge pclk) begin
        if (pix_valid) begin
            for (r = 0; r < 5; r = r + 1) begin
                w[r*5 + 0] <= w[r*5 + 1];
                w[r*5 + 1] <= w[r*5 + 2];
                w[r*5 + 2] <= w[r*5 + 3];
                w[r*5 + 3] <= w[r*5 + 4];
            end
            w[0*5 + 4] <= row4;
            w[1*5 + 4] <= row3;
            w[2*5 + 4] <= row2;
            w[3*5 + 4] <= row1;
            w[4*5 + 4] <= pix_luma;

            cx        <= pix_x - 10'd2;
            cy        <= pix_y - 10'd2;
            win_ready <= (pix_x >= 10'd4) && (pix_y >= 10'd4);
        end else begin
            win_ready <= 1'b0;
        end
    end

    //------------------------------------------------------------------------
    // Peak test
    //------------------------------------------------------------------------
    wire [7:0] centre = w[12];

    wire greater_before = (centre > w[0])  && (centre > w[1])  && (centre > w[2])  &&
                          (centre > w[3])  && (centre > w[4])  && (centre > w[5])  &&
                          (centre > w[6])  && (centre > w[7])  && (centre > w[8])  &&
                          (centre > w[9])  && (centre > w[10]) && (centre > w[11]);

    wire ge_after       = (centre >= w[13]) && (centre >= w[14]) && (centre >= w[15]) &&
                          (centre >= w[16]) && (centre >= w[17]) && (centre >= w[18]) &&
                          (centre >= w[19]) && (centre >= w[20]) && (centre >= w[21]) &&
                          (centre >= w[22]) && (centre >= w[23]) && (centre >= w[24]);

    wire is_peak = win_ready && (centre > threshold) && greater_before && ge_after;

    //------------------------------------------------------------------------
    // Centroid sums, background removed
    //------------------------------------------------------------------------
    wire [7:0] q [0:24];
    genvar gi;
    generate
        for (gi = 0; gi < 25; gi = gi + 1) begin : g_sub
            assign q[gi] = (w[gi] > threshold) ? (w[gi] - threshold) : 8'd0;
        end
    endgenerate

    wire [10:0] colsum [0:4];
    generate
        for (gi = 0; gi < 5; gi = gi + 1) begin : g_col
            assign colsum[gi] = q[0*5+gi] + q[1*5+gi] + q[2*5+gi] + q[3*5+gi] + q[4*5+gi];
        end
    endgenerate

    wire [12:0] sum_i = colsum[0] + colsum[1] + colsum[2] + colsum[3] + colsum[4];

    //------------------------------------------------------------------------
    // Per-frame accumulation
    //------------------------------------------------------------------------
    reg [7:0]  count_acc  = 8'd0;
    reg [7:0]  max_acc    = 8'd0;
    reg [12:0] best_sum   = 13'd0;
    reg [9:0]  best_x     = 10'd0;
    reg [9:0]  best_y     = 10'd0;

    always @(posedge pclk) begin
        if (rst) begin
            count_acc  <= 8'd0;
            max_acc    <= 8'd0;
            best_sum   <= 13'd0;
            best_x     <= 10'd0;
            best_y     <= 10'd0;
            star_count <= 8'd0;
            frame_max  <= 8'd0;
            bright_x   <= 10'd0;
            bright_y   <= 10'd0;
            bright_sum <= 13'd0;
            threshold  <= MIN_THRESH[7:0];
            result_tog <= 1'b0;
        end else if (frame_start) begin
            // Publish the frame that just ended, and re-arm
            star_count <= count_acc;
            frame_max  <= max_acc;
            bright_x   <= best_x;
            bright_y   <= best_y;
            bright_sum <= best_sum;
            result_tog <= ~result_tog;

            // Half of the brightest pixel, never below the noise floor
            threshold  <= (max_acc[7:1] > MIN_THRESH[7:0]) ? max_acc[7:1]
                                                           : MIN_THRESH[7:0];

            count_acc  <= 8'd0;
            max_acc    <= 8'd0;
            best_sum   <= 13'd0;
            best_x     <= 10'd0;
            best_y     <= 10'd0;
        end else begin
            if (pix_valid && (pix_luma > max_acc))
                max_acc <= pix_luma;

            if (is_peak) begin
                if (count_acc != N_STAR_MAX[7:0])
                    count_acc <= count_acc + 8'd1;

                if (sum_i > best_sum) begin
                    best_sum <= sum_i;
                    best_x   <= cx;
                    best_y   <= cy;
                end
            end
        end
    end

endmodule
