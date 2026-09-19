`timescale 1ns / 1ps

//============================================================================
// Module: axi_bench_if
// Description: The host's way in and out. An AXI4 slave behind Vivado's
//              jtag_axi master, so a PC can push frames into the frame store
//              and read the star list back, over the same USB cable that
//              carries the bitstream.
//
//   Why this exists at all: the AX7010's 32 MB QSPI flash hangs off PS_MIO0-6,
//   which is PS dedicated I/O, and the Zynq's Quad-SPI controller is MIO-only -
//   it cannot be routed to EMIO. The only other memory a PL-only design can
//   reach on this board is a 512-byte I2C EEPROM. So the entire bulk storage
//   available to this design is the 60 block RAM tiles inside the chip, and
//   anything resembling video has to arrive over JTAG.
//
//   Reading the star list back matters more than the frames going in. Until
//   now the accuracy figures were the software model's, checked against the
//   RTL on two frames in simulation; with a readback the board can be scored
//   against the DUST truth directly, frame after frame, which is the one gap
//   the accuracy review could not close.
//
//   Address map, byte addresses, decoded on bits 19:16:
//
//     0x0_0000  write  frame store, 16384 words of four pixels, little-endian
//                      (pixel at x   in bits  7:0
//                       pixel at x+1 in bits 15:8, and so on)
//     0x1_0000  read   star list, two words per star, 64 stars
//                        +0  {y_fix[15:0], x_fix[15:0]}   8.8 binned pixels
//                        +4  {5'b0, npx[6:0], sum[19:0]}
//     0x2_0000  r/w    registers:
//                        +0x00 R  magic, "STFR"
//                        +0x04 R  star_count in [6:0], dropped in [14:8],
//                                 overflow in [16]
//                        +0x08 R  frame counter
//                        +0x0C R  {mad_acc[13:0], thr_code[7:0], bg_code[7:0]}
//                        +0x10 R  frames per second
//                        +0x14 R  scroll offset, display pixels, signed
//                        +0x18 R  which buffer is playing
//                        +0x20 W  control: bit0 swap, bit1 scroll, bit2 hold,
//                                 bit3 take the controls from the keys,
//                                 bit4 scroll one step
//
//   Only INCR bursts of 32-bit words are supported, which is all jtag_axi
//   issues. Byte strobes are ignored: a partial word write would be a host bug
//   and silently honouring it would hide one.
//============================================================================

module axi_bench_if #(
    parameter integer ADDR_W = 20,
    parameter [31:0]  MAGIC  = 32'h5354_4652      // "STFR"
) (
    input  wire        aclk,
    input  wire        aresetn,

    // ---- AXI4 slave, write ----
    input  wire [ADDR_W-1:0] s_awaddr,
    input  wire [7:0]        s_awlen,
    input  wire              s_awvalid,
    output wire              s_awready,
    input  wire [31:0]       s_wdata,
    input  wire [3:0]        s_wstrb,
    input  wire              s_wlast,
    input  wire              s_wvalid,
    output wire              s_wready,
    output wire [1:0]        s_bresp,
    output wire              s_bvalid,
    input  wire              s_bready,

    // ---- AXI4 slave, read ----
    input  wire [ADDR_W-1:0] s_araddr,
    input  wire [7:0]        s_arlen,
    input  wire              s_arvalid,
    output wire              s_arready,
    output wire [31:0]       s_rdata,
    output wire [1:0]        s_rresp,
    output wire              s_rlast,
    output wire              s_rvalid,
    input  wire              s_rready,

    // ---- frame store write port ----
    output reg              fb_we,
    output reg  [13:0]      fb_addr,
    output reg  [31:0]      fb_data,

    // ---- star list read port, combinational ----
    output wire [5:0]  sl_addr,
    input  wire [15:0] sl_x,
    input  wire [15:0] sl_y,
    input  wire [19:0] sl_sum,
    input  wire [6:0]  sl_npx,

    // ---- status in ----
    input  wire [6:0]  star_count,
    input  wire [6:0]  dropped,
    input  wire        overflow,
    input  wire [15:0] frame_count,
    input  wire [7:0]  fps,
    input  wire [7:0]  bg_code,
    input  wire [7:0]  thr_code,
    input  wire [13:0] mad_acc,
    input  wire signed [6:0] scroll_x,
    input  wire        play_buf,

    // ---- control out ----
    output reg         swap_req,     // one pulse: show the buffer just written
    output reg         host_scroll_en,
    output reg         host_hold,
    output reg         host_override,// the host has taken the controls from the keys
    output reg         host_step     // one pulse: scroll on by one display pixel
);

    localparam [3:0] RGN_FB   = 4'h0,
                     RGN_LIST = 4'h1,
                     RGN_REG  = 4'h2;

    //------------------------------------------------------------------------
    // Write channel
    //------------------------------------------------------------------------
    localparam [1:0] W_IDLE = 2'd0, W_DATA = 2'd1, W_RESP = 2'd2;

    reg [1:0]  wstate = W_IDLE;
    reg [3:0]  wrgn;
    reg [15:0] wcur;                 // word address inside the region

    assign s_awready = (wstate == W_IDLE);
    assign s_wready  = (wstate == W_DATA);
    assign s_bvalid  = (wstate == W_RESP);
    assign s_bresp   = 2'b00;        // OKAY, always: there is nothing to fail

    always @(posedge aclk) begin
        fb_we     <= 1'b0;
        swap_req  <= 1'b0;
        host_step <= 1'b0;

        if (!aresetn) begin
            wstate         <= W_IDLE;
            host_scroll_en <= 1'b0;
            host_hold      <= 1'b0;
            host_override  <= 1'b0;
            host_step      <= 1'b0;
        end else begin
            case (wstate)

            W_IDLE: if (s_awvalid) begin
                wrgn   <= s_awaddr[19:16];
                wcur   <= {2'b00, s_awaddr[15:2]};
                wstate <= W_DATA;
            end

            W_DATA: if (s_wvalid) begin
                case (wrgn)
                RGN_FB: begin
                    fb_we   <= 1'b1;
                    fb_addr <= wcur[13:0];
                    fb_data <= s_wdata;
                end
                RGN_REG: case (wcur[3:0])
                    4'h8: begin                    // 0x2_0020 control
                        swap_req       <= s_wdata[0];
                        host_scroll_en <= s_wdata[1];
                        host_hold      <= s_wdata[2];
                        host_override  <= s_wdata[3];
                        host_step      <= s_wdata[4];
                    end
                    default: ;
                endcase
                default: ;
                endcase

                wcur <= wcur + 16'd1;
                if (s_wlast) wstate <= W_RESP;
            end

            W_RESP: if (s_bready) wstate <= W_IDLE;

            default: wstate <= W_IDLE;
            endcase
        end
    end

    //------------------------------------------------------------------------
    // Read channel
    //------------------------------------------------------------------------
    localparam [1:0] R_IDLE = 2'd0, R_DATA = 2'd1;

    reg [1:0]  rstate = R_IDLE;
    reg [3:0]  rrgn;
    reg [15:0] rcur;
    reg [8:0]  rleft;

    assign s_arready = (rstate == R_IDLE);
    assign s_rvalid  = (rstate == R_DATA);
    assign s_rresp   = 2'b00;
    assign s_rlast   = (rstate == R_DATA) && (rleft == 9'd0);

    // The star list is distributed RAM with a combinational read, so the data
    // for the word being presented is available in the same cycle.
    assign sl_addr = rcur[6:1];

    reg [31:0] rdata_r;
    assign s_rdata = rdata_r;

    always @(*) begin
        case (rrgn)
        RGN_LIST: rdata_r = rcur[0] ? {5'b0, sl_npx, sl_sum}
                                    : {sl_y, sl_x};
        RGN_REG:  case (rcur[3:0])
            4'h0:    rdata_r = MAGIC;
            // 15 + 1 + 1 + 7 + 1 + 7 = 32. The first version of this line came
            // to 33 and the whole word silently shifted, which is the sort of
            // thing a concatenation will do for you without complaint.
            4'h1:    rdata_r = {15'd0, overflow, 1'b0, dropped, 1'b0, star_count};
            4'h2:    rdata_r = {16'd0, frame_count};
            4'h3:    rdata_r = {2'd0, mad_acc, thr_code, bg_code};
            4'h4:    rdata_r = {24'd0, fps};
            4'h5:    rdata_r = {24'd0, 1'b0, scroll_x};
            4'h6:    rdata_r = {31'd0, play_buf};
            default: rdata_r = 32'd0;
        endcase
        default:  rdata_r = 32'hDEAD_BEEF;    // an unmapped region, said loudly
        endcase
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            rstate <= R_IDLE;
        end else begin
            case (rstate)

            R_IDLE: if (s_arvalid) begin
                rrgn   <= s_araddr[19:16];
                rcur   <= {2'b00, s_araddr[15:2]};
                rleft  <= {1'b0, s_arlen};
                rstate <= R_DATA;
            end

            R_DATA: if (s_rready) begin
                rcur <= rcur + 16'd1;
                if (rleft == 9'd0) rstate <= R_IDLE;
                else               rleft  <= rleft - 9'd1;
            end

            default: rstate <= R_IDLE;
            endcase
        end
    end

endmodule
