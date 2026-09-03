`timescale 1ns / 1ps

//============================================================================
// Module: top_starfront_bringup
// Description: OV7670 bring-up top level for the ALINX AX7010 (xc7z010clg400-1).
//              PL-only: the Zynq PS is not instantiated, so the bitstream is
//              loaded straight over JTAG.
//
//   Milestones in this build:
//     M1  50 MHz PL_GCLK -> MMCM -> 25 MHz pixel + 125 MHz serial, DVI out on
//         the board's HDMI connector, XCLK forwarded to the camera
//     M2  SCCB master with read, camera ID probe
//     M3  94-register camera init, and a probe that measures what the sensor
//         is really emitting (bytes per line, lines per frame, PCLK, fps)
//     M4  320x240 RGB444 frame buffer, pixel-doubled back to 640x480
//
//   Controls:
//     KEY1  reset
//     KEY2  hold to force the status overlay while a live image is showing
//     KEY3  toggle the sensor's built-in colour bar test pattern
//
//   LEDs (active low on this board, so lit means the signal is high):
//     LED1  heartbeat        LED2  camera ID ok
//     LED3  init done        LED4  stream geometry ok
//
//   SCCB ownership passes from sccb_probe to ov7670_init the moment the camera
//   answers with the right product ID; until then the probe keeps retrying, so
//   the camera can be plugged in with the bitstream already running.
//============================================================================

module top_starfront_bringup (
    // Clock and buttons
    input  wire        sys_clk,        // U18, 50 MHz PL_GCLK
    input  wire [3:0]  key_n,          // KEY1..KEY4, active low
    output wire [3:0]  led_n,          // LED1..LED4, active low

    // HDMI (DVI-D out, raw TMDS from PL bank 34)
    output wire        hdmi_clk_p,
    output wire        hdmi_clk_n,
    output wire [2:0]  hdmi_d_p,
    output wire [2:0]  hdmi_d_n,
    output wire        hdmi_out_en,    // enables the +5V supply to the sink
    input  wire        hdmi_hpd,

    // OV7670 on expansion header J11 (bank 35, 3.3 V)
    output wire        ov7670_xclk,
    input  wire        ov7670_pclk,
    input  wire        ov7670_href,
    input  wire        ov7670_vsync,
    input  wire [7:0]  ov7670_data,
    output wire        ov7670_sioc,
    inout  wire        ov7670_siod,
    output wire        ov7670_reset_n,
    output wire        ov7670_pwdn
);

    localparam integer PIX_FREQ = 25_000_000;

    //------------------------------------------------------------------------
    // Clocking: one MMCM, so clk_ser is exactly 5x clk_pix and phase aligned
    // with it - which is what the 10:1 OSERDES pair needs.
    //------------------------------------------------------------------------
    wire clk_pix;
    wire clk_ser;
    wire mmcm_locked;

`ifdef SIM
    reg clk_pix_reg = 1'b0;
    reg clk_ser_reg = 1'b0;
    always @(posedge sys_clk) clk_pix_reg <= ~clk_pix_reg;   // 25 MHz from 50 MHz
    always @(posedge sys_clk) clk_ser_reg <= ~clk_ser_reg;   // stand-in only
    assign clk_pix     = clk_pix_reg;
    assign clk_ser     = clk_ser_reg;
    assign mmcm_locked = 1'b1;
`else
    clk_wiz_0 u_clk_wiz (
        .clk_in1  ( sys_clk     ),
        .clk_out1 ( clk_ser     ),   // 125 MHz
        .clk_out2 ( clk_pix     ),   //  25 MHz
        .locked   ( mmcm_locked )
    );
`endif

    //------------------------------------------------------------------------
    // Reset: KEY1 or an unlocked MMCM. Synchronous release in the pixel domain.
    //------------------------------------------------------------------------
    wire rst_raw = ~key_n[0] | ~mmcm_locked;

    reg [3:0] rst_sync = 4'hF;
    always @(posedge clk_pix) begin
        if (rst_raw) rst_sync <= 4'hF;
        else         rst_sync <= {rst_sync[2:0], 1'b0};
    end
    wire rst_pix = rst_sync[3];

    //------------------------------------------------------------------------
    // Debounced keys
    //------------------------------------------------------------------------
    wire key2_pressed;   // hold to show the overlay
    wire key3_pressed;   // toggle the sensor test pattern

    key_debounce #(.CLK_FREQ(PIX_FREQ)) u_key2 (
        .clk ( clk_pix ), .key_raw ( ~key_n[1] ), .key_stable ( key2_pressed )
    );
    key_debounce #(.CLK_FREQ(PIX_FREQ)) u_key3 (
        .clk ( clk_pix ), .key_raw ( ~key_n[2] ), .key_stable ( key3_pressed )
    );

    //------------------------------------------------------------------------
    // Camera clock and power sequencing
    //   XCLK is clock-forwarded through an ODDR so it leaves the pin as a clean
    //   clock rather than as fabric logic.
    //   RESET# is held low for ~2.6 ms after reset, then released.
    //------------------------------------------------------------------------
`ifdef SIM
    assign ov7670_xclk = clk_pix;
`else
    ODDR #(
        .DDR_CLK_EDGE ("OPPOSITE_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_xclk_oddr (
        .Q (ov7670_xclk), .C (clk_pix), .CE (1'b1),
        .D1(1'b1),        .D2(1'b0),    .R  (1'b0), .S (1'b0)
    );
`endif

    reg [15:0] cam_rst_cnt   = 16'd0;
    reg        cam_reset_n_r = 1'b0;

    always @(posedge clk_pix) begin
        if (rst_pix) begin
            cam_rst_cnt   <= 16'd0;
            cam_reset_n_r <= 1'b0;
        end else if (cam_rst_cnt != 16'hFFFF) begin
            cam_rst_cnt <= cam_rst_cnt + 16'd1;
        end else begin
            cam_reset_n_r <= 1'b1;
        end
    end

    assign ov7670_reset_n = cam_reset_n_r;
    assign ov7670_pwdn    = 1'b0;          // low = normal operation

    //------------------------------------------------------------------------
    // SCCB bus: one master, two users. The probe owns it until the camera has
    // identified itself, then ov7670_init takes over for the register table.
    //------------------------------------------------------------------------
    wire       sccb_done;
    wire       sccb_busy;
    wire [7:0] sccb_rd_data;
    wire [4:0] sccb_dbg_state;

    wire       probe_start, probe_rw, probe_locked;
    wire [7:0] probe_sub_addr, probe_wr_data;
    wire       init_start;
    wire [7:0] init_sub_addr, init_wr_data;

    wire       sccb_start    = probe_locked ? init_start    : probe_start;
    wire       sccb_rw       = probe_locked ? 1'b0          : probe_rw;
    wire [7:0] sccb_sub_addr = probe_locked ? init_sub_addr : probe_sub_addr;
    wire [7:0] sccb_wr_data  = probe_locked ? init_wr_data  : probe_wr_data;

    wire siod_out, siod_oe, siod_in;

`ifdef SIM
    assign ov7670_siod = siod_oe ? siod_out : 1'bz;
    assign siod_in     = ov7670_siod;
`else
    IOBUF u_siod_iobuf (
        .I (siod_out), .O (siod_in), .T (~siod_oe), .IO (ov7670_siod)
    );
`endif

    sccb_master #(
        .CLK_FREQ  ( PIX_FREQ ),
        .SCCB_FREQ ( 100_000  )
    ) u_sccb_master (
        .clk            ( clk_pix        ),
        .rst            ( rst_pix        ),
        .start          ( sccb_start     ),
        .rw             ( sccb_rw        ),
        .sub_addr       ( sccb_sub_addr  ),
        .wr_data        ( sccb_wr_data   ),
        .rd_data        ( sccb_rd_data   ),
        .busy           ( sccb_busy      ),
        .done           ( sccb_done      ),
        .sccb_sio_c     ( ov7670_sioc    ),
        .sccb_sio_d_out ( siod_out       ),
        .sccb_sio_d_oe  ( siod_oe        ),
        .sccb_sio_d_in  ( siod_in        ),
        .dbg_state      ( sccb_dbg_state )
    );

    wire [7:0] cam_pid, cam_ver, cam_readback;
    wire       cam_id_ok, cam_rw_ok, probe_done;
    wire [3:0] probe_dbg_state;

    sccb_probe #(.CLK_FREQ(PIX_FREQ)) u_sccb_probe (
        .clk           ( clk_pix         ),
        .rst           ( rst_pix         ),
        .sccb_start    ( probe_start     ),
        .sccb_rw       ( probe_rw        ),
        .sccb_sub_addr ( probe_sub_addr  ),
        .sccb_wr_data  ( probe_wr_data   ),
        .sccb_rd_data  ( sccb_rd_data    ),
        .sccb_done     ( sccb_done       ),
        .cam_pid       ( cam_pid         ),
        .cam_ver       ( cam_ver         ),
        .cam_readback  ( cam_readback    ),
        .cam_id_ok     ( cam_id_ok       ),
        .cam_rw_ok     ( cam_rw_ok       ),
        .probe_done    ( probe_done      ),
        .probe_locked  ( probe_locked    ),
        .dbg_state     ( probe_dbg_state )
    );

    wire init_done;

    ov7670_init #(.CLK_FREQ(PIX_FREQ)) u_ov7670_init (
        .clk           ( clk_pix       ),
        .rst           ( rst_pix | ~probe_locked ),   // held until the bus is ours
        .color_bar     ( key3_pressed  ),
        .init_done     ( init_done     ),
        .sccb_start    ( init_start    ),
        .sccb_sub_addr ( init_sub_addr ),
        .sccb_wr_data  ( init_wr_data  ),
        .sccb_done     ( sccb_done     )
    );

    //------------------------------------------------------------------------
    // Camera pixel bus
    //------------------------------------------------------------------------
    wire cam_pclk;

`ifdef SIM
    assign cam_pclk = ov7670_pclk;
`else
    BUFG u_pclk_bufg (.I(ov7670_pclk), .O(cam_pclk));
`endif

    wire pclk_alive, href_alive, vsync_alive, data_alive;

    cam_activity #(.CLK_FREQ(PIX_FREQ)) u_cam_activity (
        .clk         ( clk_pix      ),
        .rst         ( rst_pix      ),
        .cam_pclk    ( cam_pclk     ),
        .cam_href    ( ov7670_href  ),
        .cam_vsync   ( ov7670_vsync ),
        .cam_data    ( ov7670_data  ),
        .pclk_alive  ( pclk_alive   ),
        .href_alive  ( href_alive   ),
        .vsync_alive ( vsync_alive  ),
        .data_alive  ( data_alive   )
    );

    wire [15:0] bytes_per_line, lines_per_frame;
    wire [7:0]  frames_per_sec, pclk_freq_100k;
    wire        stream_ok;

    cam_stream_probe #(.CLK_FREQ(PIX_FREQ)) u_stream_probe (
        .clk             ( clk_pix         ),
        .rst             ( rst_pix         ),
        .cam_pclk        ( cam_pclk        ),
        .cam_href        ( ov7670_href     ),
        .cam_vsync       ( ov7670_vsync    ),
        .bytes_per_line  ( bytes_per_line  ),
        .lines_per_frame ( lines_per_frame ),
        .frames_per_sec  ( frames_per_sec  ),
        .pclk_freq_100k  ( pclk_freq_100k  ),
        .stream_ok       ( stream_ok       )
    );

    //------------------------------------------------------------------------
    // Capture into the frame buffer (camera domain) and read it back out
    // (pixel domain). The dual-clock block RAM is the clock domain crossing.
    //------------------------------------------------------------------------
    wire        cap_wr_en;
    wire [16:0] cap_addr;
    wire [11:0] cap_data;

    cam_capture u_cam_capture (
        .ov7670_pclk  ( cam_pclk     ),
        .ov7670_href  ( ov7670_href  ),
        .ov7670_vsync ( ov7670_vsync ),
        .ov7670_data  ( ov7670_data  ),
        .cap_wr_en    ( cap_wr_en    ),
        .cap_addr     ( cap_addr     ),
        .cap_data     ( cap_data     )
    );

    wire [16:0] fb_addr_rd;
    wire [11:0] fb_data_rd;

    fb_mem u_fb_mem (
        .clk_wr  ( cam_pclk   ),
        .wr_en   ( cap_wr_en  ),
        .addr_wr ( cap_addr   ),
        .data_wr ( cap_data   ),
        .clk_rd  ( clk_pix    ),
        .addr_rd ( fb_addr_rd ),
        .data_rd ( fb_data_rd )
    );

    //------------------------------------------------------------------------
    // Display timing
    //------------------------------------------------------------------------
    wire       vga_hsync_p, vga_vsync_p, vga_active, vga_frame_tick;
    wire [9:0] vga_pixel_x, vga_pixel_y;

    vga_sync_gen u_vga_sync (
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

    //------------------------------------------------------------------------
    // Two pixel sources, both arranged to have exactly one clock of latency so
    // the sync signals only need delaying once:
    //   image   - fb_addr_rd is combinational, the block RAM registers its data
    //   overlay - combinational, then registered here to match
    //------------------------------------------------------------------------
    reg hsync_d  = 1'b0;
    reg vsync_d  = 1'b0;
    reg active_d = 1'b0;

    always @(posedge clk_pix) begin
        hsync_d  <= vga_hsync_p;
        vsync_d  <= vga_vsync_p;
        active_d <= vga_active;
    end

    wire [7:0] img_r, img_g, img_b;

    // The read address must come from the UNDELAYED coordinate: the block RAM
    // supplies the one clock of latency all by itself. Feeding it the delayed
    // one made the picture two clocks late against a one-clock delayed de,
    // which shifted the whole image right by a pixel.
    fb_reader u_fb_reader (
        .pixel_x    ( vga_pixel_x ),
        .pixel_y    ( vga_pixel_y ),
        .active     ( active_d   ),
        .fb_addr_rd ( fb_addr_rd ),
        .fb_data_rd ( fb_data_rd ),
        .r          ( img_r      ),
        .g          ( img_g      ),
        .b          ( img_b      )
    );

    wire [1:0] banner_level = (!cam_id_ok) ? 2'd0 : (stream_ok ? 2'd2 : 2'd1);

    wire [7:0] ovl_r, ovl_g, ovl_b;

    status_overlay u_overlay (
        .clk_pix      ( clk_pix        ),
        .rst          ( rst_pix        ),
        .pixel_x      ( vga_pixel_x    ),
        .pixel_y      ( vga_pixel_y    ),
        .active       ( vga_active     ),
        .frame_tick   ( vga_frame_tick ),
        .row0         ( {cam_pid, cam_ver, 8'h00, cam_readback} ),
        .row1         ( {bytes_per_line, lines_per_frame}       ),
        .row2         ( {8'h00, pclk_freq_100k, 8'h00, frames_per_sec} ),
        .row3_bits    ( {cam_id_ok, cam_rw_ok, init_done, stream_ok,
                         data_alive, href_alive, vsync_alive, pclk_alive} ),
        .banner_level ( banner_level   ),
        .r            ( ovl_r          ),
        .g            ( ovl_g          ),
        .b            ( ovl_b          )
    );

    reg [7:0] ovl_r_d = 8'd0, ovl_g_d = 8'd0, ovl_b_d = 8'd0;
    always @(posedge clk_pix) begin
        ovl_r_d <= ovl_r;
        ovl_g_d <= ovl_g;
        ovl_b_d <= ovl_b;
    end

    // Show the numbers until the camera is configured, and whenever KEY2 is held
    wire show_overlay = key2_pressed | ~init_done;

    wire [7:0] pix_r = show_overlay ? ovl_r_d : img_r;
    wire [7:0] pix_g = show_overlay ? ovl_g_d : img_g;
    wire [7:0] pix_b = show_overlay ? ovl_b_d : img_b;

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
    // Status LEDs (active low)
    //------------------------------------------------------------------------
    reg [23:0] heartbeat_cnt = 24'd0;
    always @(posedge clk_pix) heartbeat_cnt <= heartbeat_cnt + 24'd1;

    wire [3:0] led = { stream_ok,               // LED4
                       init_done,               // LED3
                       cam_id_ok,               // LED2
                       heartbeat_cnt[23] };     // LED1
    assign led_n = ~led;

    //------------------------------------------------------------------------
    // ILA - for when the screen says the ID read failed and you need to see
    // the SCCB waveform to find out why.
    //------------------------------------------------------------------------
`ifndef SIM
    ila_0 u_ila (
        .clk    ( clk_pix ),
        .probe0 ( {cam_readback, cam_ver, cam_pid, probe_dbg_state} ),
        .probe1 ( {init_done, stream_ok, cam_id_ok, cam_rw_ok,
                   ov7670_sioc, siod_in, siod_oe, sccb_busy} ),
        .probe2 ( sccb_dbg_state ),
        .probe3 ( {data_alive, href_alive, vsync_alive, pclk_alive} )
    );
`endif

endmodule
