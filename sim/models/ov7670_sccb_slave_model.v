`timescale 1ns / 1ps

//============================================================================
// Module: ov7670_sccb_slave_model
// Description: SCCB slave model of an OV7670, supporting both the 3-phase
//              write and the 2-phase-write / 2-phase-read pair.
//
//   Extended from the write-only model used on the Basys 3 project: that one
//   could not exercise the read path, which is exactly the path this project
//   depends on for camera bring-up.
//
//   Bus handling mirrors real SCCB: the slave only ever pulls SIO_D low and
//   releases it otherwise, so the testbench pull-up supplies the ones. The
//   ninth bit of a written byte is the "don't care" slot; the model drives it
//   low the way an OV7670 does.
//
//   Blocking assignments are used throughout - this is a behavioural model,
//   and the ordering inside each edge handler matters.
//
// SIMULATION ONLY.
//============================================================================

module ov7670_sccb_slave_model #(
    parameter [7:0] DEV_ADDR_W = 8'h42,
    parameter [7:0] DEV_ADDR_R = 8'h43
) (
    input  wire       sio_c,
    inout  wire       sio_d,

    // Observation ports, so the testbench does not need to reach into arrays
    output reg  [7:0] dbg_last_sub  = 8'h00,
    output reg  [7:0] dbg_last_data = 8'h00,
    output reg  [7:0] dbg_id_byte   = 8'h00
);

    reg drive_low = 1'b0;
    assign sio_d = drive_low ? 1'b0 : 1'bz;

    reg [7:0] regmap [0:255];

    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1) regmap[i] = 8'h00;
        regmap[8'h0A] = 8'h76;   // PID
        regmap[8'h0B] = 8'h73;   // VER
        regmap[8'h1C] = 8'h7F;   // MIDH
        regmap[8'h1D] = 8'hA2;   // MIDL
        regmap[8'h11] = 8'h80;   // CLKRC power-on default
    end

    reg       active   = 1'b0;
    reg       new_txn  = 1'b0;
    reg [3:0] slot     = 4'd0;   // 0..8, slot 8 is the don't-care / NA bit
    reg [1:0] byte_num = 2'd0;
    reg [7:0] rx_sr    = 8'd0;
    reg [7:0] tx_sr    = 8'd0;
    reg [7:0] sub_ptr  = 8'd0;
    reg       is_read  = 1'b0;
    reg       tx_mode  = 1'b0;

    // START: SIO_D falls while SIO_C is high
    always @(negedge sio_d) begin
        if (sio_c === 1'b1) begin
            active   = 1'b1;
            new_txn  = 1'b1;
            slot     = 4'd0;
            byte_num = 2'd0;
            rx_sr    = 8'd0;
            is_read  = 1'b0;
            tx_mode  = 1'b0;
            drive_low = 1'b0;
        end
    end

    // STOP: SIO_D rises while SIO_C is high
    always @(posedge sio_d) begin
        if (sio_c === 1'b1) begin
            active    = 1'b0;
            tx_mode   = 1'b0;
            drive_low = 1'b0;
        end
    end

    // Master drives / slave samples in the middle of the SIO_C high phase
    always @(posedge sio_c) begin
        if (active && !tx_mode && (slot < 4'd8))
            rx_sr = {rx_sr[6:0], (sio_d === 1'b1)};
    end

    // Each falling edge opens the next bit slot
    always @(negedge sio_c) begin
        if (active) begin
            if (new_txn) begin
                new_txn = 1'b0;            // this edge opens slot 0
            end else if (slot == 4'd8) begin
                // The don't-care / NA slot has ended: commit the byte
                if (!tx_mode) begin
                    case (byte_num)
                        2'd0: begin
                            dbg_id_byte = rx_sr;
                            is_read     = (rx_sr == DEV_ADDR_R);
                        end
                        2'd1: sub_ptr = rx_sr;
                        default: begin
                            regmap[sub_ptr] = rx_sr;
                            dbg_last_sub    = sub_ptr;
                            dbg_last_data   = rx_sr;
                        end
                    endcase
                end

                byte_num = byte_num + 2'd1;
                slot     = 4'd0;
                rx_sr    = 8'd0;

                // Exactly one byte follows the read device address, and it
                // comes from us. Anything later must leave the bus alone, or
                // the master's STOP would never produce a rising edge.
                tx_mode = is_read && (byte_num == 2'd1);
                if (tx_mode) tx_sr = regmap[sub_ptr];
            end else begin
                slot = slot + 4'd1;
            end

            // Drive the bus for the slot just opened
            if (tx_mode && (slot < 4'd8))
                drive_low = ~tx_sr[4'd7 - slot];   // MSB first, 0 = pull low
            else if (!tx_mode && (slot == 4'd8))
                drive_low = 1'b1;                  // don't-care slot, driven low
            else
                drive_low = 1'b0;                  // released
        end
    end

endmodule
