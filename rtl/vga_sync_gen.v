`timescale 1ns / 1ps

//============================================================================
// Module: vga_sync_gen
// Description: 640x480 @ 60 Hz display timing generator driven by a 25 MHz
//              pixel clock. Ported unchanged in behaviour from the Basys 3
//              OV7670 project; the only addition is a pair of active-HIGH
//              sync outputs, which is the polarity a DVI/TMDS transmitter
//              expects (dvi_tx encodes the sync levels into the control
//              tokens directly).
//
// Clock domain: clk_pix (25 MHz)
//
// Horizontal: 800 clocks  (640 display + 16 front + 96 sync + 48 back)
// Vertical:   521 lines   (480 display + 10 front +  2 sync + 29 back)
//============================================================================

module vga_sync_gen (
    input  wire        clk_pix,
    input  wire        rst,

    output wire        vga_hsync,      // active LOW  (VGA connector polarity)
    output wire        vga_vsync,      // active LOW
    output wire        vga_hsync_p,    // active HIGH (feed to dvi_tx)
    output wire        vga_vsync_p,    // active HIGH
    output wire        vga_active,     // high inside the 640x480 display area

    output wire [9:0]  vga_pixel_x,    // 0-799
    output wire [9:0]  vga_pixel_y,    // 0-520

    output wire        vga_frame_tick  // 1-cycle pulse at the start of each frame
);

    localparam H_DISPLAY = 10'd640;
    localparam H_FP      = 10'd16;
    localparam H_SYNC    = 10'd96;
    localparam H_BP      = 10'd48;
    localparam H_TOTAL   = 10'd800;

    localparam V_DISPLAY = 10'd480;
    localparam V_FP      = 10'd10;
    localparam V_SYNC    = 10'd2;
    localparam V_BP      = 10'd29;
    localparam V_TOTAL   = 10'd521;

    localparam H_SYNC_START = H_DISPLAY + H_FP;        // 656
    localparam H_SYNC_END   = H_SYNC_START + H_SYNC;   // 752
    localparam V_SYNC_START = V_DISPLAY + V_FP;        // 490
    localparam V_SYNC_END   = V_SYNC_START + V_SYNC;   // 492

    reg [9:0] vga_h_count = 10'd0;
    reg [9:0] vga_v_count = 10'd0;

    wire end_of_line  = (vga_h_count == H_TOTAL - 10'd1);
    wire end_of_frame = end_of_line && (vga_v_count == V_TOTAL - 10'd1);

    always @(posedge clk_pix) begin
        if (rst)
            vga_h_count <= 10'd0;
        else if (end_of_line)
            vga_h_count <= 10'd0;
        else
            vga_h_count <= vga_h_count + 10'd1;
    end

    always @(posedge clk_pix) begin
        if (rst)
            vga_v_count <= 10'd0;
        else if (end_of_line) begin
            if (vga_v_count == V_TOTAL - 10'd1)
                vga_v_count <= 10'd0;
            else
                vga_v_count <= vga_v_count + 10'd1;
        end
    end

    assign vga_hsync_p = (vga_h_count >= H_SYNC_START) && (vga_h_count < H_SYNC_END);
    assign vga_vsync_p = (vga_v_count >= V_SYNC_START) && (vga_v_count < V_SYNC_END);
    assign vga_hsync   = ~vga_hsync_p;
    assign vga_vsync   = ~vga_vsync_p;

    assign vga_active  = (vga_h_count < H_DISPLAY) && (vga_v_count < V_DISPLAY);

    assign vga_pixel_x = vga_h_count;
    assign vga_pixel_y = vga_v_count;

    assign vga_frame_tick = end_of_frame;

endmodule
