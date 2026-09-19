`timescale 1ns / 1ps

//============================================================================
// Module: axis_cam_bridge
// Description: Translates an incoming AXI4-Stream byte stream into compliant
//              OV7670 camera signals (emu_pclk, emu_href, emu_vsync, emu_data).
//
//   Line Buffer & Burst Architecture:
//     OV7670 bus timing requires that every clock cycle during HREF carries
//     valid pixel bytes (no mid-line pauses allowed).
//     This module buffers incoming AXI-Stream bytes into an internal 640-pixel
//     x 16-bit Block RAM (single 18K BRAM tile, zero LUT overhead).
//     Once a complete scanline has been received, it bursts the entire line
//     out at 25 MHz with a continuous HREF pulse (1280 cycles), followed by
//     standard horizontal blanking (~144 clocks).
//
//   Input Format Support:
//     - gray_input = 0 (RGB565): 1280 bytes/line received over AXI.
//     - gray_input = 1 (Grayscale Y): 640 bytes/line received over AXI.
//       The module expands each luminance byte Y into a compliant 2-byte pair
//       {Y, 8'h80} (neutral chroma) on the output.
//
//   Frame Synchronization:
//     A 4-byte magic word (0xAA, 0x55, 0xAA, 0x55) triggers a fresh frame,
//     pulsing emu_vsync high for 100 cycles before line 0.
//============================================================================

module axis_cam_bridge #(
    parameter integer LINE_PIXELS     = 640,
    parameter integer FRAME_LINES     = 480,
    parameter integer VSYNC_CYCLES    = 100,
    parameter integer HBLANK_CYCLES   = 144,
    parameter integer WATCHDOG_CYCLES = 625_000   // ~25 ms at 25 MHz clk_pix
) (
    input  wire        clk,            // 25 MHz pixel clock (clk_pix)
    input  wire        rst,            // Synchronous reset

    // AXI4-Stream Slave Interface
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output reg         s_axis_tready,
    input  wire        s_axis_tlast,

    // Configuration
    input  wire        gray_input,     // 1 = 640 bytes/line, 0 = 1280 bytes/line

    // Emulated OV7670 Output Interface
    output wire        emu_pclk,
    output reg         emu_href,
    output reg         emu_vsync,
    output reg  [7:0]  emu_data,

    // Status
    output reg         frame_active,
    output reg  [9:0]  current_line,
    output reg         frame_done
);

    assign emu_pclk = clk;

    //------------------------------------------------------------------------
    // Line buffer: 640 words x 16-bit (stores one full line of 640 pixels)
    // Inferred as a single 18K Block RAM tile (zero LUT overhead!)
    //------------------------------------------------------------------------
    (* ram_style = "block" *) reg [15:0] line_mem [0:LINE_PIXELS-1];

    // FSM States
    localparam ST_IDLE        = 3'd0;
    localparam ST_VSYNC_PULSE = 3'd1;
    localparam ST_VBLANK      = 3'd2;
    localparam ST_RX_LINE     = 3'd3;
    localparam ST_BURST_PREP  = 3'd4;
    localparam ST_BURST_LINE  = 3'd5;
    localparam ST_HBLANK      = 3'd6;
    localparam ST_FRAME_DONE  = 3'd7;

    reg [2:0]  state = ST_IDLE;

    // Line and pixel counters
    reg [9:0]  rx_pix_cnt   = 10'd0;   // 0..639
    reg        rx_byte_sel  = 1'b0;    // 0 = byte 0, 1 = byte 1 (RGB565)
    reg [7:0]  rx_byte0_buf = 8'd0;

    reg [9:0]  tx_pix_cnt   = 10'd0;   // 0..639
    reg        tx_byte_sel  = 1'b0;    // 0 = byte 0, 1 = byte 1
    reg [15:0] tx_word_buf  = 16'd0;

    reg [9:0]  line_cnt     = 10'd0;   // 0..479
    reg [15:0] timer_cnt    = 16'd0;

    // 4-byte magic word detector: 0xAA55AA55
    reg [31:0] sync_shift   = 32'd0;

    // Stream watchdog counter (~25 ms timeout to reset to ST_IDLE if stream stops mid-frame)
    reg [23:0] watchdog_cnt = 24'd0;

    always @(posedge clk) begin
        if (rst) begin
            state         <= ST_IDLE;
            s_axis_tready <= 1'b0;
            emu_href      <= 1'b0;
            emu_vsync     <= 1'b0;
            emu_data      <= 8'd0;
            frame_active  <= 1'b0;
            current_line  <= 10'd0;
            frame_done    <= 1'b0;
            rx_pix_cnt    <= 10'd0;
            rx_byte_sel   <= 1'b0;
            rx_byte0_buf  <= 8'd0;
            tx_pix_cnt    <= 10'd0;
            tx_byte_sel   <= 1'b0;
            tx_word_buf   <= 16'd0;
            line_cnt      <= 10'd0;
            timer_cnt     <= 16'd0;
            sync_shift    <= 32'd0;
            watchdog_cnt  <= 24'd0;
        end else if (state != ST_IDLE && watchdog_cnt >= WATCHDOG_CYCLES[23:0]) begin
            // Watchdog recovery: return cleanly to IDLE if packets halt mid-frame
            state         <= ST_IDLE;
            s_axis_tready <= 1'b1;
            emu_href      <= 1'b0;
            emu_vsync     <= 1'b0;
            emu_data      <= 8'd0;
            frame_active  <= 1'b0;
            current_line  <= 10'd0;
            frame_done    <= 1'b0;
            rx_pix_cnt    <= 10'd0;
            rx_byte_sel   <= 1'b0;
            line_cnt      <= 10'd0;
            sync_shift    <= 32'd0;
            watchdog_cnt  <= 24'd0;
        end else begin
            if (state == ST_IDLE) begin
                watchdog_cnt <= 24'd0;
            end else if (s_axis_tvalid && s_axis_tready) begin
                watchdog_cnt <= 24'd0;
            end else begin
                watchdog_cnt <= watchdog_cnt + 24'd1;
            end

            frame_done <= 1'b0;

            case (state)

            //----------------------------------------------------------------
            // ST_IDLE: Wait for 4-byte magic sync word (0xAA55AA55)
            //----------------------------------------------------------------
            ST_IDLE: begin
                s_axis_tready <= 1'b1;
                emu_href      <= 1'b0;
                emu_vsync     <= 1'b0;
                emu_data      <= 8'd0;
                frame_active  <= 1'b0;
                rx_pix_cnt    <= 10'd0;
                rx_byte_sel   <= 1'b0;
                line_cnt      <= 10'd0;

                if (s_axis_tvalid && s_axis_tready) begin
                    sync_shift <= {sync_shift[23:0], s_axis_tdata};
                    if ({sync_shift[23:0], s_axis_tdata} == 32'hAA_55_AA_55) begin
                        state         <= ST_VSYNC_PULSE;
                        timer_cnt     <= VSYNC_CYCLES[15:0];
                        s_axis_tready <= 1'b0;
                        sync_shift    <= 32'd0;
                    end
                end
            end

            //----------------------------------------------------------------
            // ST_VSYNC_PULSE: Assert VSYNC high for frame start
            //----------------------------------------------------------------
            ST_VSYNC_PULSE: begin
                emu_vsync    <= 1'b1;
                frame_active <= 1'b1;
                if (timer_cnt == 16'd0) begin
                    emu_vsync <= 1'b0;
                    timer_cnt <= 16'd100; // Vertical back porch
                    state     <= ST_VBLANK;
                end else begin
                    timer_cnt <= timer_cnt - 16'd1;
                end
            end

            //----------------------------------------------------------------
            // ST_VBLANK: Gap between VSYNC falling edge and first line
            //----------------------------------------------------------------
            ST_VBLANK: begin
                if (timer_cnt == 16'd0) begin
                    state         <= ST_RX_LINE;
                    s_axis_tready <= 1'b1;
                    rx_pix_cnt    <= 10'd0;
                    rx_byte_sel   <= 1'b0;
                end else begin
                    timer_cnt <= timer_cnt - 16'd1;
                end
            end

            //----------------------------------------------------------------
            // ST_RX_LINE: Receive 640 pixels into Block RAM
            //----------------------------------------------------------------
            ST_RX_LINE: begin
                s_axis_tready <= 1'b1;
                current_line  <= line_cnt;

                if (s_axis_tvalid && s_axis_tready) begin
                    if (gray_input) begin
                        // Grayscale: 1 byte Y per pixel, store {Y, 8'h80}
                        line_mem[rx_pix_cnt] <= {s_axis_tdata, 8'h80};
                        if (rx_pix_cnt + 10'd1 == LINE_PIXELS[9:0]) begin
                            s_axis_tready <= 1'b0;
                            rx_pix_cnt    <= 10'd0;
                            state         <= ST_BURST_PREP;
                        end else begin
                            rx_pix_cnt <= rx_pix_cnt + 10'd1;
                        end
                    end else begin
                        // RGB565: 2 bytes per pixel
                        if (!rx_byte_sel) begin
                            rx_byte0_buf <= s_axis_tdata;
                            rx_byte_sel  <= 1'b1;
                        end else begin
                            line_mem[rx_pix_cnt] <= {rx_byte0_buf, s_axis_tdata};
                            rx_byte_sel          <= 1'b0;
                            if (rx_pix_cnt + 10'd1 == LINE_PIXELS[9:0]) begin
                                s_axis_tready <= 1'b0;
                                rx_pix_cnt    <= 10'd0;
                                state         <= ST_BURST_PREP;
                            end else begin
                                rx_pix_cnt <= rx_pix_cnt + 10'd1;
                            end
                        end
                    end
                end
            end

            //----------------------------------------------------------------
            // ST_BURST_PREP: Pipeline read of pixel 0 from Block RAM (1 cycle)
            //----------------------------------------------------------------
            ST_BURST_PREP: begin
                tx_word_buf <= line_mem[10'd0];
                tx_pix_cnt  <= 10'd1;
                tx_byte_sel <= 1'b0;
                state       <= ST_BURST_LINE;
            end

            //----------------------------------------------------------------
            // ST_BURST_LINE: Stream line at continuous 25 MHz (HREF = 1)
            //----------------------------------------------------------------
            ST_BURST_LINE: begin
                emu_href <= 1'b1;

                if (!tx_byte_sel) begin
                    // Byte 0: upper 8 bits (high byte of pixel)
                    emu_data    <= tx_word_buf[15:8];
                    tx_byte_sel <= 1'b1;
                end else begin
                    // Byte 1: lower 8 bits (low byte of pixel)
                    emu_data    <= tx_word_buf[7:0];
                    tx_byte_sel <= 1'b0;

                    if (tx_pix_cnt == LINE_PIXELS[9:0]) begin
                        // All 640 pixels (1280 bytes) finished!
                        state     <= ST_HBLANK;
                        timer_cnt <= HBLANK_CYCLES[15:0];
                    end else begin
                        // Fetch next pixel from BRAM
                        tx_word_buf <= line_mem[tx_pix_cnt];
                        tx_pix_cnt  <= tx_pix_cnt + 10'd1;
                    end
                end
            end

            //----------------------------------------------------------------
            // ST_HBLANK: De-assert HREF for horizontal blanking
            //----------------------------------------------------------------
            ST_HBLANK: begin
                emu_href <= 1'b0;
                emu_data <= 8'd0;

                if (timer_cnt == 16'd0) begin
                    if (line_cnt + 10'd1 == FRAME_LINES[9:0]) begin
                        state <= ST_FRAME_DONE;
                    end else begin
                        line_cnt      <= line_cnt + 10'd1;
                        state         <= ST_RX_LINE;
                        s_axis_tready <= 1'b1;
                        rx_pix_cnt    <= 10'd0;
                        rx_byte_sel   <= 1'b0;
                    end
                end else begin
                    timer_cnt <= timer_cnt - 16'd1;
                end
            end

            //----------------------------------------------------------------
            // ST_FRAME_DONE: One-cycle frame completion pulse
            //----------------------------------------------------------------
            ST_FRAME_DONE: begin
                frame_done   <= 1'b1;
                frame_active <= 1'b0;
                state        <= ST_IDLE;
            end

            default: state <= ST_IDLE;

            endcase
        end
    end

endmodule
