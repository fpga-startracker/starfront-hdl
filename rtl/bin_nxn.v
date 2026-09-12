`timescale 1ns / 1ps

//============================================================================
// Module: bin_nxn
// Description: Streaming N x N pixel binning, N = 2**SHIFT. The paper's
//              preprocessing stage 1 (section 4.1): mean of a square region,
//              which is an adder tree and a shift.
//
//   The paper spends N-1 line buffers holding whole rows so it can present an
//   N x N block to an adder tree. This does the same arithmetic with one
//   accumulator RAM one binned-row wide, by splitting the sum along its axes:
//   N pixels across accumulate in a register, and the resulting row sums
//   accumulate down the column in a RAM indexed by the binned column. For
//   1024 wide and N = 4 that is 256 words against three 1024-byte lines - a
//   twelfth of the memory, and the same result to the bit.
//
//   On the DUST display images the operation is exactly invertible. Each
//   sensor pixel was written to the screen as a solid 4 x 4 block, so the mean
//   of a block is the block's own value: binning recovers the 256x256 sensor
//   grid with no loss at all. That is what lets the frame store here hold
//   256x256 and still feed the detector the full 1024x1024 image - the replay
//   repeats each stored pixel four times per axis and this puts it back.
//
// Clock domain: single, whatever the pixel stream runs in.
//============================================================================

module bin_nxn #(
    parameter integer SHIFT = 2,       // N = 2**SHIFT
    parameter integer IN_W  = 1024
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        in_valid,
    input  wire [9:0]  in_x,
    input  wire [9:0]  in_y,
    input  wire [7:0]  in_pix,

    output reg         out_valid,
    output reg  [7:0]  out_x,
    output reg  [7:0]  out_y,
    output reg  [7:0]  out_pix
);

    localparam integer OUT_W = IN_W >> SHIFT;
    localparam integer HW    = 8 + SHIFT;        // one row of N pixels
    localparam integer VW    = 8 + 2 * SHIFT;    // the whole N x N block

    //------------------------------------------------------------------------
    // Across: N pixels into one row sum
    //------------------------------------------------------------------------
    wire h_first = (in_x[SHIFT-1:0] == {SHIFT{1'b0}});
    wire h_last  = (in_x[SHIFT-1:0] == {SHIFT{1'b1}});

    reg  [HW-1:0] hacc = {HW{1'b0}};
    wire [HW-1:0] hsum = (h_first ? {HW{1'b0}} : hacc) + {{SHIFT{1'b0}}, in_pix};

    always @(posedge clk) begin
        if (rst)          hacc <= {HW{1'b0}};
        else if (in_valid) hacc <= hsum;
    end

    //------------------------------------------------------------------------
    // Down: N row sums into one block sum, one accumulator per binned column
    //------------------------------------------------------------------------
    (* ram_style = "distributed" *) reg [VW-1:0] vacc [0:OUT_W-1];

    integer i;
    initial begin
        for (i = 0; i < OUT_W; i = i + 1)
            vacc[i] = {VW{1'b0}};
    end

    wire [7:0]    bx      = in_x[9:SHIFT];
    wire          v_first = (in_y[SHIFT-1:0] == {SHIFT{1'b0}});
    wire          v_last  = (in_y[SHIFT-1:0] == {SHIFT{1'b1}});
    wire [VW-1:0] vprev   = vacc[bx];
    wire [VW-1:0] vsum    = (v_first ? {VW{1'b0}} : vprev) + {{SHIFT{1'b0}}, hsum};

    always @(posedge clk) begin
        if (in_valid && h_last)
            vacc[bx] <= vsum;
    end

    //------------------------------------------------------------------------
    // The mean is the block sum shifted down by 2*SHIFT, truncated. The model
    // truncates too; rounding here would be a free half-LSB but it would also
    // be a difference between the two, and there is nothing downstream that
    // an eighth of a code value changes.
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
        end else begin
            out_valid <= in_valid && h_last && v_last;
            out_x     <= bx;
            out_y     <= in_y[9:SHIFT];
            out_pix   <= vsum[VW-1 -: 8];
        end
    end

endmodule
