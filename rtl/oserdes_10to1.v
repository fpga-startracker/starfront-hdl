`timescale 1ns / 1ps

//============================================================================
// Module: oserdes_10to1
// Description: 10:1 output serialiser for one TMDS lane, built from a
//              master/slave OSERDESE2 pair (a single OSERDESE2 tops out at
//              8:1 in DDR mode, so the slave supplies the extra two bits
//              through SHIFTIN/SHIFTOUT).
//
//   clk_ser must be exactly 5x clk_pix and come from the same MMCM, so the
//   two are phase aligned. For 640x480 @ 60 Hz that is 125 MHz / 25 MHz,
//   i.e. 250 Mbps per lane - comfortably inside the OSERDESE2 limit even on
//   a -1 speed grade part.
//
//   din leaves the pin LSB first: din[0] is the first bit on the wire.
//
//   Under `SIM` a behavioural shift register stands in for the primitive so
//   the design can be elaborated by Icarus Verilog.
//============================================================================

module oserdes_10to1 (
    input  wire        clk_ser,    // 5x pixel clock
    input  wire        clk_pix,    // pixel clock (OSERDESE2 CLKDIV)
    input  wire        rst,        // synchronous to clk_pix
    input  wire [9:0]  din,
    output wire        sdata       // single ended serial, drive an OBUFDS
);

`ifdef SIM

    // Behavioural stand-in: reload every 5 clk_ser cycles, shift out two bits
    // per cycle (DDR is modelled as "LSB on the cycle" only - enough for
    // elaboration and waveform sanity, not for bit-accurate DDR checking).
    reg [9:0] shift_reg = 10'd0;
    reg [3:0] bit_cnt   = 4'd0;

    always @(posedge clk_ser) begin
        if (rst) begin
            shift_reg <= din;
            bit_cnt   <= 4'd0;
        end else if (bit_cnt == 4'd9) begin
            shift_reg <= din;
            bit_cnt   <= 4'd0;
        end else begin
            shift_reg <= {1'b0, shift_reg[9:1]};
            bit_cnt   <= bit_cnt + 4'd1;
        end
    end

    assign sdata = shift_reg[0];

`else

    wire [1:0] shift;

    OSERDESE2 #(
        .DATA_RATE_OQ   ("DDR"),
        .DATA_RATE_TQ   ("SDR"),
        .DATA_WIDTH     (10),
        .SERDES_MODE    ("MASTER"),
        .TRISTATE_WIDTH (1),
        .TBYTE_CTL      ("FALSE"),
        .TBYTE_SRC      ("FALSE")
    ) u_master (
        .OQ        (sdata),
        .OFB       (),
        .TQ        (),
        .TFB       (),
        .TBYTEOUT  (),
        .SHIFTOUT1 (),
        .SHIFTOUT2 (),
        .CLK       (clk_ser),
        .CLKDIV    (clk_pix),
        .D1        (din[0]),
        .D2        (din[1]),
        .D3        (din[2]),
        .D4        (din[3]),
        .D5        (din[4]),
        .D6        (din[5]),
        .D7        (din[6]),
        .D8        (din[7]),
        .OCE       (1'b1),
        .RST       (rst),
        .SHIFTIN1  (shift[0]),
        .SHIFTIN2  (shift[1]),
        .T1        (1'b0),
        .T2        (1'b0),
        .T3        (1'b0),
        .T4        (1'b0),
        .TBYTEIN   (1'b0),
        .TCE       (1'b0)
    );

    OSERDESE2 #(
        .DATA_RATE_OQ   ("DDR"),
        .DATA_RATE_TQ   ("SDR"),
        .DATA_WIDTH     (10),
        .SERDES_MODE    ("SLAVE"),
        .TRISTATE_WIDTH (1),
        .TBYTE_CTL      ("FALSE"),
        .TBYTE_SRC      ("FALSE")
    ) u_slave (
        .OQ        (),
        .OFB       (),
        .TQ        (),
        .TFB       (),
        .TBYTEOUT  (),
        .SHIFTOUT1 (shift[0]),
        .SHIFTOUT2 (shift[1]),
        .CLK       (clk_ser),
        .CLKDIV    (clk_pix),
        .D1        (1'b0),
        .D2        (1'b0),
        .D3        (din[8]),
        .D4        (din[9]),
        .D5        (1'b0),
        .D6        (1'b0),
        .D7        (1'b0),
        .D8        (1'b0),
        .OCE       (1'b1),
        .RST       (rst),
        .SHIFTIN1  (1'b0),
        .SHIFTIN2  (1'b0),
        .T1        (1'b0),
        .T2        (1'b0),
        .T3        (1'b0),
        .T4        (1'b0),
        .TBYTEIN   (1'b0),
        .TCE       (1'b0)
    );

`endif

endmodule
