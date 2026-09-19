`timescale 1ns / 1ps

//============================================================================
// Module: top_starfront
// Description: OV7670 top level for the ALINX AX7010 (xc7z010clg400-1).
//              PL-only: the Zynq PS is not instantiated, so the bitstream is
//              loaded straight over JTAG.
//
//   ENABLE_STARS picks between three builds from one source tree:
//
//     0  camera bring-up only. Clocking, HDMI, SCCB, camera init, the stream
//        geometry probe and the live picture - milestones M0 to M4, and the
//        thing to show when the question is "does the camera work".
//     1  the above plus the streaming peak detector of M5 (star_detect), which
//        marks the brightest point. Hardware-proven on a torch in a dark room.
//     2  the above with the sub-pixel centroiding pipeline from the bench
//        (star_centroid) running on the live camera at its full 640x480, a
//        cross on every star it lists, and the star-field register profile
//        on KEY3 - milestone M7. The `tracker` build is this one.
//
//   scripts/build.sh builds any of them; they land as separate bitstreams.
//
//   Milestones in this build:
//     M1  50 MHz PL_GCLK -> MMCM -> 25 MHz pixel + 125 MHz serial, DVI out on
//         the board's HDMI connector, XCLK forwarded to the camera
//     M2  SCCB master with read, camera ID probe
//     M3  94-register camera init, and a probe that measures what the sensor
//         is really emitting (bytes per line, lines per frame, PCLK, fps)
//     M4  320x240 8-bit luminance frame buffer, pixel-doubled back to 640x480.
//         The sensor runs in YUV422 and only Y is kept: the picture is gray,
//         the buffer is half what RGB565 cost, and the star path gets the
//         sensor's own luminance instead of one approximated from colour.
//     M5  streaming star detection at the camera's full 640x480, with no frame
//         buffer at all - see star_detect.v for why that is the right shape
//     M7  star_centroid on the camera: per-column background, 9x9 region
//         growing, centre of gravity to 1/256 pixel, up to 64 stars a frame,
//         and a sensor profile with exposure, gain, gamma and the de-noise
//         blocks set for stars rather than for a pleasant picture
//
//   Controls:
//     KEY1  reset
//     KEY2  hold to force the status overlay while a live image is showing
//     KEY3  toggle the sensor's built-in 8-bar test pattern - a descending
//           gray staircase in Y, white on the left to black on the right.
//           In the M7 build KEY3 instead toggles the star-field register
//           profile (astro), and KEY2 held + KEY3 steps its exposure/gain
//           preset 0-3; both show on the overlay's row 0, see below.
//     KEY4  step the horizontal window position, 0-3, shown on the overlay.
//           Use it if the picture has a band of junk down one edge: that is
//           the sensor's window sitting over its dummy columns, and no amount
//           of FPGA-side work can recover it.
//     KEY2 + KEY4  (KEY4 pressed while KEY2 is held) swap which byte of each
//           YUV422 pair is taken as Y. The overlay's window digit reads 4
//           higher while swapped. Use it if the picture is a fine vertical
//           comb or the test bars are bright and dark in the wrong order:
//           that is the chroma byte being displayed instead of the luma.
//
//   LEDs (active low on this board, so lit means the signal is high):
//     LED1  heartbeat        LED2  camera ID ok
//     LED3  init done        LED4  stream geometry ok
//
//   SCCB ownership passes from sccb_probe to ov7670_init the moment the camera
//   answers with the right product ID; until then the probe keeps retrying, so
//   the camera can be plugged in with the bitstream already running.
//============================================================================

module top_starfront #(
    parameter integer ENABLE_STARS = 1
) (
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
    wire key4_pressed;   // step the horizontal window

    key_debounce #(.CLK_FREQ(PIX_FREQ)) u_key2 (
        .clk ( clk_pix ), .key_raw ( ~key_n[1] ), .key_stable ( key2_pressed )
    );
    key_debounce #(.CLK_FREQ(PIX_FREQ)) u_key3 (
        .clk ( clk_pix ), .key_raw ( ~key_n[2] ), .key_stable ( key3_pressed )
    );
    key_debounce #(.CLK_FREQ(PIX_FREQ)) u_key4 (
        .clk ( clk_pix ), .key_raw ( ~key_n[3] ), .key_stable ( key4_pressed )
    );

    // KEY4 steps through the four window positions on each press.
    // Position 1 is the default because it is the one that came out clean on
    // this board - position 0, inherited from the Basys 3 project, put the
    // sensor's dummy columns inside the captured window and produced a band of
    // junk down the right edge.
    //
    // With KEY2 held, KEY4 instead toggles y_second: which byte of each YUV422
    // pair the capture logic takes as luminance. The register table asks the
    // sensor for Y first, but the sensor's own default is Y second and the two
    // are one bit apart in TSLB, so the choice is made reversible on the bench
    // rather than being trusted to a datasheet reading.
    //
    // In the M7 build KEY3 is the star-field profile: a press toggles astro,
    // and a press with KEY2 held steps the exposure/gain preset. The consumer
    // profile is the power-up default so the first picture is a recognisable
    // one; astro is what to switch to once the lens is pointed at the sky.
    // The bring-up builds keep KEY3 as the test-pattern key.
    localparam [1:0] HSTART_DEFAULT = 2'd1;
    localparam       Y_SECOND_DEFAULT = 1'b0;
    localparam       ASTRO_KEYS = (ENABLE_STARS == 2);

    reg [1:0] hstart_sel = HSTART_DEFAULT;
    reg       y_second   = Y_SECOND_DEFAULT;
    reg       astro      = 1'b0;
    reg [1:0] preset     = 2'd0;
    reg       key3_prev  = 1'b0;
    reg       key4_prev  = 1'b0;

    always @(posedge clk_pix) begin
        if (rst_pix) begin
            hstart_sel <= HSTART_DEFAULT;
            y_second   <= Y_SECOND_DEFAULT;
            astro      <= 1'b0;
            preset     <= 2'd0;
            key3_prev  <= 1'b0;
            key4_prev  <= 1'b0;
        end else begin
            key3_prev <= key3_pressed;
            key4_prev <= key4_pressed;
            if (key4_pressed && !key4_prev) begin
                if (key2_pressed)
                    y_second   <= ~y_second;
                else
                    hstart_sel <= hstart_sel + 2'd1;
            end
            if (ASTRO_KEYS && key3_pressed && !key3_prev) begin
                if (key2_pressed)
                    preset <= preset + 2'd1;
                else
                    astro  <= ~astro;
            end
        end
    end

    wire color_bar_in = ASTRO_KEYS ? 1'b0 : key3_pressed;

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
        .color_bar     ( color_bar_in  ),
        .hstart_sel    ( hstart_sel    ),
        .astro         ( astro         ),
        .preset        ( preset        ),
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

    // The byte select is a quasi-static control bit from the pixel domain;
    // one synchroniser takes it into the camera domain for both consumers.
    wire y_second_p;
    cdc_sync #(.WIDTH(1)) u_sy_ysel (.clk(cam_pclk), .din(y_second), .dout(y_second_p));

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

    //------------------------------------------------------------------------
    // Full resolution tap for the star detector, built only when asked for.
    // This runs at 640x480 - the display path's 2:1 downsample would throw
    // away three quarters of the sky.
    //------------------------------------------------------------------------
    wire [7:0] star_count_s, star_thresh_s, star_max_s;
    wire [9:0] bright_x_s, bright_y_s;
    wire [31:0] row3_s;                 // the overlay's fourth row, per build

    // M7 star list, read by the marker in the pixel domain. The published
    // bank is static for a whole camera frame, so an asynchronous read of it
    // is safe except for the cycle the bank flips - one wrong marker pixel,
    // once a frame, in a place the eye cannot find.
    wire [5:0]  m7_rd_addr;
    wire [17:0] m7_rd_x, m7_rd_y;
    wire [6:0]  m7_count_x;

    generate
    if (ENABLE_STARS == 1) begin : g_stars

        wire        pix_valid;
        wire [9:0]  pix_x, pix_y;
        wire [7:0]  pix_luma;
        wire        cam_frame_start;

        cam_pixel_stream u_pixel_stream (
            .pclk        ( cam_pclk        ),
            .href        ( ov7670_href     ),
            .vsync       ( ov7670_vsync    ),
            .data        ( ov7670_data     ),
            .y_second    ( y_second_p      ),
            .pix_valid   ( pix_valid       ),
            .pix_x       ( pix_x           ),
            .pix_y       ( pix_y           ),
            .pix_luma    ( pix_luma        ),
            .frame_start ( cam_frame_start )
        );

        wire [7:0]  count_p, thresh_p, max_p;
        wire [9:0]  bx_p, by_p;
        wire [12:0] bsum_p;
        wire        tog_p;

        star_detect u_star_detect (
            .pclk        ( cam_pclk        ),
            .rst         ( 1'b0            ),
            .pix_valid   ( pix_valid       ),
            .pix_x       ( pix_x           ),
            .pix_y       ( pix_y           ),
            .pix_luma    ( pix_luma        ),
            .frame_start ( cam_frame_start ),
            .star_count  ( count_p         ),
            .threshold   ( thresh_p        ),
            .frame_max   ( max_p           ),
            .bright_x    ( bx_p            ),
            .bright_y    ( by_p            ),
            .bright_sum  ( bsum_p          ),
            .result_tog  ( tog_p           )
        );

        // Results cross into the pixel domain on the same toggle handshake
        // cam_stream_probe uses: the values sit still for a whole frame behind
        // the toggle, so by the time it has been through the synchroniser they
        // are long settled.
        wire       tog_x;
        wire [7:0] count_x, thresh_x, max_x;
        wire [9:0] bx_x, by_x;

        cdc_sync #(.WIDTH(1))  u_sy_tog (.clk(clk_pix), .din(tog_p),    .dout(tog_x));
        cdc_sync #(.WIDTH(8))  u_sy_cnt (.clk(clk_pix), .din(count_p),  .dout(count_x));
        cdc_sync #(.WIDTH(8))  u_sy_thr (.clk(clk_pix), .din(thresh_p), .dout(thresh_x));
        cdc_sync #(.WIDTH(8))  u_sy_max (.clk(clk_pix), .din(max_p),    .dout(max_x));
        cdc_sync #(.WIDTH(10)) u_sy_bx  (.clk(clk_pix), .din(bx_p),     .dout(bx_x));
        cdc_sync #(.WIDTH(10)) u_sy_by  (.clk(clk_pix), .din(by_p),     .dout(by_x));

        reg [7:0] count_r  = 8'd0;
        reg [7:0] thresh_r = 8'd0;
        reg [7:0] max_r    = 8'd0;
        reg [9:0] bx_r     = 10'd0;
        reg [9:0] by_r     = 10'd0;
        reg       tog_d    = 1'b0;

        always @(posedge clk_pix) begin
            tog_d <= tog_x;
            if (tog_x != tog_d) begin
                count_r  <= count_x;
                thresh_r <= thresh_x;
                max_r    <= max_x;
                bx_r     <= bx_x;
                by_r     <= by_x;
            end
        end

        assign star_count_s  = count_r;
        assign star_thresh_s = thresh_r;
        assign star_max_s    = max_r;
        assign bright_x_s    = bx_r;
        assign bright_y_s    = by_r;
        // stars found, detection threshold, brightest pixel in the frame
        assign row3_s        = {count_r, thresh_r, max_r, 8'h00};

        assign m7_rd_x       = 18'd0;
        assign m7_rd_y       = 18'd0;
        assign m7_count_x    = 7'd0;

    end else if (ENABLE_STARS == 2) begin : g_astro

        wire        pix_valid;
        wire [9:0]  pix_x, pix_y;
        wire [7:0]  pix_luma;
        wire        cam_frame_start;

        cam_pixel_stream u_pixel_stream (
            .pclk        ( cam_pclk        ),
            .href        ( ov7670_href     ),
            .vsync       ( ov7670_vsync    ),
            .data        ( ov7670_data     ),
            .y_second    ( y_second_p      ),
            .pix_valid   ( pix_valid       ),
            .pix_x       ( pix_x           ),
            .pix_y       ( pix_y           ),
            .pix_luma    ( pix_luma        ),
            .frame_start ( cam_frame_start )
        );

        // Reset into the camera domain. Every register in the detector has a
        // power-up value, so this only matters for KEY1 - and it cannot land
        // while the camera is not clocking, which is also when it cannot matter.
        wire rst_cam;
        cdc_sync #(.WIDTH(1)) u_sy_rst (.clk(cam_pclk), .din(rst_pix), .dout(rst_cam));

        wire [6:0]  count_p, drop_p;
        wire [7:0]  bg_p, thr_p;
        wire [13:0] mad_p;
        wire [17:0] best_x_p, best_y_p;
        wire [19:0] best_sum_p;
        wire [15:0] fcnt_p;

        // The bench's detector, at the camera's geometry: 640x480, no binning,
        // and no field-of-view mask - the lens is whatever is on the sensor.
        star_centroid #(
            .IMG_W(640), .IMG_H(480), .XW(10), .YW(9), .CW(18),
            .FOV_CX(320), .FOV_CY(240), .FOV_R(0)
        ) u_det (
            .clk           ( cam_pclk        ),
            .rst           ( rst_cam         ),
            .in_valid      ( pix_valid       ),
            .in_x          ( pix_x           ),
            .in_y          ( pix_y[8:0]      ),
            .in_code       ( pix_luma        ),
            .frame_start   ( cam_frame_start ),
            .fov_ox        ( 6'sd0           ),
            .fov_oy        ( 6'sd0           ),
            .star_count    ( count_p         ),
            .dropped       ( drop_p          ),
            .overflow      (                 ),
            .best_x        ( best_x_p        ),
            .best_y        ( best_y_p        ),
            .best_sum      ( best_sum_p      ),
            .frame_count   ( fcnt_p          ),
            .rd_addr       ( m7_rd_addr      ),
            .rd_x          ( m7_rd_x         ),
            .rd_y          ( m7_rd_y         ),
            .rd_sum        (                 ),
            .rd_npx        (                 ),
            .rd2_addr      ( 6'd0            ),
            .rd2_x         (                 ),
            .rd2_y         (                 ),
            .rd2_sum       (                 ),
            .rd2_npx       (                 ),
            .bg_code       ( bg_p            ),
            .thr_grow_code ( thr_p           ),
            .mad_acc       ( mad_p           )
        );

        // Per-frame numbers for the overlay cross on the toggle handshake the
        // M5 path uses. The background and threshold change every column, so
        // they are snapshotted at the frame boundary first; the toggle flips
        // one cycle after everything behind it has settled.
        reg [7:0] bg_snap = 8'd0, thr_snap = 8'd0;
        reg       fs_d    = 1'b0;
        reg       tog_p   = 1'b0;

        always @(posedge cam_pclk) begin
            fs_d <= cam_frame_start;
            if (cam_frame_start) begin
                bg_snap  <= bg_p;
                thr_snap <= thr_p;
            end
            if (fs_d)
                tog_p <= ~tog_p;
        end

        wire       tog_x;
        wire [6:0] count_x, drop_x;
        wire [7:0] bg_x, thr_x;

        cdc_sync #(.WIDTH(1)) u_sy_tog (.clk(clk_pix), .din(tog_p),    .dout(tog_x));
        cdc_sync #(.WIDTH(7)) u_sy_cnt (.clk(clk_pix), .din(count_p),  .dout(count_x));
        cdc_sync #(.WIDTH(7)) u_sy_drp (.clk(clk_pix), .din(drop_p),   .dout(drop_x));
        cdc_sync #(.WIDTH(8)) u_sy_bg  (.clk(clk_pix), .din(bg_snap),  .dout(bg_x));
        cdc_sync #(.WIDTH(8)) u_sy_thr (.clk(clk_pix), .din(thr_snap), .dout(thr_x));

        reg [6:0] count_r = 7'd0, drop_r = 7'd0;
        reg [7:0] bg_r    = 8'd0, thr_r  = 8'd0;
        reg       tog_d   = 1'b0;

        always @(posedge clk_pix) begin
            tog_d <= tog_x;
            if (tog_x != tog_d) begin
                count_r <= count_x;
                drop_r  <= drop_x;
                bg_r    <= bg_x;
                thr_r   <= thr_x;
            end
        end

        assign m7_count_x    = count_r;
        assign star_count_s  = {1'b0, count_r};
        assign star_thresh_s = thr_r;
        assign star_max_s    = bg_r;
        assign bright_x_s    = 10'd0;
        assign bright_y_s    = 10'd0;
        // stars listed, grow threshold, background, seeds dropped
        assign row3_s        = {1'b0, count_r, thr_r, bg_r, 1'b0, drop_r};

    end else begin : g_no_stars

        assign star_count_s  = 8'd0;
        assign star_thresh_s = 8'd0;
        assign star_max_s    = 8'd0;
        assign bright_x_s    = 10'd0;
        assign bright_y_s    = 10'd0;
        assign row3_s        = 32'd0;
        assign m7_rd_x       = 18'd0;
        assign m7_rd_y       = 18'd0;
        assign m7_count_x    = 7'd0;

    end
    endgenerate

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
    wire [7:0]  cap_data;

    cam_capture u_cam_capture (
        .ov7670_pclk  ( cam_pclk     ),
        .ov7670_href  ( ov7670_href  ),
        .ov7670_vsync ( ov7670_vsync ),
        .ov7670_data  ( ov7670_data  ),
        .y_second     ( y_second_p   ),
        .cap_wr_en    ( cap_wr_en    ),
        .cap_addr     ( cap_addr     ),
        .cap_data     ( cap_data     )
    );

    wire [16:0] fb_addr_rd;
    wire [7:0]  fb_data_rd;

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
    reg       hsync_d   = 1'b0;
    reg       vsync_d   = 1'b0;
    reg       active_d  = 1'b0;
    reg [9:0] pixel_x_d = 10'd0;
    reg [9:0] pixel_y_d = 10'd0;

    always @(posedge clk_pix) begin
        hsync_d   <= vga_hsync_p;
        vsync_d   <= vga_vsync_p;
        active_d  <= vga_active;
        pixel_x_d <= vga_pixel_x;   // for the star marker, which must line up
        pixel_y_d <= vga_pixel_y;   // with the picture rather than the address
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
        // digits: PID VER, then {astro, preset, 0, 0, y_second, hstart_sel}
        // as two hex digits, then the register read-back. 01 is the consumer
        // profile with the default window; 81/A1/C1/E1 are astro presets 0-3;
        // +4 on the low digit means the Y byte is swapped.
        .row0         ( {cam_pid, cam_ver, astro, preset, 2'b0, y_second, hstart_sel, cam_readback} ),
        .row1         ( {bytes_per_line, lines_per_frame}       ),
        .row2         ( {8'h00, pclk_freq_100k, 8'h00, frames_per_sec} ),
        .row3         ( row3_s ),
        .row3_en      ( ENABLE_STARS != 0 ),
        .row4_bits    ( {cam_id_ok, cam_rw_ok, init_done, stream_ok,
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

    //------------------------------------------------------------------------
    // Markers. The detectors work in the camera's 640x480 coordinates and the
    // screen is 640x480, so a position needs no scaling - a 320x240 buffer
    // pixel-doubled lands exactly on it. M5 draws one cross on the brightest
    // point; M7 draws one on every star in the list, with the same list
    // walker the bench uses. The middle of a cross is left open so the star
    // itself stays visible, and it is red, the only colour on a gray picture.
    //------------------------------------------------------------------------
    wire show_mark;

    generate
    if (ENABLE_STARS == 1) begin : g_mark5

        wire [9:0] mark_dx = (pixel_x_d > bright_x_s) ? (pixel_x_d - bright_x_s)
                                                      : (bright_x_s - pixel_x_d);
        wire [9:0] mark_dy = (pixel_y_d > bright_y_s) ? (pixel_y_d - bright_y_s)
                                                      : (bright_y_s - pixel_y_d);

        wire mark_arm_h = (mark_dy == 10'd0) && (mark_dx >= 10'd4) && (mark_dx <= 10'd12);
        wire mark_arm_v = (mark_dx == 10'd0) && (mark_dy >= 10'd4) && (mark_dy <= 10'd12);
        assign show_mark  = (star_count_s != 8'd0) && (mark_arm_h || mark_arm_v);
        assign m7_rd_addr = 6'd0;

    end else if (ENABLE_STARS == 2) begin : g_mark7

        star_marker #(
            .CROP_X0(0), .CROP_Y0(0), .CROP_W(640), .CROP_H(480),
            .SCALE_SHIFT(0), .CW(18), .FRAC(8)
        ) u_mark (
            .clk        ( clk_pix    ),
            .rst        ( rst_pix    ),
            .pixel_x    ( pixel_x_d  ),
            .pixel_y    ( pixel_y_d  ),
            .star_count ( m7_count_x ),
            .rd_addr    ( m7_rd_addr ),
            .rd_x       ( m7_rd_x    ),
            .rd_y       ( m7_rd_y    ),
            .mark       ( show_mark  )
        );

    end else begin : g_mark0

        assign show_mark  = 1'b0;
        assign m7_rd_addr = 6'd0;

    end
    endgenerate

    wire [7:0] src_r = show_overlay ? ovl_r_d : img_r;
    wire [7:0] src_g = show_overlay ? ovl_g_d : img_g;
    wire [7:0] src_b = show_overlay ? ovl_b_d : img_b;

    wire [7:0] pix_r = (show_mark && !show_overlay) ? 8'hFF : src_r;
    wire [7:0] pix_g = (show_mark && !show_overlay) ? 8'h20 : src_g;
    wire [7:0] pix_b = (show_mark && !show_overlay) ? 8'h20 : src_b;

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
        .probe3 ( {data_alive, href_alive, vsync_alive, pclk_alive} ),
        .probe4 ( {bright_y_s, bright_x_s, star_max_s, star_thresh_s, star_count_s} )
    );
`endif

endmodule
