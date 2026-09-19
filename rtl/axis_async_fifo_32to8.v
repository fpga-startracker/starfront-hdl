`timescale 1ns / 1ps

//============================================================================
// Module: axis_async_fifo_32to8
// Description: Dual-clock Asynchronous FIFO with 32-to-8 bit stream unpacker.
//
//   Bridges the 32-bit AXI4-Stream TX port from the Zynq PS (operating at
//   50 MHz, FCLK_CLK0) into the 8-bit stream required by axis_cam_bridge
//   (operating at 25 MHz, clk_pix).
//
//   Architecture:
//     1. Dual-Clock Asynchronous FIFO (32 words deep x 33 bits wide):
//        Stores 32-bit TDATA + 1-bit TLAST across the clock domain boundary
//        using Gray-coded read/write pointers and 2-stage synchronizers.
//        Full/empty flags provide seamless backpressure via s_axis_tready.
//     2. 32-to-8 Stream Serializer (Read domain, 25 MHz clk_pix):
//        Pops 32-bit words {B3, B2, B1, B0} and transmits them byte-by-byte
//        in Little-Endian order (B0 -> B1 -> B2 -> B3) into axis_cam_bridge.
//        Only when the 4th byte is acknowledged by m_axis_tready is the next
//        word popped from the FIFO.
//============================================================================

module axis_async_fifo_32to8 #(
    parameter integer ADDR_WIDTH = 5   // Depth = 32 words (128 bytes)
) (
    // Write side: PS AXI4-Stream (wr_clk, e.g. 50 MHz FCLK_CLK0)
    input  wire        wr_clk,
    input  wire        wr_rst,
    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // Read side: axis_cam_bridge (rd_clk, e.g. 25 MHz clk_pix)
    input  wire        rd_clk,
    input  wire        rd_rst,
    output reg  [7:0]  m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast
);

    localparam integer FIFO_DEPTH = 1 << ADDR_WIDTH;

    // Dual-port distributed RAM: [32] = tlast, [31:0] = tdata
    reg [32:0] mem [0:FIFO_DEPTH-1];

    //------------------------------------------------------------------------
    // Write Domain (wr_clk)
    //------------------------------------------------------------------------
    reg [ADDR_WIDTH:0] wr_ptr_bin   = {(ADDR_WIDTH+1){1'b0}};
    reg [ADDR_WIDTH:0] wr_ptr_gray  = {(ADDR_WIDTH+1){1'b0}};

    // Synchronize read pointer into write domain
    (* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] rd_ptr_gray_sync1 = {(ADDR_WIDTH+1){1'b0}};
    (* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] rd_ptr_gray_sync2 = {(ADDR_WIDTH+1){1'b0}};

    always @(posedge wr_clk) begin
        if (wr_rst) begin
            rd_ptr_gray_sync1 <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray_sync2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            rd_ptr_gray_sync1 <= rd_ptr_gray;
            rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
        end
    end

    // Full condition: MSB and second MSB differ, all other bits match
    wire fifo_full = (wr_ptr_gray == {~rd_ptr_gray_sync2[ADDR_WIDTH:ADDR_WIDTH-1],
                                       rd_ptr_gray_sync2[ADDR_WIDTH-2:0]});

    assign s_axis_tready = ~fifo_full;
    wire fifo_wr_en      = s_axis_tvalid & s_axis_tready;

    always @(posedge wr_clk) begin
        if (wr_rst) begin
            wr_ptr_bin  <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
        end else if (fifo_wr_en) begin
            mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= {s_axis_tlast, s_axis_tdata};
            wr_ptr_bin  <= wr_ptr_bin + 1'b1;
            wr_ptr_gray <= ((wr_ptr_bin + 1'b1) >> 1) ^ (wr_ptr_bin + 1'b1);
        end
    end

    //------------------------------------------------------------------------
    // Read Domain (rd_clk)
    //------------------------------------------------------------------------
    reg [ADDR_WIDTH:0] rd_ptr_bin   = {(ADDR_WIDTH+1){1'b0}};
    reg [ADDR_WIDTH:0] rd_ptr_gray  = {(ADDR_WIDTH+1){1'b0}};

    // Synchronize write pointer into read domain
    (* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] wr_ptr_gray_sync1 = {(ADDR_WIDTH+1){1'b0}};
    (* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] wr_ptr_gray_sync2 = {(ADDR_WIDTH+1){1'b0}};

    always @(posedge rd_clk) begin
        if (rd_rst) begin
            wr_ptr_gray_sync1 <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray_sync2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end

    wire fifo_empty = (rd_ptr_gray == wr_ptr_gray_sync2);

    //------------------------------------------------------------------------
    // 32-to-8 Unpacker FSM (rd_clk)
    //------------------------------------------------------------------------
    reg [1:0]  byte_idx  = 2'd0;
    reg [31:0] hold_data = 32'd0;
    reg        hold_last = 1'b0;
    reg        have_word = 1'b0;

    always @(posedge rd_clk) begin
        if (rd_rst) begin
            rd_ptr_bin    <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray   <= {(ADDR_WIDTH+1){1'b0}};
            byte_idx      <= 2'd0;
            hold_data     <= 32'd0;
            hold_last     <= 1'b0;
            have_word     <= 1'b0;
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= 8'd0;
            m_axis_tlast  <= 1'b0;
        end else begin
            if (!have_word) begin
                // Fetch new 32-bit word from FIFO
                if (!fifo_empty) begin
                    hold_data     <= mem[rd_ptr_bin[ADDR_WIDTH-1:0]][31:0];
                    hold_last     <= mem[rd_ptr_bin[ADDR_WIDTH-1:0]][32];
                    rd_ptr_bin    <= rd_ptr_bin + 1'b1;
                    rd_ptr_gray   <= ((rd_ptr_bin + 1'b1) >> 1) ^ (rd_ptr_bin + 1'b1);
                    have_word     <= 1'b1;
                    byte_idx      <= 2'd0;
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= mem[rd_ptr_bin[ADDR_WIDTH-1:0]][7:0]; // Byte 0
                    m_axis_tlast  <= 1'b0;
                end else begin
                    m_axis_tvalid <= 1'b0;
                end
            end else begin
                // A word is currently loaded and being serialized
                m_axis_tvalid <= 1'b1;

                if (m_axis_tready) begin
                    if (byte_idx == 2'd0) begin
                        byte_idx     <= 2'd1;
                        m_axis_tdata <= hold_data[15:8];  // Byte 1
                        m_axis_tlast <= 1'b0;
                    end else if (byte_idx == 2'd1) begin
                        byte_idx     <= 2'd2;
                        m_axis_tdata <= hold_data[23:16]; // Byte 2
                        m_axis_tlast <= 1'b0;
                    end else if (byte_idx == 2'd2) begin
                        byte_idx     <= 2'd3;
                        m_axis_tdata <= hold_data[31:24]; // Byte 3
                        m_axis_tlast <= hold_last;
                    end else begin
                        // Byte 3 acknowledged! Check if FIFO has another word ready immediately
                        if (!fifo_empty) begin
                            hold_data     <= mem[rd_ptr_bin[ADDR_WIDTH-1:0]][31:0];
                            hold_last     <= mem[rd_ptr_bin[ADDR_WIDTH-1:0]][32];
                            rd_ptr_bin    <= rd_ptr_bin + 1'b1;
                            rd_ptr_gray   <= ((rd_ptr_bin + 1'b1) >> 1) ^ (rd_ptr_bin + 1'b1);
                            byte_idx      <= 2'd0;
                            m_axis_tvalid <= 1'b1;
                            m_axis_tdata  <= mem[rd_ptr_bin[ADDR_WIDTH-1:0]][7:0];
                            m_axis_tlast  <= 1'b0;
                        end else begin
                            have_word     <= 1'b0;
                            m_axis_tvalid <= 1'b0;
                            byte_idx      <= 2'd0;
                        end
                    end
                end
            end
        end
    end

endmodule
