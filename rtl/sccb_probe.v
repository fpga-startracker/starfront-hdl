`timescale 1ns / 1ps

//============================================================================
// Module: sccb_probe
// Description: Camera presence check over SCCB - the milestone that answers
//              "is the OV7670 actually wired up and alive?".
//
//   Sequence, repeated forever so the camera can be plugged in after the
//   bitstream is already running:
//
//     1. hold off for POWERUP_MS after reset (XCLK must be running first)
//     2. write COM7 (0x12) = 0x80          - software reset
//     3. wait RESET_MS
//     4. read  PID  (0x0A)                 - expect 0x76
//     5. read  VER  (0x0B)                 - expect 0x73
//     6. write CLKRC (0x11) = 0x01         - a harmless R/W register
//     7. read  CLKRC (0x11)                - expect 0x01, proves the write path
//     8. write CLKRC (0x11) = 0x80         - restore external clock, no prescale
//     9. hold for HOLD_MS, then go back to step 2
//
//   `cam_id_ok` alone tells you power, wiring, pull-ups and SCCB timing are
//   all good. `cam_rw_ok` additionally proves writes land.
//
//   Once the camera has answered correctly the probe parks and raises
//   `probe_locked`, which is the top level's cue to hand the SCCB bus over to
//   ov7670_init. Until then it keeps retrying, so the camera can be plugged in
//   after the bitstream is already running.
//============================================================================

module sccb_probe #(
    parameter integer CLK_FREQ   = 25_000_000,
    parameter integer POWERUP_MS = 10,
    parameter integer RESET_MS   = 5,
    parameter integer HOLD_MS    = 500
) (
    input  wire        clk,
    input  wire        rst,

    // sccb_master control interface
    output reg         sccb_start,
    output reg         sccb_rw,
    output reg  [7:0]  sccb_sub_addr,
    output reg  [7:0]  sccb_wr_data,
    input  wire [7:0]  sccb_rd_data,
    input  wire        sccb_done,

    // Results
    output reg  [7:0]  cam_pid,
    output reg  [7:0]  cam_ver,
    output reg  [7:0]  cam_readback,
    output reg         cam_id_ok,
    output reg         cam_rw_ok,
    output reg         probe_done,
    output wire        probe_locked,   // camera found; SCCB is free for init

    output wire [3:0]  dbg_state
);

    localparam [7:0] REG_COM7  = 8'h12;
    localparam [7:0] REG_CLKRC = 8'h11;
    localparam [7:0] REG_PID   = 8'h0A;
    localparam [7:0] REG_VER   = 8'h0B;

    localparam [7:0] OV7670_PID = 8'h76;
    localparam [7:0] OV7670_VER = 8'h73;
    localparam [7:0] TEST_VALUE = 8'h01;

    localparam integer T_POWERUP = (CLK_FREQ / 1000) * POWERUP_MS;
    localparam integer T_RESET   = (CLK_FREQ / 1000) * RESET_MS;
    localparam integer T_HOLD    = (CLK_FREQ / 1000) * HOLD_MS;

    localparam S_POWERUP  = 4'd0;
    localparam S_SW_RESET = 4'd1;
    localparam S_RST_WAIT = 4'd2;
    localparam S_RD_PID   = 4'd3;
    localparam S_RD_VER   = 4'd4;
    localparam S_WR_TEST  = 4'd5;
    localparam S_RD_TEST  = 4'd6;
    localparam S_RESTORE  = 4'd7;
    localparam S_EVAL     = 4'd8;
    localparam S_HOLD     = 4'd9;
    localparam S_PARKED   = 4'd10;

    reg [3:0]  state    = S_POWERUP;
    reg        txn_wait = 1'b0;
    reg [24:0] delay    = 25'd0;

    assign dbg_state    = state;
    assign probe_locked = (state == S_PARKED);

    // One place to kick off a transaction, so every step reads the same way
    task issue;
        input       t_rw;
        input [7:0] t_sub;
        input [7:0] t_data;
        begin
            sccb_rw       <= t_rw;
            sccb_sub_addr <= t_sub;
            sccb_wr_data  <= t_data;
            sccb_start    <= 1'b1;
            txn_wait      <= 1'b1;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            state         <= S_POWERUP;
            txn_wait      <= 1'b0;
            delay         <= 25'd0;
            sccb_start    <= 1'b0;
            sccb_rw       <= 1'b0;
            sccb_sub_addr <= 8'd0;
            sccb_wr_data  <= 8'd0;
            cam_pid       <= 8'd0;
            cam_ver       <= 8'd0;
            cam_readback  <= 8'd0;
            cam_id_ok     <= 1'b0;
            cam_rw_ok     <= 1'b0;
            probe_done    <= 1'b0;
        end else begin
            sccb_start <= 1'b0;

            case (state)

            S_POWERUP: begin
                if (delay == T_POWERUP[24:0]) begin
                    delay <= 25'd0;
                    state <= S_SW_RESET;
                end else begin
                    delay <= delay + 25'd1;
                end
            end

            S_SW_RESET: begin
                if (!txn_wait)          issue(1'b0, REG_COM7, 8'h80);
                else if (sccb_done) begin
                    txn_wait <= 1'b0;
                    state    <= S_RST_WAIT;
                end
            end

            S_RST_WAIT: begin
                if (delay == T_RESET[24:0]) begin
                    delay <= 25'd0;
                    state <= S_RD_PID;
                end else begin
                    delay <= delay + 25'd1;
                end
            end

            S_RD_PID: begin
                if (!txn_wait)          issue(1'b1, REG_PID, 8'h00);
                else if (sccb_done) begin
                    cam_pid  <= sccb_rd_data;
                    txn_wait <= 1'b0;
                    state    <= S_RD_VER;
                end
            end

            S_RD_VER: begin
                if (!txn_wait)          issue(1'b1, REG_VER, 8'h00);
                else if (sccb_done) begin
                    cam_ver  <= sccb_rd_data;
                    txn_wait <= 1'b0;
                    state    <= S_WR_TEST;
                end
            end

            S_WR_TEST: begin
                if (!txn_wait)          issue(1'b0, REG_CLKRC, TEST_VALUE);
                else if (sccb_done) begin
                    txn_wait <= 1'b0;
                    state    <= S_RD_TEST;
                end
            end

            S_RD_TEST: begin
                if (!txn_wait)          issue(1'b1, REG_CLKRC, 8'h00);
                else if (sccb_done) begin
                    cam_readback <= sccb_rd_data;
                    txn_wait     <= 1'b0;
                    state        <= S_RESTORE;
                end
            end

            S_RESTORE: begin
                if (!txn_wait)          issue(1'b0, REG_CLKRC, 8'h80);
                else if (sccb_done) begin
                    txn_wait <= 1'b0;
                    state    <= S_EVAL;
                end
            end

            S_EVAL: begin
                cam_id_ok  <= (cam_pid == OV7670_PID) && (cam_ver == OV7670_VER);
                cam_rw_ok  <= (cam_readback == TEST_VALUE);
                probe_done <= 1'b1;
                state      <= S_HOLD;
            end

            S_HOLD: begin
                if (cam_id_ok) begin
                    // Camera answered - stop touching the bus so ov7670_init
                    // can have it, and stay out of the way from here on.
                    delay <= 25'd0;
                    state <= S_PARKED;
                end else if (delay == T_HOLD[24:0]) begin
                    delay <= 25'd0;
                    state <= S_SW_RESET;
                end else begin
                    delay <= delay + 25'd1;
                end
            end

            S_PARKED: begin
                // Terminal. A board reset is what starts the probe again.
            end

            default: state <= S_POWERUP;

            endcase
        end
    end

endmodule
