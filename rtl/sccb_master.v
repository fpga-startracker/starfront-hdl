`timescale 1ns / 1ps

//============================================================================
// Module: sccb_master
// Description: SCCB (OmniVision 2-wire) master with both WRITE and READ
//              support.
//
//   The Basys 3 predecessor of this project was write-only, which made every
//   camera failure look identical: nothing happened. Being able to read back
//   the product ID is what turns "the camera is not working" into a specific
//   answer, so the read path is the whole point of this module.
//
//   Transactions (SCCB has no ACK; the 9th bit of every byte is "don't care"):
//
//     WRITE (3-phase):
//       START  [0x42, X]  [sub_addr, X]  [wr_data, X]  STOP
//
//     READ (2-phase write, then 2-phase read):
//       START  [0x42, X]  [sub_addr, X]  STOP
//       START  [0x43, X]  [<-rd_data, NA]  STOP
//
//   SIO_C is push-pull (the OV7670 never stretches the clock). SIO_D is open
//   drain: the module only ever drives it low, and releases it to let the
//   external pull-up produce a one. The IOBUF lives in the top level, so this
//   module exposes the tri-state as separate _out / _oe / _in signals.
//
//   Every bit is four quarter-periods:
//     Q1  SIO_C low
//     Q2  SIO_D driven (write) or left released (read)
//     Q3  SIO_C high
//     Q4  slave has sampled (write) / master samples (read), then advance
//============================================================================

module sccb_master #(
    parameter integer CLK_FREQ  = 25_000_000,
    parameter integer SCCB_FREQ = 100_000
) (
    input  wire        clk,
    input  wire        rst,

    // Control interface
    input  wire        start,           // 1-cycle pulse, ignored while busy
    input  wire        rw,              // 0 = write, 1 = read
    input  wire [7:0]  sub_addr,
    input  wire [7:0]  wr_data,
    output wire [7:0]  rd_data,
    output wire        busy,
    output wire        done,            // 1-cycle pulse at end of transaction

    // SCCB bus
    output wire        sccb_sio_c,
    output wire        sccb_sio_d_out,  // always 0 - open drain
    output wire        sccb_sio_d_oe,   // 1 = drive low, 0 = release
    input  wire        sccb_sio_d_in,

    output wire [4:0]  dbg_state
);

    //------------------------------------------------------------------------
    // Constants
    //------------------------------------------------------------------------
    localparam [7:0] OV7670_ADDR_W = 8'h42;
    localparam [7:0] OV7670_ADDR_R = 8'h43;

    localparam integer QUARTER_PERIOD = CLK_FREQ / (4 * SCCB_FREQ);
    localparam integer BUS_FREE_TIME  = CLK_FREQ / SCCB_FREQ;

    //------------------------------------------------------------------------
    // States
    //------------------------------------------------------------------------
    localparam ST_IDLE    = 5'd0;
    localparam ST_START   = 5'd1;
    localparam ST_LOAD    = 5'd2;
    localparam ST_TX_Q1   = 5'd3;
    localparam ST_TX_Q2   = 5'd4;
    localparam ST_TX_Q3   = 5'd5;
    localparam ST_TX_Q4   = 5'd6;
    localparam ST_RX_Q1   = 5'd7;
    localparam ST_RX_Q2   = 5'd8;
    localparam ST_RX_Q3   = 5'd9;
    localparam ST_RX_Q4   = 5'd10;
    localparam ST_STOP_Q1 = 5'd11;
    localparam ST_STOP_Q2 = 5'd12;
    localparam ST_STOP_Q3 = 5'd13;
    localparam ST_STOP_Q4 = 5'd14;
    localparam ST_BUSFREE = 5'd15;
    localparam ST_RESTART = 5'd16;
    localparam ST_DONE    = 5'd17;
    localparam ST_TIMER   = 5'd18;

    reg [4:0]  state        = ST_IDLE;
    reg [4:0]  return_state = ST_IDLE;
    reg [15:0] timer_cnt    = 16'd0;

    reg [7:0]  tx_byte  = 8'd0;
    reg [7:0]  rx_byte  = 8'd0;
    reg [3:0]  bit_idx  = 4'd0;      // 0-8, 8 = don't-care / NA bit
    reg [1:0]  byte_cnt = 2'd0;
    reg        phase    = 1'b0;      // 0 = address write phase, 1 = read phase
    reg        stop_to_restart = 1'b0;

    reg        sio_c_oe = 1'b0;      // 1 = drive SIO_C low
    reg        sio_d_oe = 1'b0;      // 1 = drive SIO_D low
    reg        done_reg = 1'b0;

    reg [7:0]  sub_lat = 8'd0;
    reg [7:0]  wd_lat  = 8'd0;
    reg        rw_lat  = 1'b0;

    //------------------------------------------------------------------------
    // SIO_D is an asynchronous input during a read - synchronise it
    //------------------------------------------------------------------------
    wire sio_d_in_s;
    cdc_sync #(.WIDTH(1)) u_sync_siod (
        .clk  ( clk           ),
        .din  ( sccb_sio_d_in ),
        .dout ( sio_d_in_s    )
    );

    //------------------------------------------------------------------------
    // Outputs
    //------------------------------------------------------------------------
    assign sccb_sio_c     = ~sio_c_oe;
    assign sccb_sio_d_out = 1'b0;
    assign sccb_sio_d_oe  = sio_d_oe;
    assign rd_data        = rx_byte;
    assign done           = done_reg;
    assign busy           = (state != ST_IDLE);
    assign dbg_state      = state;

    //------------------------------------------------------------------------
    // FSM
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state           <= ST_IDLE;
            return_state    <= ST_IDLE;
            timer_cnt       <= 16'd0;
            sio_c_oe        <= 1'b0;
            sio_d_oe        <= 1'b0;
            done_reg        <= 1'b0;
            bit_idx         <= 4'd0;
            byte_cnt        <= 2'd0;
            phase           <= 1'b0;
            stop_to_restart <= 1'b0;
            tx_byte         <= 8'd0;
            rx_byte         <= 8'd0;
        end else begin
            done_reg <= 1'b0;

            case (state)

            //----------------------------------------------------------------
            ST_IDLE: begin
                sio_c_oe <= 1'b0;
                sio_d_oe <= 1'b0;
                if (start) begin
                    sub_lat         <= sub_addr;
                    wd_lat          <= wr_data;
                    rw_lat          <= rw;
                    byte_cnt        <= 2'd0;
                    phase           <= 1'b0;
                    stop_to_restart <= 1'b0;
                    // Clear the receive register so a read that never sees the
                    // camera returns 0xFF from the pull-up rather than the
                    // previous transaction's value.
                    rx_byte         <= 8'd0;
                    // START: pull SIO_D low while SIO_C is high
                    sio_d_oe        <= 1'b1;
                    state           <= ST_TIMER;
                    return_state    <= ST_START;
                    timer_cnt       <= QUARTER_PERIOD[15:0];
                end
            end

            ST_START: state <= ST_LOAD;

            //----------------------------------------------------------------
            // Decide what the next byte period does
            //----------------------------------------------------------------
            ST_LOAD: begin
                bit_idx <= 4'd0;
                if (phase == 1'b0) begin
                    case (byte_cnt)
                    2'd0: begin
                        tx_byte      <= OV7670_ADDR_W;
                        state        <= ST_TIMER;
                        return_state <= ST_TX_Q1;
                        timer_cnt    <= 16'd1;
                    end
                    2'd1: begin
                        tx_byte      <= sub_lat;
                        state        <= ST_TIMER;
                        return_state <= ST_TX_Q1;
                        timer_cnt    <= 16'd1;
                    end
                    2'd2: begin
                        if (rw_lat) begin
                            // Address phase of a read ends here; restart after STOP
                            stop_to_restart <= 1'b1;
                            state           <= ST_TIMER;
                            return_state    <= ST_STOP_Q1;
                            timer_cnt       <= QUARTER_PERIOD[15:0];
                        end else begin
                            tx_byte      <= wd_lat;
                            state        <= ST_TIMER;
                            return_state <= ST_TX_Q1;
                            timer_cnt    <= 16'd1;
                        end
                    end
                    default: begin
                        stop_to_restart <= 1'b0;
                        state           <= ST_TIMER;
                        return_state    <= ST_STOP_Q1;
                        timer_cnt       <= QUARTER_PERIOD[15:0];
                    end
                    endcase
                end else begin
                    case (byte_cnt)
                    2'd0: begin
                        tx_byte      <= OV7670_ADDR_R;
                        state        <= ST_TIMER;
                        return_state <= ST_TX_Q1;
                        timer_cnt    <= 16'd1;
                    end
                    2'd1: begin
                        state        <= ST_TIMER;
                        return_state <= ST_RX_Q1;
                        timer_cnt    <= 16'd1;
                    end
                    default: begin
                        stop_to_restart <= 1'b0;
                        state           <= ST_TIMER;
                        return_state    <= ST_STOP_Q1;
                        timer_cnt       <= QUARTER_PERIOD[15:0];
                    end
                    endcase
                end
            end

            //----------------------------------------------------------------
            // Transmit one bit
            //----------------------------------------------------------------
            ST_TX_Q1: begin
                sio_c_oe     <= 1'b1;                    // SIO_C low
                state        <= ST_TIMER;
                return_state <= ST_TX_Q2;
                timer_cnt    <= QUARTER_PERIOD[15:0];
            end

            ST_TX_Q2: begin
                // 9th bit is the don't-care slot: release the bus
                sio_d_oe     <= (bit_idx == 4'd8) ? 1'b0 : ~tx_byte[7];
                state        <= ST_TIMER;
                return_state <= ST_TX_Q3;
                timer_cnt    <= QUARTER_PERIOD[15:0];
            end

            ST_TX_Q3: begin
                sio_c_oe     <= 1'b0;                    // SIO_C high, slave samples
                state        <= ST_TIMER;
                return_state <= ST_TX_Q4;
                timer_cnt    <= QUARTER_PERIOD[15:0];
            end

            ST_TX_Q4: begin
                if (bit_idx == 4'd8) begin
                    byte_cnt     <= byte_cnt + 2'd1;
                    return_state <= ST_LOAD;
                end else begin
                    tx_byte      <= {tx_byte[6:0], 1'b0};  // MSB first
                    bit_idx      <= bit_idx + 4'd1;
                    return_state <= ST_TX_Q1;
                end
                state     <= ST_TIMER;
                timer_cnt <= QUARTER_PERIOD[15:0];
            end

            //----------------------------------------------------------------
            // Receive one bit (SIO_D released the whole time, including the
            // trailing NA bit which the pull-up drives high)
            //----------------------------------------------------------------
            ST_RX_Q1: begin
                sio_c_oe     <= 1'b1;
                sio_d_oe     <= 1'b0;
                state        <= ST_TIMER;
                return_state <= ST_RX_Q2;
                timer_cnt    <= QUARTER_PERIOD[15:0];
            end

            ST_RX_Q2: begin
                state        <= ST_TIMER;
                return_state <= ST_RX_Q3;
                timer_cnt    <= QUARTER_PERIOD[15:0];
            end

            ST_RX_Q3: begin
                sio_c_oe     <= 1'b0;
                state        <= ST_TIMER;
                return_state <= ST_RX_Q4;
                timer_cnt    <= QUARTER_PERIOD[15:0];
            end

            ST_RX_Q4: begin
                // One quarter after the rising edge = middle of the high phase
                if (bit_idx < 4'd8)
                    rx_byte <= {rx_byte[6:0], sio_d_in_s};

                if (bit_idx == 4'd8) begin
                    byte_cnt     <= byte_cnt + 2'd1;
                    return_state <= ST_LOAD;
                end else begin
                    bit_idx      <= bit_idx + 4'd1;
                    return_state <= ST_RX_Q1;
                end
                state     <= ST_TIMER;
                timer_cnt <= QUARTER_PERIOD[15:0];
            end

            //----------------------------------------------------------------
            // STOP: SIO_D rises while SIO_C is high
            //----------------------------------------------------------------
            ST_STOP_Q1: begin
                sio_c_oe     <= 1'b1;
                state        <= ST_TIMER;
                return_state <= ST_STOP_Q2;
                timer_cnt    <= QUARTER_PERIOD[15:0];
            end

            ST_STOP_Q2: begin
                sio_d_oe     <= 1'b1;
                state        <= ST_TIMER;
                return_state <= ST_STOP_Q3;
                timer_cnt    <= QUARTER_PERIOD[15:0];
            end

            ST_STOP_Q3: begin
                sio_c_oe     <= 1'b0;
                state        <= ST_TIMER;
                return_state <= ST_STOP_Q4;
                timer_cnt    <= QUARTER_PERIOD[15:0];
            end

            ST_STOP_Q4: begin
                sio_d_oe     <= 1'b0;                    // release -> STOP
                state        <= ST_TIMER;
                return_state <= ST_BUSFREE;
                timer_cnt    <= BUS_FREE_TIME[15:0];
            end

            ST_BUSFREE: begin
                state <= stop_to_restart ? ST_RESTART : ST_DONE;
            end

            //----------------------------------------------------------------
            ST_RESTART: begin
                phase           <= 1'b1;
                byte_cnt        <= 2'd0;
                stop_to_restart <= 1'b0;
                sio_d_oe        <= 1'b1;                 // START for read phase
                state           <= ST_TIMER;
                return_state    <= ST_START;
                timer_cnt       <= QUARTER_PERIOD[15:0];
            end

            ST_DONE: begin
                done_reg <= 1'b1;
                state    <= ST_IDLE;
            end

            //----------------------------------------------------------------
            ST_TIMER: begin
                if (timer_cnt == 16'd0)
                    state <= return_state;
                else
                    timer_cnt <= timer_cnt - 16'd1;
            end

            default: state <= ST_IDLE;

            endcase
        end
    end

endmodule
