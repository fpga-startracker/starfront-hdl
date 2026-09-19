`timescale 1ns / 1ps

//============================================================================
// Module: top_starfront_bench
// Description: Centroiding bench for the ALINX AX7010 (xc7z010clg400-1).
//              PL-only, no camera: star fields come out of an on-chip frame
//              store, go through the same detector the camera would feed, and
//              the result is drawn on the HDMI output.
//
//   Why a separate top from top_starfront: that one is hardware-proven camera
//   bring-up and there is nothing to gain by making it conditional. This shares
//   every module that matters - the clocking, the DVI transmitter, the detector
//   itself - and differs only in where the pixels come from and what is drawn.
//
//   The point of the thing: measuring centroid accuracy needs hundreds of
//   frames with known answers, and no camera pointed at a monitor will give
//   you that repeatably. Feeding the image digitally removes the optics, the
//   display gamma, the registration and the exposure beat all at once, so what
//   is left to measure is the algorithm. bench/evaluate.py then scores the same
//   algorithm over the whole dataset in software, and sim/centroid proves the
//   two are the same arithmetic. This is the part of that chain that runs on
//   the board.
//
//   Screen, 640x480:
//     x   0..479   the stored frame, a 240x240 crop at 2x - which is exactly
//                  the illuminated disc of the DUST optics, so nothing that
//                  can hold a star is cropped away
//     x 480..639   detector state as text, see bench_panel.v
//     markers      a cross on every star in the list, centre left open
//
//   Controls:
//     KEY1  reset
//     KEY2  scroll the stored frame on by one display pixel, once
//     KEY3  scroll continuously, one display pixel per frame
//     KEY4  hold - stop the replay, freezing the last result on screen
//
//   A host can take all three over JTAG, and can also write a new frame into
//   the store and read the star list back out - see axi_bench_if.v.
//
//   Scrolling is what stands in for video here. Four 256x256 frames is the most
//   this part's block RAM could ever hold, so a stream of different images has
//   to come from off-chip; moving the one frame that is stored does not. And
//   because the binner averages 4x4 blocks, a one display-pixel offset is a
//   quarter of a binned pixel, so the detector sees a genuinely different
//   binned image with different noise under the threshold - a slewing sky,
//   which is what a star tracker actually looks at.
//
//   It is also the sub-pixel proof, on the board, with no host: press KEY4 to
//   hold, KEY2 to step once, and every centroid must move by exactly 0x40 in
//   the 8.8 readout.
//
//   LEDs (active low):
//     LED1  heartbeat      LED2  scrolling
//     LED3  a star was dropped for want of an engine
//     LED4  the star list filled up
//============================================================================

module top_starfront_bench #(
    parameter integer USE_MEM_FILE = 1,
    parameter         MEM_FILE     = "frames.mem",
    parameter integer CG_HALF      = 0        // 0 = blob centroid, 3 = fixed 7x7
) (
    input  wire        sys_clk,        // U18, 50 MHz PL_GCLK
    input  wire [3:0]  key_n,          // KEY1..KEY4, active low
    output wire [3:0]  led_n,          // LED1..LED4, active low

    output wire        hdmi_clk_p,
    output wire        hdmi_clk_n,
    output wire [2:0]  hdmi_d_p,
    output wire [2:0]  hdmi_d_n,
    output wire        hdmi_out_en,
    input  wire        hdmi_hpd
);

    localparam integer PIX_FREQ = 25_000_000;
    localparam integer IMG_W    = 256;
    localparam integer CROP_X0  = 8;
    localparam integer CROP_Y0  = 8;
    localparam integer CROP_WH  = 240;       // 2x on screen = 480

    //------------------------------------------------------------------------
    // Clocking - one MMCM, so clk_ser is exactly 5x clk_pix and phase aligned
    //------------------------------------------------------------------------
    wire clk_pix, clk_ser, mmcm_locked;

`ifdef SIM
    reg clk_pix_reg = 1'b0;
    reg clk_ser_reg = 1'b0;
    always @(posedge sys_clk) clk_pix_reg <= ~clk_pix_reg;
    always @(posedge sys_clk) clk_ser_reg <= ~clk_ser_reg;
    assign clk_pix     = clk_pix_reg;
    assign clk_ser     = clk_ser_reg;
    assign mmcm_locked = 1'b1;
`else
    clk_wiz_0 u_clk_wiz (
        .clk_in1  ( sys_clk     ),
        .clk_out1 ( clk_ser     ),
        .clk_out2 ( clk_pix     ),
        .locked   ( mmcm_locked )
    );
`endif

    wire rst_raw = ~key_n[0] | ~mmcm_locked;

    reg [3:0] rst_sync = 4'hF;
    always @(posedge clk_pix) begin
        if (rst_raw) rst_sync <= 4'hF;
        else         rst_sync <= {rst_sync[2:0], 1'b0};
    end
    wire rst_pix = rst_sync[3];

    //------------------------------------------------------------------------
    // Keys
    //------------------------------------------------------------------------
    wire key2, key3, key4;

    key_debounce #(.CLK_FREQ(PIX_FREQ)) u_key2 (
        .clk(clk_pix), .key_raw(~key_n[1]), .key_stable(key2));
    key_debounce #(.CLK_FREQ(PIX_FREQ)) u_key3 (
        .clk(clk_pix), .key_raw(~key_n[2]), .key_stable(key3));
    key_debounce #(.CLK_FREQ(PIX_FREQ)) u_key4 (
        .clk(clk_pix), .key_raw(~key_n[3]), .key_stable(key4));

    reg key2_d = 1'b0, key3_d = 1'b0, key4_d = 1'b0;
    reg scroll_en  = 1'b1;
    reg hold       = 1'b0;
    reg step_pulse = 1'b0;

    always @(posedge clk_pix) begin
        key2_d <= key2;  key3_d <= key3;  key4_d <= key4;
        step_pulse <= key2 & ~key2_d;
        if (rst_pix) begin
            scroll_en <= 1'b1;
            hold      <= 1'b0;
        end else begin
            if (key3 & ~key3_d) scroll_en <= ~scroll_en;
            if (key4 & ~key4_d) hold      <= ~hold;
        end
    end

    //------------------------------------------------------------------------
    // Frame source -> binner -> detector
    //------------------------------------------------------------------------
    wire       vga_hsync_p, vga_vsync_p, vga_active, vga_frame_tick;
    wire [9:0] vga_pixel_x, vga_pixel_y;

    // The display shows a 240x240 crop at 2x, placed so it covers the whole
    // illuminated disc of the DUST optics: nothing that can hold a star is
    // cropped away, and the integer scale keeps the markers on their pixels.
    wire [7:0] disp_x = CROP_X0[7:0] + {1'b0, vga_pixel_x[8:1]};
    wire [7:0] disp_y = CROP_Y0[7:0] + {1'b0, vga_pixel_y[8:1]};

    wire       src_valid, src_fstart;
    wire [9:0] src_x, src_y;
    wire [7:0] src_pix;
    wire [7:0] disp_data;
    wire signed [6:0] scroll_x, scroll_y;
    wire       play_buf;

    // The image moves the other way from the read offset, so the mask that
    // follows the disc moves the other way too.
    wire signed [5:0] fov_ox = -{{2{scroll_x[6]}}, scroll_x[6:2]};
    wire signed [5:0] fov_oy = -{{2{scroll_y[6]}}, scroll_y[6:2]};

    frame_source #(
        .IMG_W(IMG_W), .IMG_H(IMG_W), .UP(4),
        .USE_MEM_FILE(USE_MEM_FILE), .MEM_FILE(MEM_FILE)
    ) u_src (
        .clk         ( clk_pix    ),
        .rst         ( rst_pix    ),
        .run         ( ~hold_eff      ),
        .scroll_en   ( scroll_en_eff  ),
        .scroll_step ( step_eff       ),
        .scroll_x    ( scroll_x       ),
        .scroll_y    ( scroll_y       ),
        .pix_valid   ( src_valid  ),
        .pix_x       ( src_x      ),
        .pix_y       ( src_y      ),
        .pix_data    ( src_pix    ),
        .frame_start ( src_fstart ),
        .disp_x      ( disp_x     ),
        .disp_y      ( disp_y     ),
        .disp_data   ( disp_data  ),
        .fb_we       ( fb_we      ),
        .fb_addr     ( fb_addr    ),
        .fb_data     ( fb_data    ),
        .swap_req    ( swap_req   ),
        .play_buf    ( play_buf   )
    );

    wire       bin_valid;
    wire [7:0] bin_x, bin_y, bin_pix;

    bin_nxn #(.SHIFT(2), .IN_W(1024)) u_bin (
        .clk       ( clk_pix   ),
        .rst       ( rst_pix   ),
        .in_valid  ( src_valid ),
        .in_x      ( src_x     ),
        .in_y      ( src_y     ),
        .in_pix    ( src_pix   ),
        .out_valid ( bin_valid ),
        .out_x     ( bin_x     ),
        .out_y     ( bin_y     ),
        .out_pix   ( bin_pix   )
    );

    // The frame_start pulse is generated in the 1024x1024 domain; the detector
    // wants it in the binned one, and it must arrive before the first binned
    // pixel. The binner emits its first pixel only after four full rows, so
    // simply passing the pulse through is safe with 1023 rows to spare.
    reg fstart_d = 1'b0;
    always @(posedge clk_pix) fstart_d <= src_fstart;

    wire [6:0]  star_count, dropped;
    wire        overflow;
    wire [15:0] best_x, best_y, frame_count;
    wire [19:0] best_sum;
    wire [5:0]  rd_addr,  rd2_addr;
    wire [15:0] rd_x, rd_y, rd2_x, rd2_y;
    wire [19:0] rd_sum, rd2_sum;
    wire [6:0]  rd_npx, rd2_npx;
    wire [7:0]  bg_code, thr_code;
    wire [13:0] mad_acc;

    star_centroid #(
        .IMG_W(IMG_W), .IMG_H(IMG_W), .CG_HALF(CG_HALF)
    ) u_det (
        .clk           ( clk_pix     ),
        .rst           ( rst_pix     ),
        .in_valid      ( bin_valid   ),
        .in_x          ( bin_x       ),
        .in_y          ( bin_y       ),
        .in_code       ( bin_pix     ),
        .frame_start   ( fstart_d    ),
        .fov_ox        ( fov_ox      ),
        .fov_oy        ( fov_oy      ),
        .star_count    ( star_count  ),
        .dropped       ( dropped     ),
        .overflow      ( overflow    ),
        .best_x        ( best_x      ),
        .best_y        ( best_y      ),
        .best_sum      ( best_sum    ),
        .frame_count   ( frame_count ),
        .rd_addr       ( rd_addr     ),
        .rd_x          ( rd_x        ),
        .rd_y          ( rd_y        ),
        .rd_sum        ( rd_sum      ),
        .rd_npx        ( rd_npx      ),
        .rd2_addr      ( rd2_addr    ),
        .rd2_x         ( rd2_x       ),
        .rd2_y         ( rd2_y       ),
        .rd2_sum       ( rd2_sum     ),
        .rd2_npx       ( rd2_npx     ),
        .bg_code       ( bg_code     ),
        .thr_grow_code ( thr_code    ),
        .mad_acc       ( mad_acc     )
    );

    // When the host takes the controls, the keys stop mattering. A scripted run
    // has to be able to hold the replay, step it and read the answer without
    // anyone standing at the board.
    wire hold_eff      = host_override ? host_hold      : hold;
    wire scroll_en_eff = host_override ? host_scroll_en : scroll_en;
    wire step_eff      = host_override ? host_step      : step_pulse;

    //------------------------------------------------------------------------
    // Frames per second, measured rather than assumed - it is the number that
    // says whether the pipeline is keeping up.
    //------------------------------------------------------------------------
    reg [24:0] sec_cnt = 25'd0;
    reg [7:0]  fps_acc = 8'd0;
    reg [7:0]  fps     = 8'd0;

    always @(posedge clk_pix) begin
        if (rst_pix) begin
            sec_cnt <= 25'd0; fps_acc <= 8'd0; fps <= 8'd0;
        end else if (sec_cnt == PIX_FREQ - 1) begin
            sec_cnt <= 25'd0;
            fps     <= fps_acc;
            fps_acc <= 8'd0;
        end else begin
            sec_cnt <= sec_cnt + 25'd1;
            if (fstart_d && (fps_acc != 8'hFF)) fps_acc <= fps_acc + 8'd1;
        end
    end

    //------------------------------------------------------------------------
    // Host interface: Vivado's jtag_axi master, over the same USB cable that
    // carries the bitstream, into an AXI4 slave that can write the frame store
    // and read the star list back. See axi_bench_if.v for why this is the only
    // route a PL-only design has on this board.
    //------------------------------------------------------------------------
    wire        fb_we, swap_req;
    wire [13:0] fb_addr;
    wire [31:0] fb_data;
    wire        host_scroll_en, host_hold, host_override, host_step;

    wire [31:0] ax_awaddr,  ax_araddr,  ax_wdata,  ax_rdata;
    wire [7:0]  ax_awlen,   ax_arlen;
    wire [3:0]  ax_wstrb;
    wire [1:0]  ax_bresp,   ax_rresp;
    wire        ax_awvalid, ax_awready, ax_wvalid, ax_wready, ax_wlast;
    wire        ax_bvalid,  ax_bready,  ax_arvalid, ax_arready;
    wire        ax_rvalid,  ax_rready,  ax_rlast;

`ifdef SIM
    assign ax_awaddr  = 32'd0;  assign ax_awlen  = 8'd0;  assign ax_awvalid = 1'b0;
    assign ax_wdata   = 32'd0;  assign ax_wstrb  = 4'd0;  assign ax_wvalid  = 1'b0;
    assign ax_wlast   = 1'b0;   assign ax_bready = 1'b1;
    assign ax_araddr  = 32'd0;  assign ax_arlen  = 8'd0;  assign ax_arvalid = 1'b0;
    assign ax_rready  = 1'b1;
`else
    jtag_axi_0 u_jtag_axi (
        .aclk          ( clk_pix    ),
        .aresetn       ( ~rst_pix   ),
        .m_axi_awid    (            ),
        .m_axi_awaddr  ( ax_awaddr  ),
        .m_axi_awlen   ( ax_awlen   ),
        .m_axi_awsize  (            ),
        .m_axi_awburst (            ),
        .m_axi_awlock  (            ),
        .m_axi_awcache (            ),
        .m_axi_awprot  (            ),
        .m_axi_awqos   (            ),
        .m_axi_awvalid ( ax_awvalid ),
        .m_axi_awready ( ax_awready ),
        .m_axi_wdata   ( ax_wdata   ),
        .m_axi_wstrb   ( ax_wstrb   ),
        .m_axi_wlast   ( ax_wlast   ),
        .m_axi_wvalid  ( ax_wvalid  ),
        .m_axi_wready  ( ax_wready  ),
        .m_axi_bid     ( 1'b0       ),
        .m_axi_bresp   ( ax_bresp   ),
        .m_axi_bvalid  ( ax_bvalid  ),
        .m_axi_bready  ( ax_bready  ),
        .m_axi_arid    (            ),
        .m_axi_araddr  ( ax_araddr  ),
        .m_axi_arlen   ( ax_arlen   ),
        .m_axi_arsize  (            ),
        .m_axi_arburst (            ),
        .m_axi_arlock  (            ),
        .m_axi_arcache (            ),
        .m_axi_arprot  (            ),
        .m_axi_arqos   (            ),
        .m_axi_arvalid ( ax_arvalid ),
        .m_axi_arready ( ax_arready ),
        .m_axi_rid     ( 1'b0       ),
        .m_axi_rdata   ( ax_rdata   ),
        .m_axi_rresp   ( ax_rresp   ),
        .m_axi_rlast   ( ax_rlast   ),
        .m_axi_rvalid  ( ax_rvalid  ),
        .m_axi_rready  ( ax_rready  )
    );
`endif

    axi_bench_if u_axi (
        .aclk           ( clk_pix        ),
        .aresetn        ( ~rst_pix       ),
        .s_awaddr       ( ax_awaddr[19:0] ),
        .s_awlen        ( ax_awlen       ),
        .s_awvalid      ( ax_awvalid     ),
        .s_awready      ( ax_awready     ),
        .s_wdata        ( ax_wdata       ),
        .s_wstrb        ( ax_wstrb       ),
        .s_wlast        ( ax_wlast       ),
        .s_wvalid       ( ax_wvalid      ),
        .s_wready       ( ax_wready      ),
        .s_bresp        ( ax_bresp       ),
        .s_bvalid       ( ax_bvalid      ),
        .s_bready       ( ax_bready      ),
        .s_araddr       ( ax_araddr[19:0] ),
        .s_arlen        ( ax_arlen       ),
        .s_arvalid      ( ax_arvalid     ),
        .s_arready      ( ax_arready     ),
        .s_rdata        ( ax_rdata       ),
        .s_rresp        ( ax_rresp       ),
        .s_rlast        ( ax_rlast       ),
        .s_rvalid       ( ax_rvalid      ),
        .s_rready       ( ax_rready      ),
        .fb_we          ( fb_we          ),
        .fb_addr        ( fb_addr        ),
        .fb_data        ( fb_data        ),
        .sl_addr        ( rd2_addr       ),
        .sl_x           ( rd2_x          ),
        .sl_y           ( rd2_y          ),
        .sl_sum         ( rd2_sum        ),
        .sl_npx         ( rd2_npx        ),
        .star_count     ( star_count     ),
        .dropped        ( dropped        ),
        .overflow       ( overflow       ),
        .frame_count    ( frame_count    ),
        .fps            ( fps            ),
        .bg_code        ( bg_code        ),
        .thr_code       ( thr_code       ),
        .mad_acc        ( mad_acc        ),
        .scroll_x       ( scroll_x       ),
        .play_buf       ( play_buf       ),
        .swap_req       ( swap_req       ),
        .host_scroll_en ( host_scroll_en ),
        .host_hold      ( host_hold      ),
        .host_override  ( host_override  ),
        .host_step      ( host_step      )
    );

    //------------------------------------------------------------------------
    // Display timing
    //------------------------------------------------------------------------

    vga_sync_gen u_vga (
        .clk_pix        ( clk_pix        ),
        .rst            ( rst_pix        ),
        .vga_hsync      (                ),
        .vga_vsync      (                ),
        .vga_hsync_p    ( vga_hsync_p    ),
        .vga_vsync_p    ( vga_vsync_p    ),
        .vga_active     ( vga_active     ),
        .vga_pixel_x    ( vga_pixel_x    ),
        .vga_pixel_y    ( vga_pixel_y    ),
        .vga_frame_tick ( vga_frame_tick )
    );

    // The frame store registers its output, so everything else is delayed one
    // clock to match it - the same arrangement top_starfront uses.
    reg       hsync_d = 1'b0, vsync_d = 1'b0, active_d = 1'b0;
    reg [9:0] px_d = 10'd0, py_d = 10'd0;

    always @(posedge clk_pix) begin
        hsync_d  <= vga_hsync_p;
        vsync_d  <= vga_vsync_p;
        active_d <= vga_active;
        px_d     <= vga_pixel_x;
        py_d     <= vga_pixel_y;
    end

    //------------------------------------------------------------------------
    // Markers and text, both combinational on the delayed coordinates so they
    // line up with the image without a pipeline of their own.
    //------------------------------------------------------------------------
    wire mark;

    star_marker #(
        .CROP_X0(CROP_X0), .CROP_Y0(CROP_Y0),
        .CROP_W(CROP_WH), .CROP_H(CROP_WH)
    ) u_mark (
        .clk        ( clk_pix    ),
        .rst        ( rst_pix    ),
        .pixel_x    ( px_d       ),
        .pixel_y    ( py_d       ),
        .star_count ( star_count ),
        .rd_addr    ( rd_addr    ),
        .rd_x       ( rd_x       ),
        .rd_y       ( rd_y       ),
        .mark       ( mark       )
    );

    wire       in_panel;
    wire [7:0] pan_r, pan_g, pan_b;

    bench_panel u_panel (
        .pixel_x     ( px_d               ),
        .pixel_y     ( py_d               ),
        .star_count  ( {1'b0, star_count} ),
        .dropped     ( {1'b0, dropped}    ),
        .overflow    ( overflow           ),
        .frame_count ( frame_count        ),
        .fps         ( fps                ),
        .bg_code     ( bg_code            ),
        .thr_code    ( thr_code           ),
        .mad_acc     ( mad_acc            ),
        .best_x      ( best_x             ),
        .best_y      ( best_y             ),
        .best_sum    ( best_sum           ),
        .scroll_x    ( scroll_x           ),
        .in_panel    ( in_panel           ),
        .r           ( pan_r              ),
        .g           ( pan_g              ),
        .b           ( pan_b              )
    );

    wire in_image = (px_d < 10'd480) && (py_d < 10'd480);

    reg [7:0] pix_r, pix_g, pix_b;

    always @(*) begin
        if (!active_d) begin
            pix_r = 8'h00; pix_g = 8'h00; pix_b = 8'h00;
        end else if (in_image) begin
            if (mark) begin
                pix_r = 8'hFF; pix_g = 8'h40; pix_b = 8'h20;
            end else begin
                pix_r = disp_data; pix_g = disp_data; pix_b = disp_data;
            end
        end else if (in_panel) begin
            pix_r = pan_r; pix_g = pan_g; pix_b = pan_b;
        end else begin
            pix_r = 8'h08; pix_g = 8'h08; pix_b = 8'h10;
        end
    end

    dvi_tx u_dvi_tx (
        .clk_pix    ( clk_pix    ),
        .clk_ser    ( clk_ser    ),
        .rst        ( rst_pix    ),
        .r          ( pix_r      ),
        .g          ( pix_g      ),
        .b          ( pix_b      ),
        .hsync      ( hsync_d    ),
        .vsync      ( vsync_d    ),
        .de         ( active_d   ),
        .tmds_clk_p ( hdmi_clk_p ),
        .tmds_clk_n ( hdmi_clk_n ),
        .tmds_d_p   ( hdmi_d_p   ),
        .tmds_d_n   ( hdmi_d_n   )
    );

    assign hdmi_out_en = 1'b1;

    //------------------------------------------------------------------------
    // LEDs (active low)
    //------------------------------------------------------------------------
    reg [23:0] heartbeat = 24'd0;
    always @(posedge clk_pix) heartbeat <= heartbeat + 24'd1;

    wire [3:0] led = { overflow,              // LED4
                       (dropped != 7'd0),     // LED3
                       scroll_en_eff & ~hold_eff, // LED2
                       heartbeat[23] };       // LED1
    assign led_n = ~led;

`ifndef SIM
    ila_0 u_ila (
        .clk    ( clk_pix ),
        .probe0 ( {best_y, best_x}                                  ),
        .probe1 ( {1'b0, star_count}                                ),
        .probe2 ( {1'b0, dropped[3:0]}                              ),
        .probe3 ( {overflow, host_override, play_buf, src_fstart}   ),
        .probe4 ( {best_sum, mad_acc[13:6], thr_code, bg_code}      )
    );
`endif

endmodule
