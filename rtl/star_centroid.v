`timescale 1ns / 1ps

//============================================================================
// Module: star_centroid
// Description: The whole star detection front end, from a binned pixel stream
//              to a list of sub-pixel centroids. One pixel per clock, no frame
//              store, fixed latency.
//
//   Stages, following Panousopoulos et al., J Real-Time Image Proc 21:16
//   (2024), section 3:
//
//     linearise      pix_lut, 8-bit code -> 12-bit light (see pix_lut.v)
//     background     bg_track, per-column median and a global MAD
//     window         eight line buffers -> a 9x9 RoI in registers
//     seed           local maximum above the seed threshold, inside the FOV
//     grow           region_grow, 8-connected component of the RoI, in one cycle
//     CG             cg_engine, centre of gravity to 1/256 of a binned pixel
//     list           up to N_STAR_MAX per frame, double buffered
//
//   The RoI is 9x9 because a DUST star fills a box of about 4 x 2 binned
//   pixels and trails a smear tail up to six columns to its left; 9 covers
//   both with room for the neighbourhood the local-maximum test needs.
//   Widening it to 13 was measured and changed the centroid error by under
//   0.01 display pixels, so it buys nothing but registers.
//
//   Line buffers hold linearised values rather than raw codes, and the
//   thresholds are passed through the same table to compare against them. The
//   table is strictly increasing, so that comparison is identical to the one in
//   code space - and it means the linearising table is instantiated three times
//   instead of eighty-one.
//
//   Only one cluster is processed at a time. The engine takes about 28 cycles
//   and stars are tens of columns apart, so a collision is rare; when it does
//   happen the seed is dropped and counted rather than queued, because a queue
//   deep enough to matter costs more than the star it would save. `dropped` is
//   on the status panel for exactly that reason - a number that is normally
//   zero and says so.
//
// Clock domain: single, the binned pixel stream's.
//============================================================================

module star_centroid #(
    parameter integer IMG_W      = 256,
    parameter integer IMG_H      = 256,
    parameter integer WIN        = 9,
    parameter integer PIXW       = 12,
    parameter integer FRAC       = 8,
    parameter integer N_STAR_MAX = 64,

    parameter integer K_SEED_Q   = 20,     // quarter sigma
    parameter integer K_GROW_Q   = 12,
    parameter integer FLOOR_CODE = 2,
    parameter integer MIN_NPX    = 4,
    parameter integer MIN_SUM    = 256,
    parameter integer CG_HALF    = 0,      // 0 = weight the grown region

    // Illuminated disc. FOV_R = 0 disables the mask.
    parameter integer FOV_CX     = 128,
    parameter integer FOV_CY     = 128,
    parameter integer FOV_R      = 122
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        in_valid,
    input  wire [7:0]  in_x,
    input  wire [7:0]  in_y,
    input  wire [7:0]  in_code,
    input  wire        frame_start,     // one pulse before the first pixel

    // Where the illuminated disc currently sits, relative to FOV_CX/FOV_CY, in
    // binned pixels. Zero unless the frame source is scrolling: the mask has to
    // travel with the image, or a scrolled disc puts unlit corner outside the
    // mask and dark sky inside it, and the background follower then chases the
    // dark into columns that hold stars.
    input  wire signed [5:0] fov_ox,
    input  wire signed [5:0] fov_oy,

    // Published on frame_start and stable for the whole of the next frame
    output reg  [6:0]  star_count,
    output reg  [6:0]  dropped,
    output reg         overflow,
    output reg  [15:0] best_x,
    output reg  [15:0] best_y,
    output reg  [19:0] best_sum,
    output reg  [15:0] frame_count,

    // Star list read port, combinational, reads the published bank
    input  wire [5:0]  rd_addr,
    output wire [15:0] rd_x,
    output wire [15:0] rd_y,
    output wire [19:0] rd_sum,
    output wire [6:0]  rd_npx,

    // A second read port, for the host over AXI. Separate rather than muxed
    // because the marker drawer walks the list every scan line and would
    // otherwise have to be interrupted mid-line to answer a read - and a
    // corrupted readback is worse than a few extra LUTs.
    input  wire [5:0]  rd2_addr,
    output wire [15:0] rd2_x,
    output wire [15:0] rd2_y,
    output wire [19:0] rd2_sum,
    output wire [6:0]  rd2_npx,

    // For the status panel and the ILA
    output wire [7:0]  bg_code,
    output wire [7:0]  thr_grow_code,
    output wire [13:0] mad_acc
);

    localparam integer HALF = WIN / 2;
    localparam integer NPIX = WIN * WIN;
    localparam integer CTR  = HALF * WIN + HALF;
    localparam integer FOV_R2 = FOV_R * FOV_R;

    //------------------------------------------------------------------------
    // Linearise, and decide whether this pixel is under the optics at all
    //------------------------------------------------------------------------
    wire [PIXW-1:0] lin;
    pix_lut u_lut_pix (.code(in_code), .lin(lin));

    wire [7:0] fov_cx_e = FOV_CX[7:0] + {{2{fov_ox[5]}}, fov_ox};
    wire [7:0] fov_cy_e = FOV_CY[7:0] + {{2{fov_oy[5]}}, fov_oy};

    function in_disc;
        input [7:0] px;
        input [7:0] py;
        reg [7:0] adx, ady;
        reg [17:0] r2;
        begin
            adx = (px > fov_cx_e) ? (px - fov_cx_e) : (fov_cx_e - px);
            ady = (py > fov_cy_e) ? (py - fov_cy_e) : (fov_cy_e - py);
            r2  = (adx * adx) + (ady * ady);
            in_disc = (FOV_R == 0) || (r2 <= FOV_R2[17:0]);
        end
    endfunction

    wire pix_in_fov = in_disc(in_x, in_y);

    //------------------------------------------------------------------------
    // Background and thresholds. Registered one cycle after in_valid, which is
    // the cycle the window they belong to becomes valid.
    //------------------------------------------------------------------------
    wire [7:0]      thr_seed_code;
    wire [7:0]      thr_grow_c;
    wire [PIXW-1:0] bg_lin;

    bg_track #(
        .IMG_W      ( IMG_W      ),
        .HALF       ( HALF       ),
        .K_SEED_Q   ( K_SEED_Q   ),
        .K_GROW_Q   ( K_GROW_Q   ),
        .FLOOR_CODE ( FLOOR_CODE )
    ) u_bg (
        .clk      ( clk           ),
        .rst      ( rst           ),
        .in_valid ( in_valid      ),
        .in_x     ( in_x          ),
        .in_y     ( in_y          ),
        .in_code  ( in_code       ),
        .in_lin   ( lin           ),
        .in_fov   ( pix_in_fov    ),
        .thr_seed ( thr_seed_code ),
        .thr_grow ( thr_grow_c    ),
        .bg_lin   ( bg_lin        ),
        .bg_code  ( bg_code       ),
        .mad_acc  ( mad_acc       )
    );

    assign thr_grow_code = thr_grow_c;

    wire [PIXW-1:0] thr_seed_lin, thr_grow_lin;
    pix_lut u_lut_ts (.code(thr_seed_code), .lin(thr_seed_lin));
    pix_lut u_lut_tg (.code(thr_grow_c),    .lin(thr_grow_lin));

    //------------------------------------------------------------------------
    // Eight line buffers give rows y-1 .. y-8 at the current column, so with
    // the incoming pixel there are WIN rows to build a window from.
    //------------------------------------------------------------------------
    wire [PIXW-1:0] row [1:WIN-1];
    wire [9:0]      lb_addr = {2'b00, in_x};

    genvar gl;
    generate
        for (gl = 1; gl < WIN; gl = gl + 1) begin : g_lb
            wire [PIXW-1:0] din;
            if (gl == 1) begin : g_first
                assign din = lin;
            end else begin : g_chain
                assign din = row[gl-1];
            end
            line_buffer #(.WIDTH(PIXW), .DEPTH(IMG_W)) u_lb (
                .clk  ( clk       ),
                .we   ( in_valid  ),
                .addr ( lb_addr   ),
                .din  ( din       ),
                .dout ( row[gl]   )
            );
        end
    endgenerate

    //------------------------------------------------------------------------
    // The window. w[r*WIN + c]: row 0 is the oldest line (y - 2*HALF), column
    // 0 the leftmost, new pixels enter at the right. Centre is w[CTR].
    //------------------------------------------------------------------------
    reg [PIXW-1:0] w [0:NPIX-1];
    reg [7:0]      cx = 8'd0, cy = 8'd0;
    reg            win_valid = 1'b0;

    integer r, c;

    always @(posedge clk) begin
        if (rst) begin
            win_valid <= 1'b0;
        end else if (in_valid) begin
            for (r = 0; r < WIN; r = r + 1)
                for (c = 0; c < WIN-1; c = c + 1)
                    w[r*WIN+c] <= w[r*WIN+c+1];

            for (r = 0; r < WIN-1; r = r + 1)
                w[r*WIN + WIN-1] <= row[WIN-1-r];      // row[8] is y-8, into row 0
            w[(WIN-1)*WIN + WIN-1] <= lin;

            cx        <= in_x - HALF[7:0];
            cy        <= in_y - HALF[7:0];
            win_valid <= (in_x >= (WIN-1)) && (in_y >= (WIN-1));
        end else begin
            win_valid <= 1'b0;
        end
    end

    //------------------------------------------------------------------------
    // Seed test: a local maximum over the RoI, above the seed threshold, under
    // the optics.
    //
    // The tie-break is a raster one - strictly greater than every neighbour
    // that comes before the centre, greater or equal to every one after. A
    // plain strict maximum drops saturated stars, whose cores are flat; a plain
    // >= reports one flat core as several stars.
    //------------------------------------------------------------------------
    wire [NPIX-1:0] cmp;
    wire [NPIX-1:0] msk;
    wire [NPIX*PIXW-1:0] win_flat;

    genvar gi;
    generate
        for (gi = 0; gi < NPIX; gi = gi + 1) begin : g_win
            assign win_flat[gi*PIXW +: PIXW] = w[gi];
            assign msk[gi] = (w[gi] > thr_grow_lin);
            if (gi < CTR)      assign cmp[gi] = (w[CTR] >  w[gi]);
            else if (gi > CTR) assign cmp[gi] = (w[CTR] >= w[gi]);
            else               assign cmp[gi] = 1'b1;
        end
    endgenerate

    wire [NPIX-1:0] region;
    region_grow #(.WIN(WIN)) u_grow (.mask(msk), .region(region));

    wire is_max  = &cmp;
    wire ctr_fov = in_disc(cx, cy);
    wire is_seed = win_valid && ctr_fov && is_max && (w[CTR] > thr_seed_lin);

    //------------------------------------------------------------------------
    // One cluster at a time
    //------------------------------------------------------------------------
    wire        eng_busy, eng_valid, eng_reject;
    wire [15:0] eng_x, eng_y;
    wire [18:0] eng_sum;
    wire [6:0]  eng_npx;

    cg_engine #(
        .WIN(WIN), .HALF(HALF), .PIXW(PIXW), .FRAC(FRAC),
        .CG_HALF(CG_HALF), .MIN_NPX(MIN_NPX), .MIN_SUM(MIN_SUM)
    ) u_cg (
        .clk        ( clk                 ),
        .rst        ( rst                 ),
        .start      ( is_seed && !eng_busy ),
        .win        ( win_flat            ),
        .reg_in     ( region              ),
        .bg         ( bg_lin              ),
        .x0         ( cx - HALF[7:0]      ),
        .y0         ( cy - HALF[7:0]      ),
        .busy       ( eng_busy            ),
        .out_valid  ( eng_valid           ),
        .out_x      ( eng_x               ),
        .out_y      ( eng_y               ),
        .out_sum    ( eng_sum             ),
        .out_npx    ( eng_npx             ),
        .out_reject ( eng_reject          )
    );

    //------------------------------------------------------------------------
    // Star list, double buffered: the detector fills one bank while the display
    // reads the other, so a marker never lands half way between two frames.
    //------------------------------------------------------------------------
    (* ram_style = "distributed" *) reg [15:0] lx  [0:2*N_STAR_MAX-1];
    (* ram_style = "distributed" *) reg [15:0] ly  [0:2*N_STAR_MAX-1];
    (* ram_style = "distributed" *) reg [19:0] lsm [0:2*N_STAR_MAX-1];
    (* ram_style = "distributed" *) reg [6:0]  lnp [0:2*N_STAR_MAX-1];

    reg        bank      = 1'b0;      // the one being written
    reg [6:0]  wcount    = 7'd0;
    reg [6:0]  dropcount = 7'd0;
    reg        ovf       = 1'b0;
    reg [15:0] bx = 16'd0, by = 16'd0;
    reg [19:0] bs = 20'd0;

    wire full = (wcount >= N_STAR_MAX[6:0]);

    assign rd_x   = lx [{~bank, rd_addr}];
    assign rd_y   = ly [{~bank, rd_addr}];
    assign rd_sum = lsm[{~bank, rd_addr}];
    assign rd_npx = lnp[{~bank, rd_addr}];

    assign rd2_x   = lx [{~bank, rd2_addr}];
    assign rd2_y   = ly [{~bank, rd2_addr}];
    assign rd2_sum = lsm[{~bank, rd2_addr}];
    assign rd2_npx = lnp[{~bank, rd2_addr}];

    always @(posedge clk) begin
        if (rst) begin
            bank        <= 1'b0;
            wcount      <= 7'd0;
            dropcount   <= 7'd0;
            ovf         <= 1'b0;
            star_count  <= 7'd0;
            dropped     <= 7'd0;
            overflow    <= 1'b0;
            frame_count <= 16'd0;
            bx <= 16'd0; by <= 16'd0; bs <= 20'd0;
            best_x <= 16'd0; best_y <= 16'd0; best_sum <= 20'd0;
        end else if (frame_start) begin
            star_count  <= wcount;
            dropped     <= dropcount;
            overflow    <= ovf;
            best_x      <= bx;
            best_y      <= by;
            best_sum    <= bs;
            frame_count <= frame_count + 16'd1;

            bank        <= ~bank;
            wcount      <= 7'd0;
            dropcount   <= 7'd0;
            ovf         <= 1'b0;
            bx <= 16'd0; by <= 16'd0; bs <= 20'd0;
        end else begin
            if (is_seed && eng_busy && (dropcount != 7'h7F))
                dropcount <= dropcount + 7'd1;

            if (eng_valid) begin
                if (full) begin
                    ovf <= 1'b1;
                end else begin
                    lx [{bank, wcount[5:0]}] <= eng_x;
                    ly [{bank, wcount[5:0]}] <= eng_y;
                    lsm[{bank, wcount[5:0]}] <= {1'b0, eng_sum};
                    lnp[{bank, wcount[5:0]}] <= eng_npx;
                    wcount <= wcount + 7'd1;
                end

                if ({1'b0, eng_sum} > bs) begin
                    bs <= {1'b0, eng_sum};
                    bx <= eng_x;
                    by <= eng_y;
                end
            end
        end
    end

endmodule
