`timescale 1ns / 1ps

//============================================================================
// Module: cg_engine
// Description: Grows one cluster inside a captured RoI and returns its centre
//              of gravity to FRAC fractional bits. The paper's sections 4.2
//              (clustering) and 4.4 (centre of gravity), in one state machine.
//
//   The cluster arrives already grown - region_grow.v does that
//   combinationally in the cycle that captures it - so what is left here is
//   the paper's centre of gravity, section 4.4.
//
//   The sums are taken one column per cycle rather than all at once. A fully
//   parallel adder tree over 81 twelve-bit weights is several thousand LUTs
//   for a result the design needs at most a few dozen times per frame; walking
//   the columns needs one column's worth of adders and WIN cycles. With 65536
//   pixel slots in a frame and a whole cluster costing 28 cycles, the engine
//   is idle more than 99% of the time even with the list full.
//
//   Word lengths follow the paper's section 3.3: coordinates are relative to
//   the window's top left corner, so they need four bits rather than eight and
//   every product downstream is narrower. The absolute position is added back
//   at the very end, where it is free.
//
//   CG_HALF selects what carries weight:
//     0        the grown region - a blob centroid, which is what a
//              threshold-and-label front end produces
//     1..HALF  a fixed square of that half-width about the seed, which is what
//              a fixed-window centroider produces
//   Both are computed from the same capture; only the mask differs.
//
//   Accumulation and division are separate stages with their own state, and
//   `busy` covers only the first of them. That is not a throughput
//   optimisation - the engine is idle 99% of the time either way - it is about
//   the window during which a second seed would be dropped for want of
//   anywhere to put it. Accumulating takes WIN + 1 cycles and dividing another
//   FRAC + 6; keeping them together made the door shut for 24 cycles instead
//   of 10, and on a real star field that was three lost stars a frame.
//
// Latency: ceil(WIN/CPC) + FRAC + 7 cycles, 20 for the defaults, of which
//          only the first ceil(WIN/CPC) block a new capture.
//============================================================================

module cg_engine #(
    parameter integer WIN     = 9,
    parameter integer HALF    = 4,
    parameter integer PIXW    = 12,
    parameter integer FRAC    = 8,
    parameter integer CG_HALF = 0,      // 0 = weight the grown region
    parameter integer MIN_NPX = 4,
    parameter integer MIN_SUM = 256
) (
    input  wire        clk,
    input  wire        rst,

    // Capture. Accepted only while busy is low.
    input  wire                       start,
    input  wire [WIN*WIN*PIXW-1:0]    win,     // linear pixels, index r*WIN + c
    input  wire [WIN*WIN-1:0]         reg_in,  // the grown region, from region_grow
    input  wire [PIXW-1:0]            bg,      // linear background under the weights
    input  wire [7:0]                 x0,      // window's top left, absolute
    input  wire [7:0]                 y0,

    output reg         busy,
    output reg         out_valid,
    output reg  [15:0] out_x,       // absolute, FRAC fractional bits
    output reg  [15:0] out_y,
    output reg  [18:0] out_sum,     // background-subtracted flux
    output reg  [6:0]  out_npx,     // pixels in the grown region
    output reg         out_reject   // failed the quality gate; no star emitted
);

    localparam integer NPIX = WIN * WIN;

    localparam [1:0] S_IDLE = 2'd0,
                     S_ACC  = 2'd1,
                     S_HAND = 2'd2;

    reg [1:0]  state = S_IDLE;
    reg [3:0]  cnt;

    reg [PIXW-1:0] w [0:NPIX-1];
    reg [NPIX-1:0] region;
    reg [PIXW-1:0] bg_r;
    reg [7:0]      x0_r, y0_r;

    integer i, r, c;

    //------------------------------------------------------------------------
    // Column accumulation, CPC columns per cycle.
    //
    // The first CPC columns are taken straight from the input on the cycle that
    // captures the cluster, and what gets registered is the window already
    // shifted by that much. Nine columns therefore cost five cycles, and the
    // exact number matters: the seed test only forbids two local maxima inside
    // one 9x9 window, so two stars on the same row can be five columns apart
    // and no closer. Hold the capture door shut for longer than five cycles and
    // those pairs lose one of their two stars. Measured on a real DUST frame
    // that was two stars a frame at ten cycles, and none at five.
    //------------------------------------------------------------------------
    localparam integer CPC = 2;

    wire cap = (state == S_IDLE) && start;

    reg [18:0] sum_i;
    reg [21:0] sum_x, sum_y;
    reg [6:0]  npx;

    reg [18:0] sum_i_n;
    reg [21:0] sum_x_n, sum_y_n;
    reg [6:0]  npx_n;

    // One combinational block, not two. Splitting the column sums out into an
    // array that a second `always @(*)` then read looked tidier and was wrong:
    // an array element indexed by a loop variable is exactly the read that
    // sensitivity-list inference is weakest at, and the second block kept a
    // stale sum. It cost one star in a hundred and nothing that looked like a
    // bug until the model disagreed.
    reg [PIXW-1:0] src_pix;
    reg            src_reg;
    reg [PIXW-1:0] qv;
    reg [16:0]     cs;
    reg [19:0]     csy;
    reg [3:0]      nc;
    reg [3:0]      rr4;
    reg [3:0]      cidx;
    reg            in_box;

    wire [PIXW-1:0] src_bg  = cap ? bg : bg_r;
    wire [3:0]      src_cnt = cap ? 4'd0 : cnt;

    integer j;

    always @(*) begin
        sum_i_n = cap ? 19'd0 : sum_i;
        sum_x_n = cap ? 22'd0 : sum_x;
        sum_y_n = cap ? 22'd0 : sum_y;
        npx_n   = cap ? 7'd0  : npx;

        for (j = 0; j < CPC; j = j + 1) begin
            cs   = 17'd0;
            csy  = 20'd0;
            nc   = 4'd0;
            cidx = src_cnt + j[3:0];

            for (r = 0; r < WIN; r = r + 1) begin
                src_pix = cap ? win[(r*WIN+j)*PIXW +: PIXW] : w[r*WIN+j];
                src_reg = cap ? reg_in[r*WIN+j]             : region[r*WIN+j];

                // What carries weight: the grown region, or a fixed square
                // about the seed when CG_HALF says so.
                in_box = (cidx >= (HALF - CG_HALF)) && (cidx <= (HALF + CG_HALF)) &&
                         (r    >= (HALF - CG_HALF)) && (r    <= (HALF + CG_HALF));

                if ((CG_HALF <= 0) ? src_reg : in_box)
                    qv = (src_pix > src_bg) ? (src_pix - src_bg) : {PIXW{1'b0}};
                else
                    qv = {PIXW{1'b0}};

                rr4 = r[3:0];
                cs  = cs  + {{(17-PIXW){1'b0}}, qv};
                csy = csy + (rr4 * {{(20-PIXW){1'b0}}, qv});
                nc  = nc  + {3'b0, src_reg};
            end

            sum_i_n = sum_i_n + {2'b0, cs};
            sum_x_n = sum_x_n + (cidx * {5'b0, cs});
            sum_y_n = sum_y_n + {2'b0, csy};
            npx_n   = npx_n   + {3'b0, nc};
        end
    end

    wire pass_n = (npx_n >= MIN_NPX[6:0]) && (sum_i_n >= MIN_SUM[18:0]);
    wire last_col = ((cnt + CPC[3:0]) >= WIN[3:0]);

    //------------------------------------------------------------------------
    // One-deep handoff to the divider. Accumulating takes nine cycles and
    // dividing fifteen, so two clusters arriving back to back would otherwise
    // stall the front end on a divider that is still working. Ninety flip-flops
    // of result buffer decouple them.
    //------------------------------------------------------------------------
    reg        hold_valid = 1'b0;
    reg [18:0] hold_i;
    reg [21:0] hold_x, hold_y;
    reg [6:0]  hold_npx;
    reg [7:0]  hold_x0, hold_y0;

    wire hold_take;      // the divider is loading from the hold this cycle

    task load_hold;
        input [18:0] hi;
        input [21:0] hx, hy;
        input [6:0]  hn;
        input [7:0]  hx0, hy0;
        begin
            hold_i   <= hi;
            hold_x   <= hx;
            hold_y   <= hy;
            hold_npx <= hn;
            hold_x0  <= hx0;
            hold_y0  <= hy0;
        end
    endtask

    //------------------------------------------------------------------------
    // Stage 1: capture and accumulate. `busy` is asserted only here.
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        out_reject <= 1'b0;

        if (rst) begin
            state      <= S_IDLE;
            busy       <= 1'b0;
            hold_valid <= 1'b0;
        end else begin
            if (hold_take)
                hold_valid <= 1'b0;

            case (state)

            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    // Load the window already shifted one column left, because
                    // column 0 has been consumed on this very cycle.
                    for (r = 0; r < WIN; r = r + 1)
                        for (c = 0; c < WIN; c = c + 1)
                            if (c + CPC < WIN) begin
                                w[r*WIN+c]      <= win[(r*WIN+c+CPC)*PIXW +: PIXW];
                                region[r*WIN+c] <= reg_in[r*WIN+c+CPC];
                            end else begin
                                w[r*WIN+c]      <= {PIXW{1'b0}};
                                region[r*WIN+c] <= 1'b0;
                            end
                    bg_r  <= bg;
                    x0_r  <= x0;
                    y0_r  <= y0;
                    sum_i <= sum_i_n;
                    sum_x <= sum_x_n;
                    sum_y <= sum_y_n;
                    npx   <= npx_n;
                    cnt   <= CPC[3:0];
                    busy  <= 1'b1;
                    state <= S_ACC;
                end
            end

            S_ACC: begin
                sum_i <= sum_i_n;
                sum_x <= sum_x_n;
                sum_y <= sum_y_n;
                npx   <= npx_n;

                // A column shift is per row, not a shift of the flat vector:
                // bit r*WIN+WIN-1 and bit (r+1)*WIN are neighbours in the
                // vector and nowhere near each other in the window.
                for (r = 0; r < WIN; r = r + 1)
                    for (c = 0; c < WIN; c = c + 1)
                        if (c + CPC < WIN) begin
                            w[r*WIN+c]      <= w[r*WIN+c+CPC];
                            region[r*WIN+c] <= region[r*WIN+c+CPC];
                        end else begin
                            w[r*WIN+c]      <= {PIXW{1'b0}};
                            region[r*WIN+c] <= 1'b0;
                        end

                cnt <= cnt + CPC[3:0];

                if (last_col) begin
                    if (!pass_n) begin
                        out_reject <= 1'b1;
                        busy       <= 1'b0;
                        state      <= S_IDLE;
                    end else if (!hold_valid || hold_take) begin
                        load_hold(sum_i_n, sum_x_n, sum_y_n, npx_n, x0_r, y0_r);
                        hold_valid <= 1'b1;
                        busy       <= 1'b0;
                        state      <= S_IDLE;
                    end else begin
                        state <= S_HAND;
                    end
                end
            end

            S_HAND: begin
                // Only reachable if two clusters and a slow divider line up.
                if (!hold_valid || hold_take) begin
                    load_hold(sum_i, sum_x, sum_y, npx, x0_r, y0_r);
                    hold_valid <= 1'b1;
                    busy       <= 1'b0;
                    state      <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    //------------------------------------------------------------------------
    // Stage 2: divide. Two of these, so x and y finish together.
    //
    // The quotient is sum * 2^(FRAC+1) / sum_i, one bit more than the answer
    // needs; adding one and shifting right rounds it. Truncating alone would
    // pull every centroid half an LSB toward the window's top left corner,
    // which is a bias, not noise, and it does not average out over a frame.
    //
    // Only FRAC+5 iterations are needed rather than the numerator's full
    // width: the relative centroid cannot exceed WIN-1, so the quotient is
    // below 2^(FRAC+5) and the high part of the numerator is a valid starting
    // remainder.
    //------------------------------------------------------------------------
    localparam integer QW = FRAC + 5;                // 13

    reg [19:0]   remx, remy;
    reg [QW-1:0] nlox, nloy;
    reg [QW-1:0] qx, qy;
    reg [18:0]   den;
    reg [6:0]    npx_d;
    reg [7:0]    x0_d, y0_d;
    reg [4:0]    dcnt = 5'd0;
    reg          drun = 1'b0;

    assign hold_take = hold_valid && !drun;

    wire [30:0] numx = {hold_x, {(FRAC+1){1'b0}}};
    wire [30:0] numy = {hold_y, {(FRAC+1){1'b0}}};

    wire [19:0] remx_sh = {remx[18:0], nlox[QW-1]};
    wire [19:0] remy_sh = {remy[18:0], nloy[QW-1]};
    wire        takex   = (remx_sh >= {1'b0, den});
    wire        takey   = (remy_sh >= {1'b0, den});

    wire [QW:0] qx_round = {1'b0, qx} + 1'b1;
    wire [QW:0] qy_round = {1'b0, qy} + 1'b1;

    always @(posedge clk) begin
        out_valid <= 1'b0;

        if (rst) begin
            drun <= 1'b0;
            dcnt <= 5'd0;
        end else if (!drun) begin
            if (hold_valid) begin
                remx  <= {2'b0, numx[30:QW]};
                remy  <= {2'b0, numy[30:QW]};
                nlox  <= numx[QW-1:0];
                nloy  <= numy[QW-1:0];
                qx    <= {QW{1'b0}};
                qy    <= {QW{1'b0}};
                den   <= hold_i;
                npx_d <= hold_npx;
                x0_d  <= hold_x0;
                y0_d  <= hold_y0;
                dcnt  <= 5'd0;
                drun  <= 1'b1;
            end
        end else if (dcnt != QW[4:0]) begin
            remx <= takex ? (remx_sh - {1'b0, den}) : remx_sh;
            remy <= takey ? (remy_sh - {1'b0, den}) : remy_sh;
            nlox <= {nlox[QW-2:0], 1'b0};
            nloy <= {nloy[QW-2:0], 1'b0};
            qx   <= {qx[QW-2:0], takex};
            qy   <= {qy[QW-2:0], takey};
            dcnt <= dcnt + 5'd1;
        end else begin
            out_x     <= {x0_d, {FRAC{1'b0}}} + {{(16-QW){1'b0}}, qx_round[QW:1]};
            out_y     <= {y0_d, {FRAC{1'b0}}} + {{(16-QW){1'b0}}, qy_round[QW:1]};
            out_sum   <= den;
            out_npx   <= npx_d;
            out_valid <= 1'b1;
            drun      <= 1'b0;
        end
    end

endmodule
