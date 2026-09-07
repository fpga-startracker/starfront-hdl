`timescale 1ns / 1ps

//============================================================================
// Module: tmds_encoder
// Description: DVI 1.0 / HDMI TMDS 8b/10b channel encoder (section 3.2.2 of
//              the DVI 1.0 specification).
//
//   Stage 1 - transition minimisation: the 8 data bits are XOR- or XNOR-
//             chained so that the encoded word has at most 5 transitions.
//             q_m[8] records which operation was used.
//   Stage 2 - DC balancing: a running disparity counter `cnt` decides whether
//             the byte is inverted, so that the average number of ones and
//             zeros on the serial line stays balanced.
//
//   During blanking (de = 0) one of four fixed control tokens is sent and the
//   running disparity is reset. Channel 0 carries {vsync, hsync} in `c`;
//   channels 1 and 2 tie `c` to 2'b00.
//
// `dout` leaves the serialiser LSB first (dout[0] is on the wire first).
//============================================================================

module tmds_encoder (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  din,        // pixel component for this channel
    input  wire [1:0]  c,          // control bits, used only while de = 0
    input  wire        de,         // data enable (active video)
    output reg  [9:0]  dout
);

    //------------------------------------------------------------------------
    // Stage 1: transition minimisation
    //------------------------------------------------------------------------
    wire [3:0] n1_din = din[0] + din[1] + din[2] + din[3]
                      + din[4] + din[5] + din[6] + din[7];

    // Choose XNOR when the input already has many ones, so the encoded word
    // does not add further transitions.
    wire use_xnor = (n1_din > 4'd4) || ((n1_din == 4'd4) && (din[0] == 1'b0));

    wire [8:0] q_m;
    assign q_m[0] = din[0];
    assign q_m[1] = use_xnor ? ~(q_m[0] ^ din[1]) : (q_m[0] ^ din[1]);
    assign q_m[2] = use_xnor ? ~(q_m[1] ^ din[2]) : (q_m[1] ^ din[2]);
    assign q_m[3] = use_xnor ? ~(q_m[2] ^ din[3]) : (q_m[2] ^ din[3]);
    assign q_m[4] = use_xnor ? ~(q_m[3] ^ din[4]) : (q_m[3] ^ din[4]);
    assign q_m[5] = use_xnor ? ~(q_m[4] ^ din[5]) : (q_m[4] ^ din[5]);
    assign q_m[6] = use_xnor ? ~(q_m[5] ^ din[6]) : (q_m[5] ^ din[6]);
    assign q_m[7] = use_xnor ? ~(q_m[6] ^ din[7]) : (q_m[6] ^ din[7]);
    assign q_m[8] = ~use_xnor;      // 1 = XOR was used, 0 = XNOR

    //------------------------------------------------------------------------
    // Stage 2: DC balancing
    //------------------------------------------------------------------------
    wire [3:0] n1_qm = q_m[0] + q_m[1] + q_m[2] + q_m[3]
                     + q_m[4] + q_m[5] + q_m[6] + q_m[7];
    wire [3:0] n0_qm = 4'd8 - n1_qm;

    // ones minus zeros, signed, range -8 .. +8
    wire signed [5:0] diff_qm = $signed({2'b00, n1_qm}) - $signed({2'b00, n0_qm});

    // 2*q_m[8] and 2*(1 - q_m[8]) kept signed so the whole expression stays signed
    wire signed [5:0] adj_hi = q_m[8] ? 6'sd2 : 6'sd0;
    wire signed [5:0] adj_lo = q_m[8] ? 6'sd0 : 6'sd2;

    reg signed [5:0] cnt;   // running disparity

    // DVI 1.0 control tokens, indexed by {c1, c0}
    localparam [9:0] CTRL_00 = 10'b1101010100;
    localparam [9:0] CTRL_01 = 10'b0010101011;
    localparam [9:0] CTRL_10 = 10'b0101010100;
    localparam [9:0] CTRL_11 = 10'b1010101011;

    always @(posedge clk) begin
        if (rst) begin
            dout <= CTRL_00;
            cnt  <= 6'sd0;
        end else if (!de) begin
            case (c)
                2'b00: dout <= CTRL_00;
                2'b01: dout <= CTRL_01;
                2'b10: dout <= CTRL_10;
                2'b11: dout <= CTRL_11;
            endcase
            cnt <= 6'sd0;
        end else begin
            if ((cnt == 6'sd0) || (n1_qm == n0_qm)) begin
                // No disparity to correct: invert only when q_m[8] says to.
                dout[9]   <= ~q_m[8];
                dout[8]   <=  q_m[8];
                dout[7:0] <=  q_m[8] ? q_m[7:0] : ~q_m[7:0];
                cnt       <=  q_m[8] ? (cnt + diff_qm) : (cnt - diff_qm);
            end else if (((cnt > 6'sd0) && (n1_qm > n0_qm)) ||
                         ((cnt < 6'sd0) && (n0_qm > n1_qm))) begin
                // Disparity and word pull the same way: invert to correct.
                dout[9]   <= 1'b1;
                dout[8]   <= q_m[8];
                dout[7:0] <= ~q_m[7:0];
                cnt       <= cnt + adj_hi - diff_qm;
            end else begin
                dout[9]   <= 1'b0;
                dout[8]   <= q_m[8];
                dout[7:0] <= q_m[7:0];
                cnt       <= cnt - adj_lo + diff_qm;
            end
        end
    end

endmodule
