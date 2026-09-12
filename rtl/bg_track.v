`timescale 1ns / 1ps

//============================================================================
// Module: bg_track
// Description: Follows the sky background and its noise along the raster, and
//              turns them into the two thresholds the detector needs.
//
//   Three sign-LMS median followers. Each adds or subtracts a fixed step
//   depending on which side of its estimate the sample fell on, so each one
//   converges to a median rather than a mean. That distinction is the whole
//   design: the mean of a neighbourhood containing a star is not the
//   background under that star, and a star must not be allowed to lift its own
//   baseline. The cost is a comparator and an adder - no window, no sort, no
//   division.
//
//   **The background is tracked per column, not along the raster.** A DUST
//   frame is vignetted from about code 84 on the left of the illuminated disc
//   to 58 on the right, so a follower running along the raster hits a 26-code
//   cliff at every line wrap and spends the next hundred columns climbing it.
//   It never settles, and what it leaves behind is lag, not noise: the
//   deviation estimate comes out at 6 codes against a true 1, and the
//   threshold lands 30 codes above the background where the dataset's own
//   truth puts it 9. Down a column the same background moves by a tenth of a
//   code per row, and one estimate per column follows it with nothing left
//   over. Measured against the dataset's 21x21 local median, this tracks to
//   within half a code.
//
//   **The update is gated to the illuminated disc.** A column crosses the rim
//   twice, and that is a 67-code step no follower can climb. Gated, a column
//   sees nothing but sky - and because the vignetting is radial, the value a
//   column leaves at the bottom of the disc is very nearly the one it needs at
//   the top of the next frame, so nothing has to be re-acquired.
//
//   The deviation follower is global. After per-column subtraction the
//   residual really is stationary noise, and one global estimate sees 65536
//   samples a frame where a per-column one would see 256.
//
//   Everything here works on the 8-bit display code, not on linearised light.
//   The encoding is close to logarithmic, which is what makes the noise about
//   the same size across a frame spanning two decades of brightness, so a
//   single median-plus-MAD rule holds everywhere.
//
//   **The linear background under the centroid weights is the same per-column
//   median, put through the linearising table.** It used to be a separate
//   global follower - one number for the whole frame - and that was measured
//   to be the largest single error in the pipeline: the vignetting that is a
//   26-code spread in code space is a factor of two in linear light, so a
//   frame-wide value sat a hundred counts wrong at either side of the disc,
//   where a wing pixel's real excess over the sky is thirty or forty. The
//   dataset's own blob truth subtracts the local median, linearised; doing the
//   same took the median centroid error from 0.482 to 0.401 display pixels and
//   the completeness from 65% to 69%, for one more 256-entry table and no new
//   state. Interpolating the follower's fractional bits between two table
//   entries was tried too and bought 0.002 px, which is not worth a multiplier.
//
// Clock domain: single, the binned pixel stream's.
//============================================================================

module bg_track #(
    parameter integer IMG_W       = 256,
    parameter integer XW          = 8,    // column coordinate width
    parameter integer HALF        = 4,    // detector window half-width
    parameter integer BG_FRAC     = 6,    // fractional bits, code-domain followers
    parameter integer STEP_BG     = 8,
    parameter integer STEP_MAD    = 4,
    parameter integer K_SEED_Q    = 20,   // quarter sigma, starts a cluster
    parameter integer K_GROW_Q    = 12,   // quarter sigma, joins one
    parameter integer FLOOR_CODE  = 2,    // floor on (threshold - background)

    // Cold-start values. These are also the model's, in
    // bench/starfront_model.py: Params.prime_bg / prime_mad. If they drift
    // apart the two stop describing the same detector, because the followers
    // are slow enough that where they started still shows several frames
    // later.
    parameter integer PRIME_BG    = 64,
    parameter integer PRIME_MAD   = 2
) (
    input  wire        clk,
    input  wire        rst,

    input  wire          in_valid,
    input  wire [XW-1:0] in_x,
    input  wire [7:0]    in_code,
    input  wire          in_fov,      // this pixel is inside the illuminated disc

    // Registered one cycle after in_valid, and aligned by construction with a
    // detector window whose centre is HALF rows and HALF columns behind.
    output reg  [7:0]  thr_seed,      // code a pixel must clear to start a cluster
    output reg  [7:0]  thr_grow,      // code a pixel must clear to join one
    output reg  [11:0] bg_lin,        // that column's background, linearised

    // High while the reset sweep is re-priming the column RAM. The detector
    // must not start a frame until this is low - see star_centroid.
    output wire        sweeping,

    // For the status panel and the ILA
    output wire [7:0]  bg_code,
    output wire [13:0] mad_acc
);

    localparam integer BGW = 8 + BG_FRAC;             // 14
    localparam [BGW-1:0] MAD_MIN = {{BGW{1'b0}}} + (1 << BG_FRAC);

    //------------------------------------------------------------------------
    // Per-column background. Dual port distributed RAM: port A reads and
    // writes the incoming column, port B reads the column HALF behind, which
    // is the one a closing detector window is centred on. Port B sees the
    // value written HALF cycles ago, which is exactly the post-update state
    // the model records.
    //------------------------------------------------------------------------
    (* ram_style = "distributed" *) reg [BGW-1:0] bgmem [0:IMG_W-1];

    integer i;
    initial begin
        for (i = 0; i < IMG_W; i = i + 1)
            bgmem[i] = {PRIME_BG[7:0], {BG_FRAC{1'b0}}};
    end

    // A RAM has no reset, so reset sweeps it. Without this the followers carry
    // the previous run's sky across a reset - which on hardware means KEY1 does
    // not actually put the detector back where it started, and in simulation
    // means the second test in a run disagrees with a model that always starts
    // cold. One cycle per column, and the first star cannot appear for eight
    // rows.
    reg  [XW:0] sweep = {(XW+1){1'b0}};
    assign sweeping = (sweep < IMG_W);

    always @(posedge clk) begin
        if (rst)           sweep <= {(XW+1){1'b0}};
        else if (sweeping) sweep <= sweep + 1'b1;
    end

    wire [XW-1:0]  xb    = in_x - HALF[XW-1:0];
    wire [BGW-1:0] bg_a  = bgmem[in_x];
    wire [BGW-1:0] bg_b  = bgmem[xb];
    wire [7:0]     bga_i = bg_a[BGW-1:BG_FRAC];

    wire [BGW-1:0] bg_next = (in_code > bga_i) ? (bg_a + STEP_BG[BGW-1:0])
                                               : (bg_a - STEP_BG[BGW-1:0]);

    always @(posedge clk) begin
        if (sweeping)
            bgmem[sweep[XW-1:0]] <= {PRIME_BG[7:0], {BG_FRAC{1'b0}}};
        else if (in_valid && in_fov)
            bgmem[in_x] <= bg_next;
    end

    //------------------------------------------------------------------------
    // Global deviation follower, on |code - background|
    //------------------------------------------------------------------------
    reg [BGW-1:0] mad_r = {PRIME_MAD[7:0], {BG_FRAC{1'b0}}};

    wire [7:0]     dev    = (in_code > bga_i) ? (in_code - bga_i) : (bga_i - in_code);
    wire [7:0]     mad_i  = mad_r[BGW-1:BG_FRAC];
    wire [BGW-1:0] mad_up = mad_r + STEP_MAD[BGW-1:0];
    wire [BGW-1:0] mad_dn = (mad_r > (MAD_MIN + STEP_MAD[BGW-1:0]))
                            ? (mad_r - STEP_MAD[BGW-1:0]) : MAD_MIN;
    wire [BGW-1:0] mad_next = (dev > mad_i) ? mad_up : mad_dn;

    always @(posedge clk) begin
        if (rst)                          mad_r <= {PRIME_MAD[7:0], {BG_FRAC{1'b0}}};
        else if (in_valid && in_fov)      mad_r <= mad_next;
    end

    //------------------------------------------------------------------------
    // The centre column's background in linear light, for the centroid
    // weights. Same column, same moment, same integer code the grow
    // threshold is built on - the model reads all three from one place.
    //------------------------------------------------------------------------
    wire [11:0] bg_b_lin;
    pix_lut u_lut_bg (.code(bg_b[BGW-1:BG_FRAC]), .lin(bg_b_lin));

    //------------------------------------------------------------------------
    // Thresholds. sigma = 1.4826 * MAD, and 1.4826 is 1519/1024 to a part in
    // 10^5. k is carried in quarter-sigma units, so the margin above the
    // background is k * sigma / 4, with the follower's fractional bits kept
    // all the way through and dropped only at the end - the deviation is one
    // to two codes, and rounding it to an integer there would throw away a
    // third of the threshold.
    //------------------------------------------------------------------------
    wire [BGW+10:0] sig_wide = mad_next * 11'd1519;          // 25 bits
    wire [BGW:0]    sigma    = sig_wide[BGW+10:10];          // 15 bits, BG_FRAC fractional

    wire [BGW+7:0] mseed_w = sigma * K_SEED_Q[6:0];          // 22 bits
    wire [BGW+7:0] mgrow_w = sigma * K_GROW_Q[6:0];

    // >> (2 + BG_FRAC): the 2 turns quarter-sigma into sigma, BG_FRAC drops
    // the follower's fractional bits.
    wire [12:0] mseed = mseed_w[BGW+7:BG_FRAC+2];
    wire [12:0] mgrow = mgrow_w[BGW+7:BG_FRAC+2];

    wire [12:0] mseed_f = (mseed < FLOOR_CODE[12:0]) ? FLOOR_CODE[12:0] : mseed;
    wire [12:0] mgrow_f = (mgrow < FLOOR_CODE[12:0]) ? FLOOR_CODE[12:0] : mgrow;

    wire [13:0] tseed = {6'b0, bg_b[BGW-1:BG_FRAC]} + {1'b0, mseed_f};
    wire [13:0] tgrow = {6'b0, bg_b[BGW-1:BG_FRAC]} + {1'b0, mgrow_f};

    always @(posedge clk) begin
        if (rst) begin
            thr_seed <= 8'hFF;
            thr_grow <= 8'hFF;
            bg_lin   <= 12'd0;
        end else if (in_valid) begin
            thr_seed <= (tseed > 14'd255) ? 8'd255 : tseed[7:0];
            thr_grow <= (tgrow > 14'd255) ? 8'd255 : tgrow[7:0];
            bg_lin   <= bg_b_lin;
        end
    end

    assign bg_code = bg_a[BGW-1:BG_FRAC];
    assign mad_acc = mad_r;

endmodule
