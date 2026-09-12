`timescale 1ns / 1ps

//============================================================================
// Module: ov7670_init
// Description: Sequencer that reads {addr, data} pairs from ov7670_registers
//              ROM and writes them to the camera via sccb_master.
//
// Sequence:
//   1. Wait for power-up (configurable delay)
//   2. Send soft reset (index 0: COM7=0x80)
//   3. Wait >= 1 ms for reset settling
//   4. Send remaining registers (index 1..N-1)
//   5. Assert init_done when complete
//
// The module handles:
//   - Detecting sentinel (0xFFFF) to stop
//   - Waiting for sccb_master 'done' between writes
//   - Inter-register delay (tS:REG not strictly needed per-reg,
//     but small delay improves reliability)
//============================================================================

module ov7670_init
#(
    parameter integer CLK_FREQ = 25_000_000     // for the delay constants
)
(
    input  wire        clk,
    input  wire        rst,

    // Changing any of these re-runs the whole table with the new setting, so
    // the test pattern, the window position and the star-field profile can be
    // tuned on the bench rather than costing a rebuild each time.
    input  wire        color_bar,
    input  wire [1:0]  hstart_sel,
    input  wire        astro,
    input  wire [1:0]  preset,

    // Status
    output wire        init_done,      // High when all registers written

    // SCCB master interface
    output wire        sccb_start,     // Pulse to begin SCCB write
    output wire [7:0]  sccb_sub_addr,  // Register address
    output wire [7:0]  sccb_wr_data,   // Register data
    input  wire        sccb_done       // SCCB write complete
);

    //------------------------------------------------------------------------
    // Delay constants (in clock cycles)
    //------------------------------------------------------------------------
`ifdef SIM
    // Short delays for simulation
    localparam PWRUP_DELAY = 32'd100;
    localparam RESET_DELAY = 32'd100;
    localparam REG_DELAY   = 32'd10;
`else
    // Production delays
    localparam PWRUP_DELAY = CLK_FREQ / 100;      // 10 ms
    localparam RESET_DELAY = CLK_FREQ / 1000;     // 1 ms
    localparam REG_DELAY   = CLK_FREQ / 5000;     // 200 us
`endif

    // Sentinel value from ov7670_registers
    localparam SENTINEL    = 16'hFF_FF;

    //------------------------------------------------------------------------
    // States
    //------------------------------------------------------------------------
    localparam INIT_PWRUP      = 3'd0;  // Power-up wait
    localparam INIT_SEND       = 3'd1;  // Assert sccb_start
    localparam INIT_WAIT_DONE  = 3'd2;  // Wait for sccb_done
    localparam INIT_REG_DELAY  = 3'd3;  // Inter-register delay
    localparam INIT_NEXT       = 3'd4;  // Advance to next register
    localparam INIT_DONE       = 3'd5;  // All registers written

    reg [2:0] state = INIT_PWRUP;

    //------------------------------------------------------------------------
    // Working registers
    //------------------------------------------------------------------------
    reg [7:0]  reg_index     = 8'd0;    // Current ROM index
    reg [31:0] delay_cnt     = 32'd0;   // Delay counter
    reg        sccb_start_reg = 1'b0;
    reg        init_done_reg  = 1'b0;

    //------------------------------------------------------------------------
    // ROM instance
    //------------------------------------------------------------------------
    wire [15:0] rom_data;

    ov7670_registers u_regs (
        .index      ( reg_index  ),
        .color_bar  ( color_bar  ),
        .hstart_sel ( hstart_sel ),
        .astro      ( astro      ),
        .preset     ( preset     ),
        .data       ( rom_data   )
    );

    //------------------------------------------------------------------------
    // Latch a change of color_bar until the sequencer is idle enough to act on
    // it - the change is a single cycle and the FSM is usually mid-transaction.
    //------------------------------------------------------------------------
    wire [5:0] cfg = {preset, astro, hstart_sel, color_bar};

    reg [5:0] cfg_d     = 6'd0;
    reg       cfg_dirty = 1'b0;
    wire cfg_changed = (cfg != cfg_d);

    //------------------------------------------------------------------------
    // Output assignments
    //------------------------------------------------------------------------
    assign sccb_start    = sccb_start_reg;
    assign sccb_sub_addr = rom_data[15:8];
    assign sccb_wr_data  = rom_data[7:0];
    assign init_done     = init_done_reg;

    //------------------------------------------------------------------------
    // State machine
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state          <= INIT_PWRUP;
            reg_index      <= 8'd0;
            delay_cnt      <= PWRUP_DELAY;
            sccb_start_reg <= 1'b0;
            init_done_reg  <= 1'b0;
            cfg_d          <= cfg;
            cfg_dirty      <= 1'b0;
        end else begin
            cfg_d <= cfg;
            sccb_start_reg <= 1'b0;  // Default: no start pulse

            case (state)

            //--------------------------------------------------------------
            // Wait for power-up / reset delay
            //--------------------------------------------------------------
            INIT_PWRUP: begin
                if (delay_cnt == 32'd0) begin
                    state <= INIT_SEND;
                end else begin
                    delay_cnt <= delay_cnt - 32'd1;
                end
            end

            //--------------------------------------------------------------
            // Send current register via SCCB
            //--------------------------------------------------------------
            INIT_SEND: begin
                // Check for sentinel (end of config)
                if (rom_data == SENTINEL) begin
                    state         <= INIT_DONE;
                    init_done_reg <= 1'b1;
                end else begin
                    sccb_start_reg <= 1'b1;  // Pulse start
                    state          <= INIT_WAIT_DONE;
                end
            end

            //--------------------------------------------------------------
            // Wait for SCCB write to complete
            //--------------------------------------------------------------
            INIT_WAIT_DONE: begin
                if (sccb_done) begin
                    // After soft reset (index 0), use longer delay
                    if (reg_index == 8'd0) begin
                        delay_cnt <= RESET_DELAY;
                    end else begin
                        delay_cnt <= REG_DELAY;
                    end
                    state <= INIT_REG_DELAY;
                end
            end

            //--------------------------------------------------------------
            // Wait between registers
            //--------------------------------------------------------------
            INIT_REG_DELAY: begin
                if (delay_cnt == 32'd0) begin
                    state <= INIT_NEXT;
                end else begin
                    delay_cnt <= delay_cnt - 32'd1;
                end
            end

            //--------------------------------------------------------------
            // Advance to next register
            //--------------------------------------------------------------
            INIT_NEXT: begin
                reg_index <= reg_index + 8'd1;
                state     <= INIT_SEND;
            end

            //--------------------------------------------------------------
            // Done: all registers written
            //--------------------------------------------------------------
            INIT_DONE: begin
                init_done_reg <= 1'b1;
                if (cfg_dirty) begin
                    // Re-run the table, including the soft reset at index 0
                    cfg_dirty     <= 1'b0;
                    reg_index     <= 8'd0;
                    init_done_reg <= 1'b0;
                    delay_cnt     <= RESET_DELAY;
                    state         <= INIT_PWRUP;
                end
            end

            default: state <= INIT_PWRUP;

            endcase

            // After the case, so a change landing on the same cycle as the
            // clear above is remembered rather than lost.
            if (cfg_changed)
                cfg_dirty <= 1'b1;
        end
    end

endmodule
