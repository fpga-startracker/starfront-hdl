`timescale 1ns / 1ps

//============================================================================
// Module: cam_capture
// Description: OV7670 luminance capture pipeline, entirely in the PCLK domain.
//
// The sensor runs in YUV422 and sends two bytes per pixel, one luminance and
// one chrominance, alternating U and V across pixel pairs:
//   Y0 U0 Y1 V0 Y2 U2 Y3 V2 ...     TSLB[3] = 0, COM13[0] = 0  (this table)
//   U0 Y0 V0 Y1 U2 Y2 V2 Y3 ...     TSLB[3] = 1, the sensor's power-on default
// Only Y is kept, so a stored pixel is a single byte and the buffer is half
// the size RGB565 needed. Which byte of the pair is Y is selected by
// y_second, so a wrong guess about the sensor's byte order is a key press on
// the bench rather than a rebuild.
//
// Ported in behaviour from the Basys 3 project's rgb444_capture, where it
// produced a correct live image. The three-cycle pipeline and the pixel_active
// guard below are not stylistic - each one fixes a specific bug that took days
// to find. See docs/ov7670_notes.md pitfalls 1 and 4 before touching either.
// Pitfall 1 in particular is *hidden* by a luminance-only capture, because the
// byte it needs is always one that was latched a cycle ago; the pipeline is
// kept as it was so that the full-resolution tap (cam_pixel_stream), which
// mirrors it, stays correct too.
//
// 3-cycle register pipeline avoids a combinational read of ov7670_data
// during the BRAM write:
//   Cycle 0: byte1_reg <= ov7670_data
//   Cycle 1: byte2_reg <= ov7670_data, set pixel_rdy
//   Cycle 2: pick Y from the registered bytes, write to BRAM
//
// Downsamples 640x480 to 320x240 by capturing only even pixels on even lines.
// The first pixel of each line is skipped (pixel_active guard) to prevent
// stale-data edge artifacts.
//============================================================================

module cam_capture (
    input  wire        ov7670_pclk,
    input  wire        ov7670_href,
    input  wire        ov7670_vsync,
    input  wire [7:0]  ov7670_data,
    input  wire        y_second,     // 0: Y is byte 1 of each pair, 1: byte 2

    output reg         cap_wr_en  = 1'b0,
    output reg  [16:0] cap_addr   = 17'd0,
    output reg  [7:0]  cap_data   = 8'd0
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
                    cap_data  <= y_second ? byte2_reg : byte1_reg;
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
