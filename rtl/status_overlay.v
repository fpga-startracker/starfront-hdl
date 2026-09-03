`timescale 1ns / 1ps

//============================================================================
// Module: status_overlay
// Description: Draws the bring-up state directly onto the 640x480 output.
//
//   A PL-only design on this board has no UART - the USB serial port is on PS
//   MIO - and only four LEDs. HDMI already works by milestone 1, so the screen
//   is by far the widest debug channel available, and the numbers that matter
//   are drawn as large hex digits.
//
//   Layout (640x480):
//       y   0.. 47   banner: red = no camera, amber = camera but bad stream,
//                    green = everything checks out
//       y  80..143   row 0, red tab    PID VER  __ readback     expect 7673 0001
//       y 176..239   row 1, green tab  bytes/line  lines/frame   expect 0500 01E0
//       y 272..335   row 2, blue tab   PCLK/100kHz  frames/sec   expect 00FA 001E
//       y 368..431   row 3, amber tab  eight status bits, drawn as blocks
//       y 464..479   sweep bar, one step per frame. If it stops, the pixel
//                    clock or the display pipeline has died and nothing else
//                    on screen can be trusted.
//
//   Row 3 bits, MSB first:
//       id_ok, rw_ok, init_done, stream_ok, data, href, vsync, pclk
//   All eight lit is a fully working camera.
//
//   Geometry is all powers of two: cells are 64 wide on a 64 pitch, and each
//   8x8 glyph is scaled by 8 to fill one exactly. The font's own blank first
//   and last columns provide the spacing between digits.
//============================================================================

module status_overlay (
    input  wire        clk_pix,
    input  wire        rst,

    input  wire [9:0]  pixel_x,
    input  wire [9:0]  pixel_y,
    input  wire        active,
    input  wire        frame_tick,

    input  wire [31:0] row0,        // drawn as 8 hex digits
    input  wire [31:0] row1,
    input  wire [31:0] row2,
    input  wire [7:0]  row3_bits,   // drawn as 8 blocks
    input  wire [1:0]  banner_level, // 0 = red, 1 = amber, 2 = green

    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b
);

    //------------------------------------------------------------------------
    // Row and cell decode
    //------------------------------------------------------------------------
    wire row_sel0 = (pixel_y >= 10'd80 ) && (pixel_y < 10'd144);
    wire row_sel1 = (pixel_y >= 10'd176) && (pixel_y < 10'd240);
    wire row_sel2 = (pixel_y >= 10'd272) && (pixel_y < 10'd336);
    wire row_sel3 = (pixel_y >= 10'd368) && (pixel_y < 10'd432);
    wire in_row   = row_sel0 | row_sel1 | row_sel2 | row_sel3;

    reg  [9:0] row_y0;
    reg [31:0] row_val;
    reg  [7:0] tab_r, tab_g, tab_b;

    always @(*) begin
        row_y0  = 10'd80;
        row_val = row0;
        tab_r   = 8'hE0; tab_g = 8'h30; tab_b = 8'h30;
        if (row_sel1) begin
            row_y0  = 10'd176; row_val = row1;
            tab_r = 8'h30; tab_g = 8'hE0; tab_b = 8'h30;
        end
        if (row_sel2) begin
            row_y0  = 10'd272; row_val = row2;
            tab_r = 8'h40; tab_g = 8'h70; tab_b = 8'hFF;
        end
        if (row_sel3) begin
            row_y0  = 10'd368; row_val = {24'd0, row3_bits};
            tab_r = 8'hE0; tab_g = 8'hE0; tab_b = 8'h30;
        end
    end

    wire       in_cell_x = (pixel_x >= 10'd64) && (pixel_x < 10'd576);
    wire [3:0] cell_i4   = pixel_x[9:6] - 4'd1;      // (x - 64) >> 6
    wire [2:0] cell_i    = cell_i4[2:0];
    wire [5:0] cx        = pixel_x[5:0];
    wire [9:0] cy10      = pixel_y - row_y0;
    wire [5:0] cy        = cy10[5:0];

    //------------------------------------------------------------------------
    // Hex digit for this cell: leftmost cell is the most significant nibble
    //------------------------------------------------------------------------
    wire [4:0] nib_shift = {3'd7 - cell_i, 2'b00};   // (7 - cell_i) * 4
    wire [3:0] nibble    = row_val[nib_shift +: 4];

    wire [7:0] glyph_row;
    hex_font u_font (
        .value ( nibble  ),
        .row   ( cy[5:3] ),      // 8 screen rows per glyph row
        .bits  ( glyph_row )
    );

    wire glyph_on = glyph_row[3'd7 - cx[5:3]];       // 8 screen columns per glyph column

    //------------------------------------------------------------------------
    // Row 3 is drawn as blocks instead - a lit or unlit square reads faster
    // than a hex digit when what you want is "are all the flags set".
    //------------------------------------------------------------------------
    wire block_on = (cx >= 6'd4) && (cx < 6'd60) && (cy >= 6'd8) && (cy < 6'd56);
    wire bit_on   = row3_bits[3'd7 - cell_i];

    wire in_tab = in_row && (pixel_x >= 10'd16) && (pixel_x < 10'd48);

    //------------------------------------------------------------------------
    // Sweep bar: proof of life for the pixel clock and the frame timing
    //------------------------------------------------------------------------
    reg [9:0] sweep_x = 10'd0;

    always @(posedge clk_pix) begin
        if (rst)
            sweep_x <= 10'd0;
        else if (frame_tick)
            sweep_x <= (sweep_x >= 10'd576) ? 10'd0 : (sweep_x + 10'd8);
    end

    wire in_sweep_band = (pixel_y >= 10'd464);
    wire in_sweep      = in_sweep_band &&
                         (pixel_x >= sweep_x) && (pixel_x < (sweep_x + 10'd64));

    //------------------------------------------------------------------------
    // Colour mux
    //------------------------------------------------------------------------
    always @(*) begin
        if (!active) begin
            r = 8'h00; g = 8'h00; b = 8'h00;
        end else if (pixel_y < 10'd48) begin
            case (banner_level)
                2'd0:    begin r = 8'hC0; g = 8'h10; b = 8'h10; end  // red
                2'd1:    begin r = 8'hD0; g = 8'h90; b = 8'h00; end  // amber
                default: begin r = 8'h00; g = 8'hC0; b = 8'h20; end  // green
            endcase
        end else if (in_sweep_band) begin
            if (in_sweep) begin r = 8'hF0; g = 8'hF0; b = 8'hF0; end
            else          begin r = 8'h08; g = 8'h08; b = 8'h10; end
        end else if (in_tab) begin
            r = tab_r; g = tab_g; b = tab_b;
        end else if (in_row && in_cell_x && row_sel3) begin
            if (block_on && bit_on)      begin r = 8'hF0; g = 8'hF0; b = 8'hF0; end
            else if (block_on)           begin r = 8'h18; g = 8'h18; b = 8'h48; end
            else                         begin r = 8'h10; g = 8'h10; b = 8'h18; end
        end else if (in_row && in_cell_x) begin
            if (glyph_on) begin r = 8'hF0; g = 8'hF0; b = 8'hF0; end
            else          begin r = 8'h10; g = 8'h10; b = 8'h18; end
        end else begin
            r = 8'h10; g = 8'h10; b = 8'h18;
        end
    end

endmodule
