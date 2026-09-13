`timescale 1ns / 1ps

//============================================================================
// Module: cam_capture
// Description: OV7670 RGB565 pixel capture pipeline, entirely in the PCLK domain.
//
// Ported unchanged in behaviour from the Basys 3 project's rgb444_capture, where
// it produced a correct live image. The three-cycle pipeline and the pixel_active
// guard below are not stylistic - each one fixes a specific bug that took days to
// find. See docs/ov7670_notes.md pitfalls 1 and 4 before touching either.
//
// The camera outputs two bytes per pixel in RGB565:
//   Byte 1 (even PCLK): { R[4:0], G[5:3] }
//   Byte 2 (odd  PCLK): { G[2:0], B[4:0] }
// so the stored pixel is simply the two bytes concatenated - no repacking.
//
// 3-cycle register pipeline avoids combinational read of ov7670_data
// during BRAM write (prevents metastability / rainbow noise):
//   Cycle 0: byte1_reg <= ov7670_data
//   Cycle 1: byte2_reg <= ov7670_data, set pixel_rdy
//   Cycle 2: compose RGB444 from registered bytes, write to BRAM
//
// Downsamples 640x480 to 320x240 by capturing only even pixels on
// even lines. First pixel of each line is skipped (pixel_active guard)
// to prevent stale-data edge artifacts.
//============================================================================

module cam_capture (
    input  wire        ov7670_pclk,
    input  wire        ov7670_href,
    input  wire        ov7670_vsync,
    input  wire [7:0]  ov7670_data,
    input  wire        gray_mode,

    output reg         cap_wr_en  = 1'b0,
    output reg  [16:0] cap_addr   = 17'd0,
    output reg  [15:0] cap_data   = 16'd0
);

    reg [10:0] pclk_cnt     = 11'd0;
    reg [9:0]  line_cnt     = 10'd0;
    reg [7:0]  byte1_reg    = 8'd0;
    reg [7:0]  byte2_reg    = 8'd0;
    reg        href_prev    = 1'b0;
    reg        pixel_rdy    = 1'b0;
    reg [16:0] pixel_addr   = 17'd0;

    wire       is_byte2   = pclk_cnt[0];
    wire [9:0] pixel_num  = pclk_cnt[10:1];
    wire       even_pixel = ~pixel_num[0];
    wire       even_line  = ~line_cnt[0];
    wire [8:0] ds_pixel   = pixel_num[9:1];
    wire [7:0] ds_line    = line_cnt[9:1];
    wire [16:0] ds_addr   = ({9'd0, ds_line} << 8) + ({9'd0, ds_line} << 6)
                           + {8'd0, ds_pixel};

    // Guard: skip first pixel of each line to avoid stale data
    wire       pixel_active = (pixel_num >= 10'd1);

    always @(posedge ov7670_pclk) begin
        cap_wr_en <= 1'b0;
        href_prev <= ov7670_href;

        if (ov7670_vsync) begin
            line_cnt  <= 10'd0;
            pclk_cnt  <= 11'd0;
            pixel_rdy <= 1'b0;
        end else if (!ov7670_href && href_prev) begin
            line_cnt  <= line_cnt + 10'd1;
            pclk_cnt  <= 11'd0;
            pixel_rdy <= 1'b0;
        end else if (ov7670_href) begin
            if (!is_byte2) begin
                // Even cycle: latch byte 1 (new pixel)
                byte1_reg <= ov7670_data;

                // Delayed BRAM write from PREVIOUS pixel pair
                if (pixel_rdy) begin
                    // Both bytes are fully registered by now, which is the
                    // whole point of the pipeline - reading the bus here
                    // instead is what produced rainbow noise on the Basys 3.
                    if (gray_mode) begin
                        // In the grayscale YUV422 mode the sensor delivers a Y
                        // byte for each pixel; we keep the brightness and map it
                        // back into the existing RGB565 framebuffer space.
                        cap_data <= {byte1_reg[7:3], byte1_reg[7:2], byte1_reg[7:3]};
                    end else begin
                        cap_data <= { byte1_reg, byte2_reg };   // RGB565
                    end
                    cap_addr  <= pixel_addr;
                    cap_wr_en <= 1'b1;
                end
                pixel_rdy <= 1'b0;
            end else begin
                // Odd cycle: latch byte 2, flag pixel ready
                byte2_reg <= ov7670_data;
                if (pixel_active && even_pixel && even_line
                    && ds_pixel < 9'd320 && ds_line < 8'd240) begin
                    pixel_rdy  <= 1'b1;
                    pixel_addr <= ds_addr;
                end else begin
                    pixel_rdy  <= 1'b0;
                end
            end
            pclk_cnt <= pclk_cnt + 11'd1;
        end else begin
            pixel_rdy <= 1'b0;
        end
    end

endmodule
