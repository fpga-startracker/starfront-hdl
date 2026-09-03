`timescale 1ns / 1ps

//============================================================================
// Module: cdc_sync
// Description: Multi-stage flip-flop synchroniser for crossing a signal into
//              the `clk` domain. Use only for signals that are either single
//              bit or whose bits may be sampled independently (e.g. a Gray
//              coded counter, or a slow-moving status bus).
//
// Note: a plain binary counter crossed through this synchroniser may be
//       sampled mid-update. Callers that need an exact value must either
//       Gray code it or hold it stable across the crossing.
//============================================================================

module cdc_sync #(
    parameter integer WIDTH  = 1,
    parameter integer STAGES = 2
) (
    input  wire             clk,
    input  wire [WIDTH-1:0] din,
    output wire [WIDTH-1:0] dout
);

    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync_pipe [0:STAGES-1];

    integer i;

    initial begin
        for (i = 0; i < STAGES; i = i + 1)
            sync_pipe[i] = {WIDTH{1'b0}};
    end

    always @(posedge clk) begin
        sync_pipe[0] <= din;
        for (i = 1; i < STAGES; i = i + 1)
            sync_pipe[i] <= sync_pipe[i-1];
    end

    assign dout = sync_pipe[STAGES-1];

endmodule
