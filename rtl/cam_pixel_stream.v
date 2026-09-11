`timescale 1ns / 1ps

//============================================================================
// Module: cam_pixel_stream
// Description: Unpacks the OV7670's byte stream into one 640x480 pixel per
//              strobe, with its coordinates and an 8-bit luminance.
//
//   This is the full-resolution tap. cam_capture throws away three pixels in
//   four on its way to the 320x240 display buffer; the star detector cannot
//   afford that, because a star lands on one to three pixels and centroid
//   precision comes directly from how many of them are measured.
//
//   The byte staging deliberately mirrors cam_capture rather than sharing code
//   with it: that pipeline is hardware-proven and is the one place where
//   reading the data bus a cycle early produces rainbow noise (see
//   docs/ov7670_notes.md pitfall 1), so it is left untouched.
//
//   Luminance is the usual (R + 2G + B) / 4 on the channels expanded to eight
//   bits. For the star work this will be replaced by the sensor's own Y in
//   YUV422 mode, which skips the colour matrix entirely.
//
// Clock domain: cam_pclk throughout.
//============================================================================

module cam_pixel_stream (
    input  wire        pclk,
    input  wire        href,
    input  wire        vsync,
    input  wire [7:0]  data,
    input  wire        gray_mode,

    output reg         pix_valid,    // one cycle per source pixel
    output reg  [9:0]  pix_x,        // 0..639
    output reg  [9:0]  pix_y,        // 0..479
    output reg  [15:0] pix_rgb,      // RGB565 as it came off the bus
    output reg  [7:0]  pix_luma,
    output reg         frame_start   // one cycle pulse at the start of a frame
);

    reg [10:0] pclk_cnt  = 11'd0;
    reg [9:0]  line_cnt  = 10'd0;
    reg [7:0]  byte1_reg = 8'd0;
    reg [7:0]  byte2_reg = 8'd0;
    reg        href_prev = 1'b0;
    reg        vsync_prev = 1'b0;
    reg        pixel_rdy = 1'b0;
    reg [9:0]  pending_x = 10'd0;
    reg [9:0]  pending_y = 10'd0;

    wire       is_byte2  = pclk_cnt[0];
    wire [9:0] pixel_num = pclk_cnt[10:1];

    //------------------------------------------------------------------------
    // Luminance from the two registered bytes
    //------------------------------------------------------------------------
    wire [4:0] r5 = byte1_reg[7:3];
    wire [5:0] g6 = {byte1_reg[2:0], byte2_reg[7:5]};
    wire [4:0] b5 = byte2_reg[4:0];

    wire [7:0] r8 = {r5, r5[4:2]};
    wire [7:0] g8 = {g6, g6[5:4]};
    wire [7:0] b8 = {b5, b5[4:2]};

    wire [9:0] luma_sum = {2'b0, r8} + {1'b0, g8, 1'b0} + {2'b0, b8};

    always @(posedge pclk) begin
        pix_valid   <= 1'b0;
        frame_start <= 1'b0;
        href_prev   <= href;
        vsync_prev  <= vsync;

        if (vsync) begin
            if (!vsync_prev) frame_start <= 1'b1;
            line_cnt  <= 10'd0;
            pclk_cnt  <= 11'd0;
            pixel_rdy <= 1'b0;
        end else if (!href && href_prev) begin
            line_cnt  <= line_cnt + 10'd1;
            pclk_cnt  <= 11'd0;
            pixel_rdy <= 1'b0;
        end else if (href) begin
            if (!is_byte2) begin
                byte1_reg <= data;

                // The pixel staged on the previous two cycles is complete and
                // fully registered by now - emit it.
                if (pixel_rdy) begin
                    pix_valid <= 1'b1;
                    pix_x     <= pending_x;
                    pix_y     <= pending_y;
                    pix_rgb   <= gray_mode ? {byte1_reg[7:3], byte1_reg[7:2], byte1_reg[7:3]} : {byte1_reg, byte2_reg};
                    pix_luma  <= gray_mode ? byte1_reg : luma_sum[9:2];
                end
                pixel_rdy <= 1'b0;
            end else begin
                byte2_reg <= data;
                pending_x <= pixel_num;
                pending_y <= line_cnt;
                pixel_rdy <= (pixel_num < 10'd640) && (line_cnt < 10'd480);
            end
            pclk_cnt <= pclk_cnt + 11'd1;
        end else begin
            pixel_rdy <= 1'b0;
        end
    end

endmodule
