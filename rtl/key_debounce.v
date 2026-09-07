`timescale 1ns / 1ps

//============================================================================
// Module: key_debounce
// Description: Synchronises a mechanical key into `clk` and holds off changes
//              until the new level has been stable for STABLE_MS.
//
//   KEY3 restarts the whole 94-register camera init, which takes about a
//   tenth of a second. Without debouncing, one press would queue several
//   restarts and the display would flicker for half a second.
//============================================================================

module key_debounce #(
    parameter integer CLK_FREQ  = 25_000_000,
    parameter integer STABLE_MS = 10
) (
    input  wire clk,
    input  wire key_raw,
    output reg  key_stable
);

    localparam integer TICKS = (CLK_FREQ / 1000) * STABLE_MS;

    wire key_sync;
    cdc_sync #(.WIDTH(1)) u_sync (.clk(clk), .din(key_raw), .dout(key_sync));

    reg [24:0] cnt = 25'd0;

    initial key_stable = 1'b0;

    always @(posedge clk) begin
        if (key_sync == key_stable) begin
            cnt <= 25'd0;
        end else if (cnt == TICKS[24:0]) begin
            key_stable <= key_sync;
            cnt        <= 25'd0;
        end else begin
            cnt <= cnt + 25'd1;
        end
    end

endmodule
