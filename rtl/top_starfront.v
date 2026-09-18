`timescale 1ns / 1ps

//============================================================================
// Module: top_starfront
// Description: OV7670 & AXI4-Stream Star Tracker Top Level for the ALINX AX7010
//              (xc7z010clg400-1).
//
//   ENABLE_STARS picks between two builds from one source tree:
//     0  camera bring-up only. Clocking, HDMI, SCCB, camera init, the stream
//        geometry probe and the live picture - milestones M0 to M4, and the
//        thing to show when the question is "does the camera work".
//     1  the above plus the streaming star detector (M5).
//
//   scripts/build.sh builds either; they land as separate bitstreams so both
//   stay available without rebuilding.
//
//   Milestones in this build:
//     M1  50 MHz PL_GCLK -> MMCM -> 25 MHz pixel + 125 MHz serial, DVI out on
//         the board's HDMI connector, XCLK forwarded to the camera
//     M2  SCCB master with read, camera ID probe
//     M3  94-register camera init, and a probe that measures what the sensor
//         is really emitting (bytes per line, lines per frame, PCLK, fps)
//     M4  320x240 RGB565 frame buffer, pixel-doubled back to 640x480
//     M5  streaming star detection at the camera's full 640x480, with no frame
//         buffer at all - see star_detect.v for why that is the right shape
//
//   Dual-Source Video Architecture:
//     1. Physical OV7670 camera on expansion header J11 (Bank 35, 3.3V).
//     2. Zynq PS AXI4-Stream via axi_fifo_mm_s -> axis_cam_bridge.
//        Allows real-time streaming of raw images from PS baremetal / Ethernet
//        into the hardware star detection pipeline without physical camera!
//
//   Controls (Pushbuttons):
//     KEY1  reset
//     KEY2  hold to force the status overlay while a live image is showing
//     KEY3  toggle the camera between RGB565 and YUV422 grayscale output
//     KEY4  step the horizontal window position, 0-3, shown on the overlay.
//           Use it if the picture has a band of junk down one edge: that is
//           the sensor's window sitting over its dummy columns, and no amount
//           of FPGA-side work can recover it.
//
//   LEDs (active low on this board, so lit means the signal is high):
//     LED1  heartbeat (25 MHz toggle)
//     LED2  camera ID ok (or PS stream active)
//     LED3  init done (or PS stream active)
//     LED4  stream geometry ok (640x480 verified)
//
//   SCCB ownership passes from sccb_probe to ov7670_init the moment the camera
//   answers with the right product ID; until then the probe keeps retrying, so
//   the camera can be plugged in with the bitstream already running.
//============================================================================
module top_starfront #(
    parameter integer ENABLE_STARS = 1,
    parameter integer SIM_CAM_ONLY = 0   // 1 = Pure PS Ethernet Stream (Camera disabled & powered down)
) (
    // Zynq PS DDR & Fixed IO
    inout [14:0] DDR_addr,
    inout [2:0]  DDR_ba,
    inout        DDR_cas_n,
    inout        DDR_ck_n,
    inout        DDR_ck_p,
    inout        DDR_cke,
    inout        DDR_cs_n,
    inout [3:0]  DDR_dm,
    inout [31:0] DDR_dq,
    inout [3:0]  DDR_dqs_n,
    inout [3:0]  DDR_dqs_p,
    inout        DDR_odt,
    inout        DDR_ras_n,
    inout        DDR_reset_n,
    inout        DDR_we_n,
    inout        FIXED_IO_ddr_vrn,
    inout        FIXED_IO_ddr_vrp,
    inout [53:0] FIXED_IO_mio,
    inout        FIXED_IO_ps_clk,
    inout        FIXED_IO_ps_porb,
    inout        FIXED_IO_ps_srstb,

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
    // Zynq PS Wrapper & AXI4-Stream Interface
    //------------------------------------------------------------------------
    wire [31:0] ps_axis_tdata;
    wire        ps_axis_tlast;
    wire        ps_axis_tready;
    wire        ps_axis_tvalid;
    wire        ps_stream_clk;

`ifndef SIM
`ifndef NO_PS
    ax7010_PS_wrapper u_ps_wrapper (
        .DDR_addr          ( DDR_addr          ),
        .DDR_ba            ( DDR_ba            ),
        .DDR_cas_n         ( DDR_cas_n         ),
        .DDR_ck_n          ( DDR_ck_n          ),
        .DDR_ck_p          ( DDR_ck_p          ),
        .DDR_cke           ( DDR_cke           ),
        .DDR_cs_n          ( DDR_cs_n          ),
        .DDR_dm            ( DDR_dm            ),
        .DDR_dq            ( DDR_dq            ),
        .DDR_dqs_n         ( DDR_dqs_n         ),
        .DDR_dqs_p         ( DDR_dqs_p         ),
        .DDR_odt           ( DDR_odt           ),
        .DDR_ras_n         ( DDR_ras_n         ),
        .DDR_reset_n       ( DDR_reset_n       ),
        .DDR_we_n          ( DDR_we_n          ),
        .FCLK_CLK0         ( ps_stream_clk     ),
        .FIXED_IO_ddr_vrn  ( FIXED_IO_ddr_vrn  ),
        .FIXED_IO_ddr_vrp  ( FIXED_IO_ddr_vrp  ),
        .FIXED_IO_mio      ( FIXED_IO_mio      ),
        .FIXED_IO_ps_clk   ( FIXED_IO_ps_clk   ),
        .FIXED_IO_ps_porb  ( FIXED_IO_ps_porb  ),
        .FIXED_IO_ps_srstb ( FIXED_IO_ps_srstb ),
        .M_AXIS_tdata      ( ps_axis_tdata      ),
        .M_AXIS_tlast      ( ps_axis_tlast      ),
        .M_AXIS_tready     ( ps_axis_tready     ),
        .M_AXIS_tvalid     ( ps_axis_tvalid     )
    );
`else
    assign ps_stream_clk  = sys_clk;
    assign ps_axis_tdata  = 32'd0;
    assign ps_axis_tlast  = 1'b0;
    assign ps_axis_tvalid = 1'b0;
`endif
`else
    assign ps_stream_clk  = sys_clk;
    assign ps_axis_tdata  = 32'd0;
    assign ps_axis_tlast  = 1'b0;
    assign ps_axis_tvalid = 1'b0;
`endif

    reg [3:0] rst_ps_sync = 4'hF;
    always @(posedge ps_stream_clk) begin
        if (rst_raw) rst_ps_sync <= 4'hF;
        else         rst_ps_sync <= {rst_ps_sync[2:0], 1'b0};
    end
    wire rst_ps = rst_ps_sync[3];

    //------------------------------------------------------------------------
    // AXI-Stream CDC & 32-to-8 Bit Width Converter
    // Crosses from PS Stream Clock (50 MHz) to Pixel Clock (25 MHz)
    //------------------------------------------------------------------------
    wire [7:0] bridge_s_axis_tdata;
    wire       bridge_s_axis_tvalid;
    wire       bridge_s_axis_tready;
    wire       bridge_s_axis_tlast;

    axis_async_fifo_32to8 u_axis_fifo (
        .wr_clk        ( ps_stream_clk        ),
        .wr_rst        ( rst_ps               ),
        .s_axis_tdata  ( ps_axis_tdata        ),
        .s_axis_tvalid ( ps_axis_tvalid       ),
        .s_axis_tready ( ps_axis_tready       ),
        .s_axis_tlast  ( ps_axis_tlast        ),
        .rd_clk        ( clk_pix              ),
        .rd_rst        ( rst_pix              ),
        .m_axis_tdata  ( bridge_s_axis_tdata  ),
        .m_axis_tvalid ( bridge_s_axis_tvalid ),
        .m_axis_tready ( bridge_s_axis_tready ),
        .m_axis_tlast  ( bridge_s_axis_tlast  )
    );

    //------------------------------------------------------------------------
    // Debounced keys & Mode Controls
    //------------------------------------------------------------------------
    wire key2_pressed;   // hold to show the overlay
    wire key3_pressed;   // toggle the camera between RGB565 and YUV422 grayscale
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

    // KEY3 toggles the camera output mode between RGB565 and YUV422 grayscale.
    // KEY4 steps through the four window positions on each press.
    // Position 1 is the default because it is the one that came out clean on
    // this board - position 0, inherited from the Basys 3 project, put the
    // sensor's dummy columns inside the captured window and produced a band of
    // junk down the right edge.
    localparam [1:0] HSTART_DEFAULT = 2'd1;

    reg [1:0] hstart_sel = HSTART_DEFAULT;
    reg       gray_mode  = 1'b0;
    reg       key3_prev  = 1'b0;
    reg       key4_prev  = 1'b0;

    always @(posedge clk_pix) begin
        if (rst_pix) begin
            hstart_sel <= HSTART_DEFAULT;
            gray_mode  <= 1'b0;
            key3_prev  <= 1'b0;
            key4_prev  <= 1'b0;
        end else begin
            key3_prev <= key3_pressed;
            key4_prev <= key4_pressed;

            if (key3_pressed && !key3_prev)
                gray_mode <= ~gray_mode;

            if (key4_pressed && !key4_prev)
                hstart_sel <= hstart_sel + 2'd1;
        end
    end

    //------------------------------------------------------------------------
    // Camera Bridge: converts AXI4-Stream bytes into OV7670 camera timings
    //------------------------------------------------------------------------
    wire       emu_pclk;
    wire       emu_href;
    wire       emu_vsync;
    wire [7:0] emu_data;
    wire       cam_bridge_active;
    wire [9:0] bridge_current_line;
    wire       bridge_frame_done;

    axis_cam_bridge u_axis_cam_bridge (
        .clk           ( clk_pix              ),
        .rst           ( rst_pix              ),
        .s_axis_tdata  ( bridge_s_axis_tdata  ),
        .s_axis_tvalid ( bridge_s_axis_tvalid ),
        .s_axis_tready ( bridge_s_axis_tready ),
        .s_axis_tlast  ( bridge_s_axis_tlast  ),
        .gray_input    ( gray_mode            ),
        .emu_pclk      ( emu_pclk             ),
        .emu_href      ( emu_href             ),
        .emu_vsync     ( emu_vsync            ),
        .emu_data      ( emu_data             ),
        .frame_active  ( cam_bridge_active    ),
        .current_line  ( bridge_current_line  ),
        .frame_done    ( bridge_frame_done    )
    );

    //------------------------------------------------------------------------
    // Physical Camera clock and power sequencing
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
        .Q (ov7670_xclk), .C (clk_pix), .CE (SIM_CAM_ONLY == 0),
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

    assign ov7670_reset_n = (SIM_CAM_ONLY != 0) ? 1'b0 : cam_reset_n_r;
    assign ov7670_pwdn    = (SIM_CAM_ONLY != 0) ? 1'b1 : 1'b0; // low = normal operation, high = power down

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
        .color_bar     ( 1'b0          ),
        .gray_mode     ( gray_mode     ),
        .hstart_sel    ( hstart_sel    ),
        .init_done     ( init_done     ),
        .sccb_start    ( init_start    ),
        .sccb_sub_addr ( init_sub_addr ),
        .sccb_wr_data  ( init_wr_data  ),
        .sccb_done     ( sccb_done     )
    );

    //------------------------------------------------------------------------
    // Physical Camera Pixel Bus & Activity Monitor
    //------------------------------------------------------------------------
    wire phys_cam_pclk;

`ifdef SIM
    assign phys_cam_pclk = ov7670_pclk;
`else
    BUFG u_phys_pclk_bufg (.I(ov7670_pclk), .O(phys_cam_pclk));
`endif

    wire pclk_alive, href_alive, vsync_alive, data_alive;

    cam_activity #(.CLK_FREQ(PIX_FREQ)) u_cam_activity (
        .clk         ( clk_pix        ),
        .rst         ( rst_pix        ),
        .cam_pclk    ( phys_cam_pclk  ),
        .cam_href    ( ov7670_href    ),
        .cam_vsync   ( ov7670_vsync   ),
        .cam_data    ( ov7670_data    ),
        .pclk_alive  ( pclk_alive     ),
        .href_alive  ( href_alive     ),
        .vsync_alive ( vsync_alive    ),
        .data_alive  ( data_alive     )
    );

    //------------------------------------------------------------------------
    // Camera Source Multiplexer (Physical Camera vs AXI-Stream Bridge)
    // - SIM_CAM_ONLY != 0: Exclusively stream from PS AXI-Stream bridge.
    // - ps_stream_locked: Latches high once PS sends even one frame, locking
    //   display to sim_axi permanently to prevent falling back to real camera between frames.
    // - Auto-selects AXI Stream if no physical camera is plugged in (~pclk_alive).
    //------------------------------------------------------------------------
    reg ps_stream_locked = 1'b0;

    always @(posedge clk_pix) begin
        if (rst_pix)
            ps_stream_locked <= 1'b0;
        else if (cam_bridge_active)
            ps_stream_locked <= 1'b1;
    end

    wire use_axis_cam = (SIM_CAM_ONLY != 0) | ps_stream_locked | cam_bridge_active | ~pclk_alive;

    wire cam_pclk_src;

`ifdef SIM
    assign cam_pclk_src = use_axis_cam ? clk_pix : phys_cam_pclk;
`else
    generate
    if (SIM_CAM_ONLY != 0) begin : g_sim_pclk
        assign cam_pclk_src = clk_pix;
    end else begin : g_hw_pclk
        BUFGMUX u_bufgmux_pclk (
            .O  ( cam_pclk_src  ),
            .I0 ( phys_cam_pclk ),
            .I1 ( clk_pix       ),
            .S  ( use_axis_cam  )
        );
    end
    endgenerate
`endif

    wire       cam_href_src  = use_axis_cam ? emu_href  : ov7670_href;
    wire       cam_vsync_src = use_axis_cam ? emu_vsync : ov7670_vsync;
    wire [7:0] cam_data_src  = use_axis_cam ? emu_data  : ov7670_data;

    //------------------------------------------------------------------------
    // Full resolution tap for the star detector, built only when asked for.
    // This runs at 640x480 - the display path's 2:1 downsample would throw
    // away three quarters of the sky.
    //------------------------------------------------------------------------
    wire [7:0] star_count_s, star_thresh_s, star_max_s;
    wire [9:0] bright_x_s, bright_y_s;

    generate
    if (ENABLE_STARS != 0) begin : g_stars

        wire        pix_valid;
        wire [9:0]  pix_x, pix_y;
        wire [15:0] pix_rgb;
        wire [7:0]  pix_luma;
        wire        cam_frame_start;

        cam_pixel_stream u_pixel_stream (
            .pclk        ( cam_pclk_src    ),
            .href        ( cam_href_src    ),
            .vsync       ( cam_vsync_src   ),
            .data        ( cam_data_src    ),
            .gray_mode   ( gray_mode       ),
            .pix_valid   ( pix_valid       ),
            .pix_x       ( pix_x           ),
            .pix_y       ( pix_y           ),
            .pix_rgb     ( pix_rgb         ),
            .pix_luma    ( pix_luma        ),
            .frame_start ( cam_frame_start )
        );

        wire [7:0]  count_p, thresh_p, max_p;
        wire [9:0]  bx_p, by_p;
        wire [12:0] bsum_p;
        wire        tog_p;

        star_detect u_star_detect (
            .pclk        ( cam_pclk_src    ),
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

    end else begin : g_no_stars

        assign star_count_s  = 8'd0;
        assign star_thresh_s = 8'd0;
        assign star_max_s    = 8'd0;
        assign bright_x_s    = 10'd0;
        assign bright_y_s    = 10'd0;

    end
    endgenerate

    //------------------------------------------------------------------------
    // Stream geometry probe
    //------------------------------------------------------------------------
    wire [15:0] bytes_per_line, lines_per_frame;
    wire [7:0]  frames_per_sec, pclk_freq_100k;
    wire        stream_ok;

    cam_stream_probe #(.CLK_FREQ(PIX_FREQ)) u_stream_probe (
        .clk             ( clk_pix         ),
        .rst             ( rst_pix         ),
        .cam_pclk        ( cam_pclk_src    ),
        .cam_href        ( cam_href_src    ),
        .cam_vsync       ( cam_vsync_src   ),
        .bytes_per_line  ( bytes_per_line  ),
        .lines_per_frame ( lines_per_frame ),
        .frames_per_sec  ( frames_per_sec  ),
        .pclk_freq_100k  ( pclk_freq_100k  ),
        .stream_ok       ( stream_ok       )
    );

    //------------------------------------------------------------------------
    // Capture into the frame buffer (camera domain) and read it back out
    // (pixel domain). The dual-clock block RAM is the clock domain crossing.
    // Framebuffer resolution: 320x240 RGB565, pixel-doubled back to 640x480.
    //------------------------------------------------------------------------
    wire        cap_wr_en;
    wire [16:0] cap_addr;
    wire [15:0] cap_data;

    cam_capture u_cam_capture (
        .ov7670_pclk  ( cam_pclk_src  ),
        .ov7670_href  ( cam_href_src  ),
        .ov7670_vsync ( cam_vsync_src ),
        .ov7670_data  ( cam_data_src  ),
        .gray_mode    ( gray_mode     ),
        .cap_wr_en    ( cap_wr_en     ),
        .cap_addr     ( cap_addr      ),
        .cap_data     ( cap_data      )
    );

    wire [16:0] fb_addr_rd;
    wire [15:0] fb_data_rd;

    fb_mem u_fb_mem (
        .clk_wr  ( cam_pclk_src ),
        .wr_en   ( cap_wr_en    ),
        .addr_wr ( cap_addr     ),
        .data_wr ( cap_data     ),
        .clk_rd  ( clk_pix      ),
        .addr_rd ( fb_addr_rd   ),
        .data_rd ( fb_data_rd   )
    );

    //------------------------------------------------------------------------
    // Display timing (VGA 640x480 @ 60Hz)
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

    wire [1:0] banner_level = (!cam_id_ok && !cam_bridge_active) ? 2'd0 : (stream_ok ? 2'd2 : 2'd1);

    wire [7:0] ovl_r, ovl_g, ovl_b;

    status_overlay u_overlay (
        .clk_pix      ( clk_pix        ),
        .rst          ( rst_pix        ),
        .pixel_x      ( vga_pixel_x    ),
        .pixel_y      ( vga_pixel_y    ),
        .active       ( vga_active     ),
        .frame_tick   ( vga_frame_tick ),
        // digits: PID VER, then the window selection, then the register read-back
        .row0         ( {cam_pid, cam_ver, 6'b0, hstart_sel, cam_readback} ),
        .row1         ( {bytes_per_line, lines_per_frame}       ),
        .row2         ( {8'h00, pclk_freq_100k, 8'h00, frames_per_sec} ),
        // stars found, detection threshold, brightest pixel in the frame
        .row3         ( {star_count_s, star_thresh_s, star_max_s, 8'h00} ),
        .row3_en      ( ENABLE_STARS != 0 ),
        .row4_bits    ( {cam_id_ok | cam_bridge_active, cam_rw_ok, init_done | cam_bridge_active, stream_ok,
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

    // Latch high once at least one valid frame has been processed by axis_cam_bridge
    reg first_frame_captured = 1'b0;
    always @(posedge clk_pix) begin
        if (rst_pix)
            first_frame_captured <= 1'b0;
        else if (bridge_frame_done)
            first_frame_captured <= 1'b1;
    end

    // Show the numbers until the camera is configured, and whenever KEY2 is held
    wire valid_video_available = (use_axis_cam ? first_frame_captured : (init_done & stream_ok));
    wire show_overlay = key2_pressed | ~valid_video_available;

    //------------------------------------------------------------------------
    // Crosshair on the brightest star. The detector works in the camera's
    // 640x480 coordinates and the screen is 640x480, so the position needs no
    // scaling - a 320x240 buffer pixel-doubled lands exactly on it.
    //
    // The middle of the cross is left open so the star itself stays visible.
    //------------------------------------------------------------------------
    wire [9:0] mark_dx = (pixel_x_d > bright_x_s) ? (pixel_x_d - bright_x_s)
                                                  : (bright_x_s - pixel_x_d);
    wire [9:0] mark_dy = (pixel_y_d > bright_y_s) ? (pixel_y_d - bright_y_s)
                                                  : (bright_y_s - pixel_y_d);

    wire mark_arm_h = (mark_dy == 10'd0) && (mark_dx >= 10'd4) && (mark_dx <= 10'd12);
    wire mark_arm_v = (mark_dx == 10'd0) && (mark_dy >= 10'd4) && (mark_dy <= 10'd12);
    wire show_mark  = (star_count_s != 8'd0) && (mark_arm_h || mark_arm_v);

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
    // Status LEDs (active low on this board, so lit means the signal is high)
    //   LED1  heartbeat
    //   LED2  camera ID ok (or PS stream active)
    //   LED3  init done (or PS stream active)
    //   LED4  stream geometry ok
    //------------------------------------------------------------------------
    reg [23:0] heartbeat_cnt = 24'd0;
    always @(posedge clk_pix) heartbeat_cnt <= heartbeat_cnt + 24'd1;

    wire [3:0] led = { stream_ok,                           // LED4
                       init_done | cam_bridge_active,       // LED3
                       cam_id_ok | cam_bridge_active,       // LED2
                       heartbeat_cnt[23] };                 // LED1
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
