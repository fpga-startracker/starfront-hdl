`timescale 1ns / 1ps

//============================================================================
// Module: cam_pixel_stream
// Description: Unpacks the OV7670's byte stream into one 640x480 pixel per
//              strobe, with its coordinates and the sensor's own 8-bit
//              luminance.
//
//   This is the full-resolution tap. cam_capture throws away three pixels in
//   four on its way to the 320x240 display buffer; the star detector cannot
//   afford that, because a star lands on one to three pixels and centroid
//   precision comes directly from how many of them are measured.
//
//   The sensor runs in YUV422, two bytes per pixel, one of them Y. That byte
//   is the luminance the detector wants - computed by the sensor from all
//   three colour channels at full precision, with no colour matrix or channel
//   expansion on this side. y_second says which byte of the pair it is; see
//   cam_capture.v for the two orders the sensor can produce.
//
//   The byte staging deliberately mirrors cam_capture rather than sharing code
//   with it: that pipeline is hardware-proven and is the one place where
//   reading the data bus a cycle early produces rainbow noise (see
//   docs/ov7670_notes.md pitfall 1), so it is left untouched.
//
// Clock domain: cam_pclk throughout.
//============================================================================

module cam_pixel_stream (
    input  wire        pclk,
    input  wire        href,
    input  wire        vsync,
    input  wire [7:0]  data,
    input  wire        y_second,     // 0: Y is byte 1 of each pair, 1: byte 2

    output reg         pix_valid,    // one cycle per source pixel
    output reg  [9:0]  pix_x,        // 0..639
    output reg  [9:0]  pix_y,        // 0..479
    output reg  [7:0]  pix_luma,     // the sensor's Y, 0..255
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
                    pix_luma  <= y_second ? byte2_reg : byte1_reg;
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
