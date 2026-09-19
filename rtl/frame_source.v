`timescale 1ns / 1ps

//============================================================================
// Module: frame_source
// Description: Holds two star-field frames, replays one as a full-rate
//              1024x1024 pixel stream, serves the same pixels to the display,
//              and lets the host write the other one over AXI.
//
//   This is how images get into the FPGA without a camera. The store holds a
//   frame as the 256x256 DUST sensor grid and the replay emits each stored
//   pixel four times per axis, reconstructing the 1024x1024 display image
//   exactly - because that image *is* a 4x block replication of the sensor
//   grid, and the binner downstream puts it back. So the detector really does
//   process the full-resolution image while the store holds a sixteenth of it,
//   which is the difference between fitting on a 7z010 and not.
//
//   A frame is replayed every 1024*1024 clocks - 42 ms at 25 MHz, so 24 frames
//   a second, continuously and with no host in the loop.
//
//   **Scrolling is what makes those frames different from each other.** The
//   read address is offset by whole *display* pixels, and because the binner
//   averages 4x4 blocks, an offset of one display pixel is a shift of exactly
//   a quarter of a binned pixel: the block starting one pixel over averages
//   three copies of one sensor pixel and one of the next, and the first moment
//   of that box lands a quarter of a binned pixel along. The detector sees a
//   genuinely different binned image every frame, with different noise under
//   the threshold and a background the follower has to chase - a slewing sky,
//   which is what a star tracker actually looks at. It is also the sub-pixel
//   proof, on the board, with no host: step once and every centroid moves by
//   0x40 in the 8.8 readout and by nothing else.
//
//   **Two buffers, thirty-two bits wide.** Wide because the host writes whole
//   AXI words; two because a frame arriving over JTAG must not tear the one on
//   screen. The width also settles an inference problem - see the note on the
//   memory below.
//
//   Contents come from a memory file written by bench/prepare_frames.py, and
//   are overwritten from there by whatever the host sends. With
//   USE_MEM_FILE = 0 the store fills with an obviously artificial lattice
//   instead, so the design is demonstrable on a board with no dataset anywhere
//   near it - and so that a store which failed to load says so at a glance.
//
// Clock domain: single, clk_pix.
//============================================================================

module frame_source #(
    parameter integer IMG_W        = 256,     // stored frame width
    parameter integer IMG_H        = 256,
    parameter integer UP           = 4,       // replay upscale, must match the binner
    parameter integer USE_MEM_FILE = 1,
    parameter         MEM_FILE     = "frames.mem"
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        run,          // hold high to keep replaying
    // Scrolling. The read address is offset by whole DISPLAY pixels, which the
    // 4x4 binner downstream turns into quarter-pixel motion of the binned
    // image - see the note on the offset registers below.
    input  wire        scroll_en,    // drift continuously, one step per frame
    input  wire        scroll_step,  // one pulse advances a single step
    output reg signed [6:0] scroll_x, // current offset, display pixels
    output reg signed [6:0] scroll_y,

    output reg         pix_valid,
    output reg  [9:0]  pix_x,        // 0 .. IMG_W*UP - 1
    output reg  [9:0]  pix_y,
    output wire [7:0]  pix_data,
    output reg         frame_start,  // one pulse before the first pixel of a frame

    // Display read port: binned coordinates, one cycle of latency
    input  wire [7:0]  disp_x,
    input  wire [7:0]  disp_y,
    output wire [7:0]  disp_data,

    // Host write port. Writes always land in the buffer that is NOT playing, so
    // a frame arriving over JTAG never tears the one on screen.
    input  wire        fb_we,
    input  wire [13:0] fb_addr,
    input  wire [31:0] fb_data,
    input  wire        swap_req,     // one pulse: play what was just written
    output reg         play_buf
);

    localparam integer OUT_W  = IMG_W * UP;
    localparam integer OUT_H  = IMG_H * UP;
    localparam integer WORDS  = (IMG_W * IMG_H) / 4;     // four pixels per word

    //------------------------------------------------------------------------
    // Two buffers, thirty-two bits wide.
    //
    // Wide because the host writes whole AXI words, and two because a frame
    // arriving over JTAG must not tear the one being displayed. The width also
    // settles an inference problem: as a read-only ROM with two read ports,
    // Vivado built a second copy of the whole memory rather than using the
    // second port of one block RAM - a ROM has no write port to hang the second
    // port's logic on - and one frame cost 32 tiles instead of 16. With a real
    // write port on port A it infers a true dual-port RAM, and two buffers now
    // cost what one used to.
    //
    // Only the buffer that is not playing is ever written, so the two ports
    // never contend and no arbitration is needed.
    //------------------------------------------------------------------------
    (* ram_style = "block" *) reg [31:0] mem0 [0:WORDS-1];
    (* ram_style = "block" *) reg [31:0] mem1 [0:WORDS-1];

    integer i, sx, sy, px4, v;
    reg [31:0] wtmp;

    initial begin
        // A lattice of 3x3 blobs on a vignetted disc. Deliberately nothing like
        // real data - if this is what is on the screen, the memory file did not
        // load, and a regular grid says so at a glance where a plausible star
        // field would not.
        for (i = 0; i < WORDS; i = i + 1) begin
            sy = i / (IMG_W / 4);
            wtmp = 32'd0;
            for (px4 = 0; px4 < 4; px4 = px4 + 1) begin
                sx = ((i % (IMG_W / 4)) * 4) + px4;
                if ((sx-128)*(sx-128) + (sy-128)*(sy-128) <= 120*120) begin
                    v = 84 - ((sx * 11) / 100);
                    if (((sx % 37) < 3) && ((sy % 41) < 3)) v = v + 130;
                end else begin
                    v = 4;
                end
                wtmp[px4*8 +: 8] = (v > 255) ? 8'hFF : v[7:0];
            end
            mem0[i] = wtmp;
            mem1[i] = wtmp;
        end

        if (USE_MEM_FILE != 0) begin
            $readmemh(MEM_FILE, mem0);
            $readmemh(MEM_FILE, mem1);
        end
    end

    //------------------------------------------------------------------------
    // Replay. The store index drops the low log2(UP) bits of each coordinate,
    // which is the 4x block replication the display image was built with, so
    // what leaves here is the original 1024x1024 image pixel for pixel.
    //------------------------------------------------------------------------
    reg [9:0] rx = 10'd0, ry = 10'd0;

    // The offsets wrap in ten bits, which is the frame width, so no clamping is
    // needed - and the corners of a DUST frame are unilluminated anyway.
    wire [9:0] rxs = rx + {{3{scroll_x[6]}}, scroll_x};
    wire [9:0] rys = ry + {{3{scroll_y[6]}}, scroll_y};

    wire [7:0]  bidx   = rxs[9:2];                  // binned column
    wire [7:0]  brow   = rys[9:2];
    wire [13:0] rd_ad  = {brow, bidx[7:2]};
    wire [1:0]  rd_sel = bidx[1:0];

    wire last_pix  = (rx == OUT_W - 1) && (ry == OUT_H - 1);
    wire first_pix = (rx == 10'd0) && (ry == 10'd0);

    // The display follows the scroll to the nearest binned pixel. It cannot show
    // the quarter-pixel part, and does not need to - that part is what the
    // centroid readout is for.
    wire [7:0]  dpx    = disp_x + {{5{scroll_x[6]}}, scroll_x[6:2]};
    wire [7:0]  dpy    = disp_y + {{5{scroll_y[6]}}, scroll_y[6:2]};
    wire [13:0] dp_ad  = {dpy, dpx[7:2]};
    wire [1:0]  dp_sel = dpx[1:0];

    always @(posedge clk) begin
        if (rst) begin
            rx <= 10'd0;
            ry <= 10'd0;
        end else begin
            if (!run) begin
                rx <= 10'd0;
                ry <= 10'd0;
            end else if (last_pix) begin
                rx <= 10'd0;
                ry <= 10'd0;
            end else if (rx == OUT_W - 1) begin
                rx <= 10'd0;
                ry <= ry + 10'd1;
            end else begin
                rx <= rx + 10'd1;
            end

        end
    end

    //------------------------------------------------------------------------
    // Buffer swap. The host asks whenever it likes; the swap happens at a frame
    // boundary, so the detector never sees half of one frame and half of
    // another - which would put a step change down the middle of the image and
    // a row of invented stars along it.
    //------------------------------------------------------------------------
    reg swap_pend = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            play_buf  <= 1'b0;
            swap_pend <= 1'b0;
        end else begin
            if (swap_req) swap_pend <= 1'b1;
            if (swap_pend && run && last_pix) begin
                play_buf  <= ~play_buf;
                swap_pend <= 1'b0;
            end
        end
    end

    //------------------------------------------------------------------------
    // Scroll offset. It only moves at a frame boundary, because moving it part
    // way through would tear the image across the detector's window.
    //
    // A triangle rather than a sawtooth: a sawtooth's wrap is a jump of eight
    // binned pixels, which throws the background followers out for a frame and
    // shows up as a burst of spurious stars. Reversing at the ends never moves
    // the image by more than one display pixel at a time.
    //------------------------------------------------------------------------
    localparam signed [6:0] SCROLL_LIMIT = 7'sd32;

    reg dir = 1'b0;      // 0 = increasing

    always @(posedge clk) begin
        if (rst) begin
            scroll_x <= 7'sd0;
            scroll_y <= 7'sd0;
            dir      <= 1'b0;
        end else if ((run && last_pix && scroll_en) || scroll_step) begin
            if (!dir) begin
                if (scroll_x >= SCROLL_LIMIT - 7'sd1) dir <= 1'b1;
                scroll_x <= scroll_x + 7'sd1;
            end else begin
                if (scroll_x <= -SCROLL_LIMIT + 7'sd1) dir <= 1'b0;
                scroll_x <= scroll_x - 7'sd1;
            end
            // A quarter of the horizontal rate, so the field slews along a
            // shallow diagonal instead of sliding along one axis.
            scroll_y <= {{2{scroll_x[6]}}, scroll_x[6:2]};
        end
    end

    //------------------------------------------------------------------------
    // Both reads in one always block, with nothing else in it. That is the
    // dual-port template Vivado's inference looks for; split across two blocks
    // it built a second copy of the whole store instead of using the second
    // port, which is 32 block RAMs the 7z010 does not have. Note also that
    // neither read is under a reset - a reset on a RAM output pushes the
    // register out into the fabric and the same duplication follows.
    //------------------------------------------------------------------------
    reg [31:0] wA0, wA1, wB0, wB1;
    reg [1:0]  rd_sel_d, dp_sel_d;

    // Port A: the host write, or the replay read. Never both, because the host
    // only ever writes the buffer that is not playing.
    //
    // **One address per port.** A block RAM port has a single address bus, so
    // writing at fb_addr while reading at rd_ad in the same always block is not
    // a port at all - Vivado cannot map it and builds the memory out of
    // something else, which came to 69 tiles of the 60 this part has. Muxing
    // the address is what makes it a port. The mux is free of consequence
    // because the two never happen to the same buffer.
    wire we0 = fb_we && (play_buf == 1'b1);
    wire we1 = fb_we && (play_buf == 1'b0);

    wire [13:0] adA0 = we0 ? fb_addr : rd_ad;
    wire [13:0] adA1 = we1 ? fb_addr : rd_ad;

    always @(posedge clk) begin
        if (we0) mem0[adA0] <= fb_data;
        else     wA0        <= mem0[adA0];
    end
    always @(posedge clk) begin
        if (we1) mem1[adA1] <= fb_data;
        else     wA1        <= mem1[adA1];
    end

    // Port B: the display.
    always @(posedge clk) wB0 <= mem0[dp_ad];
    always @(posedge clk) wB1 <= mem1[dp_ad];

    always @(posedge clk) begin
        rd_sel_d <= rd_sel;
        dp_sel_d <= dp_sel;
    end

    wire [31:0] wordA = play_buf ? wA1 : wA0;
    wire [31:0] wordB = play_buf ? wB1 : wB0;

    assign pix_data  = wordA[{rd_sel_d, 3'b000} +: 8];
    assign disp_data = wordB[{dp_sel_d, 3'b000} +: 8];

    //------------------------------------------------------------------------
    // The strobes and coordinates are captured on the same edge that captured
    // the pixel, all from the address side of that cycle - which is the only
    // way they stay aligned with it.
    //
    // frame_start lands on the first pixel rather than one cycle ahead of it.
    // The detector publishes its list and swaps banks on that edge, and the
    // earliest a star can be emitted into the new frame is nine rows later, so
    // nothing is lost by the overlap.
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            pix_valid   <= 1'b0;
            frame_start <= 1'b0;
        end else begin
            pix_valid   <= run;
            pix_x       <= rx;
            pix_y       <= ry;
            frame_start <= run && first_pix;
        end
    end

endmodule
