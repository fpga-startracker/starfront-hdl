`timescale 1ns / 1ps

//============================================================================
// Module: cam_activity
// Description: Coarse "is the camera producing anything?" monitor.
//
//   Everything the OV7670 drives lives in the PCLK domain, which is dead
//   silent until XCLK is running and the sensor has come out of reset. This
//   module watches each of those signals for activity inside a fixed window
//   and republishes four sticky flags in the clk domain, so the display and
//   the LEDs can show them without needing a full frame buffer.
//
//   This is deliberately cheap: it says "toggling" or "not toggling", nothing
//   about whether the line and frame geometry is right. Counting bytes per
//   line and lines per frame is cam_stream_probe's job in the next milestone.
//============================================================================

module cam_activity #(
    parameter integer CLK_FREQ  = 25_000_000,
    parameter integer WINDOW_MS = 50
) (
    input  wire        clk,          // display / control clock
    input  wire        rst,

    // Camera side, all in the cam_pclk domain
    input  wire        cam_pclk,
    input  wire        cam_href,
    input  wire        cam_vsync,
    input  wire [7:0]  cam_data,

    output reg         pclk_alive,
    output reg         href_alive,
    output reg         vsync_alive,
    output reg         data_alive
);

    localparam integer T_WINDOW = (CLK_FREQ / 1000) * WINDOW_MS;

    //------------------------------------------------------------------------
    // cam_pclk domain: turn every kind of activity into a slow toggle, which
    // is safe to sample from the other side.
    //------------------------------------------------------------------------
    reg [3:0] pclk_div  = 4'd0;
    reg       href_tog  = 1'b0;
    reg       vsync_tog = 1'b0;
    reg       data_tog  = 1'b0;
    reg       href_d    = 1'b0;
    reg       vsync_d   = 1'b0;
    reg [7:0] data_d    = 8'd0;

    always @(posedge cam_pclk) begin
        pclk_div <= pclk_div + 4'd1;

        href_d   <= cam_href;
        vsync_d  <= cam_vsync;
        data_d   <= cam_data;

        if (cam_href  != href_d ) href_tog  <= ~href_tog;
        if (cam_vsync != vsync_d) vsync_tog <= ~vsync_tog;
        if (cam_data  != data_d ) data_tog  <= ~data_tog;
    end

    //------------------------------------------------------------------------
    // clk domain: edge-detect the toggles, latch sticky bits, publish once
    // per window.
    //------------------------------------------------------------------------
    wire pclk_bit_s, href_tog_s, vsync_tog_s, data_tog_s;

    cdc_sync #(.WIDTH(1)) u_sync_pclk  (.clk(clk), .din(pclk_div[3]), .dout(pclk_bit_s ));
    cdc_sync #(.WIDTH(1)) u_sync_href  (.clk(clk), .din(href_tog   ), .dout(href_tog_s ));
    cdc_sync #(.WIDTH(1)) u_sync_vsync (.clk(clk), .din(vsync_tog  ), .dout(vsync_tog_s));
    cdc_sync #(.WIDTH(1)) u_sync_data  (.clk(clk), .din(data_tog   ), .dout(data_tog_s ));

    reg pclk_bit_d  = 1'b0;
    reg href_tog_d  = 1'b0;
    reg vsync_tog_d = 1'b0;
    reg data_tog_d  = 1'b0;

    reg p_sticky = 1'b0;
    reg h_sticky = 1'b0;
    reg v_sticky = 1'b0;
    reg d_sticky = 1'b0;

    reg [24:0] win_cnt = 25'd0;

    always @(posedge clk) begin
        if (rst) begin
            win_cnt     <= 25'd0;
            p_sticky    <= 1'b0;
            h_sticky    <= 1'b0;
            v_sticky    <= 1'b0;
            d_sticky    <= 1'b0;
            pclk_alive  <= 1'b0;
            href_alive  <= 1'b0;
            vsync_alive <= 1'b0;
            data_alive  <= 1'b0;
        end else begin
            pclk_bit_d  <= pclk_bit_s;
            href_tog_d  <= href_tog_s;
            vsync_tog_d <= vsync_tog_s;
            data_tog_d  <= data_tog_s;

            // Publish and clear at the window boundary...
            if (win_cnt == T_WINDOW[24:0]) begin
                win_cnt     <= 25'd0;
                pclk_alive  <= p_sticky;
                href_alive  <= h_sticky;
                vsync_alive <= v_sticky;
                data_alive  <= d_sticky;
                p_sticky    <= 1'b0;
                h_sticky    <= 1'b0;
                v_sticky    <= 1'b0;
                d_sticky    <= 1'b0;
            end else begin
                win_cnt <= win_cnt + 25'd1;
            end

            // ...but a toggle seen on the same cycle still counts, so these
            // assignments come after the clear above.
            if (pclk_bit_s  != pclk_bit_d ) p_sticky <= 1'b1;
            if (href_tog_s  != href_tog_d ) h_sticky <= 1'b1;
            if (vsync_tog_s != vsync_tog_d) v_sticky <= 1'b1;
            if (data_tog_s  != data_tog_d ) d_sticky <= 1'b1;
        end
    end

endmodule
