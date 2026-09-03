`timescale 1ns / 1ps

//============================================================================
// Module: cam_stream_probe
// Description: Measures what the camera is actually emitting, without needing
//              a frame buffer in the way.
//
//   Reading these four numbers off the screen is what turns "the picture is
//   wrong" into a specific answer:
//
//     bytes_per_line   1280 for VGA in a 2-byte format (RGB444 / RGB565 / YUV).
//                       640 means the sensor is in an 8-bit-per-pixel mode.
//                       Half of either means camera-side scaling is on
//                       (COM3 = 0x04) - see docs/ov7670_notes.md pitfall 3.
//     lines_per_frame   480 for VGA, 240 for QVGA.
//     frames_per_sec    about 30 with a 25 MHz XCLK.
//     pclk_freq_100k    PCLK in units of 100 kHz, so 250 means 25.0 MHz.
//                       125 means CLKRC is dividing by two.
//
//   Counting happens in the cam_pclk domain. Results cross into `clk` on a
//   toggle handshake: the counters are snapshotted at the frame boundary and
//   then sit still for a whole frame, so by the time the toggle has made it
//   through the synchroniser the data behind it is long settled.
//============================================================================

module cam_stream_probe #(
    parameter integer CLK_FREQ = 25_000_000
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        cam_pclk,
    input  wire        cam_href,
    input  wire        cam_vsync,

    output reg  [15:0] bytes_per_line,
    output reg  [15:0] lines_per_frame,
    output reg  [7:0]  frames_per_sec,
    output reg  [7:0]  pclk_freq_100k,
    output wire        stream_ok
);

    localparam [15:0] EXPECT_BYTES = 16'd1280;   // 640 pixels x 2 bytes
    localparam [15:0] EXPECT_LINES = 16'd480;

    //------------------------------------------------------------------------
    // cam_pclk domain: line and frame geometry
    //------------------------------------------------------------------------
    reg        href_d       = 1'b0;
    reg        vsync_d      = 1'b0;
    reg [15:0] byte_cnt     = 16'd0;
    reg [15:0] line_cnt     = 16'd0;
    reg [15:0] byte_snap    = 16'd0;   // last completed line, held for a frame
    reg [15:0] line_snap    = 16'd0;
    reg [15:0] byte_hold    = 16'd0;
    reg        frame_tog    = 1'b0;

    always @(posedge cam_pclk) begin
        href_d  <= cam_href;
        vsync_d <= cam_vsync;

        if (cam_href)
            byte_cnt <= byte_cnt + 16'd1;

        if (!cam_href && href_d) begin          // HREF falling = end of line
            byte_hold <= byte_cnt;
            byte_cnt  <= 16'd0;
            line_cnt  <= line_cnt + 16'd1;
        end

        if (cam_vsync && !vsync_d) begin        // VSYNC rising = end of frame
            byte_snap <= byte_hold;
            line_snap <= line_cnt;
            line_cnt  <= 16'd0;
            frame_tog <= ~frame_tog;
        end
    end

    //------------------------------------------------------------------------
    // cam_pclk domain: divide PCLK by 100,000 so the other side only has to
    // count a few hundred slow edges per second instead of tens of millions.
    //------------------------------------------------------------------------
    reg [16:0] div_cnt = 17'd0;
    reg        div_tog = 1'b0;

    always @(posedge cam_pclk) begin
        if (div_cnt == 17'd99_999) begin
            div_cnt <= 17'd0;
            div_tog <= ~div_tog;
        end else begin
            div_cnt <= div_cnt + 17'd1;
        end
    end

    //------------------------------------------------------------------------
    // clk domain
    //------------------------------------------------------------------------
    wire        frame_tog_s;
    wire        div_tog_s;
    wire [15:0] byte_snap_s;
    wire [15:0] line_snap_s;

    cdc_sync #(.WIDTH(1))  u_sync_frame (.clk(clk), .din(frame_tog), .dout(frame_tog_s));
    cdc_sync #(.WIDTH(1))  u_sync_div   (.clk(clk), .din(div_tog),   .dout(div_tog_s));
    cdc_sync #(.WIDTH(16)) u_sync_byte  (.clk(clk), .din(byte_snap), .dout(byte_snap_s));
    cdc_sync #(.WIDTH(16)) u_sync_line  (.clk(clk), .din(line_snap), .dout(line_snap_s));

    reg        frame_tog_d = 1'b0;
    reg        div_tog_d   = 1'b0;
    reg [7:0]  freq_acc    = 8'd0;
    reg [7:0]  fps_acc     = 8'd0;
    reg [24:0] sec_cnt     = 25'd0;

    wire frame_edge = (frame_tog_s != frame_tog_d);
    wire freq_edge  = (div_tog_s   != div_tog_d);
    wire sec_tick   = (sec_cnt == CLK_FREQ[24:0] - 25'd1);

    always @(posedge clk) begin
        if (rst) begin
            frame_tog_d     <= frame_tog_s;
            div_tog_d       <= div_tog_s;
            freq_acc        <= 8'd0;
            fps_acc         <= 8'd0;
            sec_cnt         <= 25'd0;
            bytes_per_line  <= 16'd0;
            lines_per_frame <= 16'd0;
            frames_per_sec  <= 8'd0;
            pclk_freq_100k  <= 8'd0;
        end else begin
            frame_tog_d <= frame_tog_s;
            div_tog_d   <= div_tog_s;
            sec_cnt     <= sec_tick ? 25'd0 : (sec_cnt + 25'd1);

            // The snapshots behind the toggle have been stable for several
            // camera clocks by now, so sampling them here is safe.
            if (frame_edge) begin
                bytes_per_line  <= byte_snap_s;
                lines_per_frame <= line_snap_s;
            end

            if (sec_tick) begin
                pclk_freq_100k <= freq_acc;
                frames_per_sec <= fps_acc;
                // Carry an edge landing on the boundary into the new window
                freq_acc <= freq_edge  ? 8'd1 : 8'd0;
                fps_acc  <= frame_edge ? 8'd1 : 8'd0;
            end else begin
                if (freq_edge  && (freq_acc != 8'hFF)) freq_acc <= freq_acc + 8'd1;
                if (frame_edge && (fps_acc  != 8'hFF)) fps_acc  <= fps_acc  + 8'd1;
            end
        end
    end

    assign stream_ok = (bytes_per_line  == EXPECT_BYTES) &&
                       (lines_per_frame == EXPECT_LINES);

endmodule
