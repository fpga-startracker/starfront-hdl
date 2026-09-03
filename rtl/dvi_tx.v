`timescale 1ns / 1ps

//============================================================================
// Module: dvi_tx
// Description: DVI-D transmitter for the AX7010 HDMI connector.
//
//   The AX7010 wires the four TMDS pairs straight from PL bank 34 to the
//   HDMI socket - there is no encoder chip on the board, so the 8b/10b
//   encoding and the 10:1 serialisation both happen here.
//
//   Only the DVI subset is sent (no data islands, no AVI infoframe), which
//   every HDMI monitor and TV accepts.
//
//   Channel map per DVI 1.0:  ch0 = blue + {vsync, hsync}, ch1 = green,
//   ch2 = red. The clock lane carries a fixed 10-bit pattern that yields one
//   full period per pixel clock.
//
//   hsync/vsync must be ACTIVE HIGH here (vga_sync_gen.vga_hsync_p / _vsync_p).
//============================================================================

module dvi_tx (
    input  wire        clk_pix,     // 25 MHz pixel clock
    input  wire        clk_ser,     // 125 MHz, same MMCM as clk_pix
    input  wire        rst,         // synchronous to clk_pix

    input  wire [7:0]  r,
    input  wire [7:0]  g,
    input  wire [7:0]  b,
    input  wire        hsync,       // active HIGH
    input  wire        vsync,       // active HIGH
    input  wire        de,

    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,
    output wire [2:0]  tmds_d_n
);

    // Five low then five high, sent LSB first: one clock period per pixel.
    localparam [9:0] CLK_PATTERN = 10'b1111100000;

    wire [9:0] tmds_ch0, tmds_ch1, tmds_ch2;

    tmds_encoder u_enc_ch0 (
        .clk  ( clk_pix          ),
        .rst  ( rst              ),
        .din  ( b                ),
        .c    ( {vsync, hsync}   ),
        .de   ( de               ),
        .dout ( tmds_ch0         )
    );

    tmds_encoder u_enc_ch1 (
        .clk  ( clk_pix ),
        .rst  ( rst     ),
        .din  ( g       ),
        .c    ( 2'b00   ),
        .de   ( de      ),
        .dout ( tmds_ch1 )
    );

    tmds_encoder u_enc_ch2 (
        .clk  ( clk_pix ),
        .rst  ( rst     ),
        .din  ( r       ),
        .c    ( 2'b00   ),
        .de   ( de      ),
        .dout ( tmds_ch2 )
    );

    wire ser_ch0, ser_ch1, ser_ch2, ser_clk;

    oserdes_10to1 u_ser_ch0 (
        .clk_ser ( clk_ser  ), .clk_pix ( clk_pix ), .rst ( rst ),
        .din     ( tmds_ch0 ), .sdata   ( ser_ch0 )
    );

    oserdes_10to1 u_ser_ch1 (
        .clk_ser ( clk_ser  ), .clk_pix ( clk_pix ), .rst ( rst ),
        .din     ( tmds_ch1 ), .sdata   ( ser_ch1 )
    );

    oserdes_10to1 u_ser_ch2 (
        .clk_ser ( clk_ser  ), .clk_pix ( clk_pix ), .rst ( rst ),
        .din     ( tmds_ch2 ), .sdata   ( ser_ch2 )
    );

    oserdes_10to1 u_ser_clk (
        .clk_ser ( clk_ser     ), .clk_pix ( clk_pix ), .rst ( rst ),
        .din     ( CLK_PATTERN ), .sdata   ( ser_clk )
    );

`ifdef SIM
    assign tmds_clk_p =  ser_clk;
    assign tmds_clk_n = ~ser_clk;
    assign tmds_d_p   = { ser_ch2,  ser_ch1,  ser_ch0};
    assign tmds_d_n   = {~ser_ch2, ~ser_ch1, ~ser_ch0};
`else
    OBUFDS u_obuf_clk (.I(ser_clk), .O(tmds_clk_p),   .OB(tmds_clk_n)  );
    OBUFDS u_obuf_d0  (.I(ser_ch0), .O(tmds_d_p[0]),  .OB(tmds_d_n[0]) );
    OBUFDS u_obuf_d1  (.I(ser_ch1), .O(tmds_d_p[1]),  .OB(tmds_d_n[1]) );
    OBUFDS u_obuf_d2  (.I(ser_ch2), .O(tmds_d_p[2]),  .OB(tmds_d_n[2]) );
`endif

endmodule
