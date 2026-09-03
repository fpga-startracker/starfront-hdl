`timescale 1ns / 1ps

//============================================================================
// Module: sccb_tb_wrapper
// Description: Ties sccb_master to the OV7670 slave model over a real
//              tri-state SIO_D with a pull-up, and flattens everything cocotb
//              needs into plain ports.
//
//   SCCB_FREQ is raised well above the 100 kHz used on hardware so the tests
//   finish quickly; the FSM is parameterised, so every state is still
//   exercised the same way.
//
// SIMULATION ONLY.
//============================================================================

module sccb_tb_wrapper #(
    parameter integer CLK_FREQ  = 25_000_000,
    parameter integer SCCB_FREQ = 500_000
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire        rw,
    input  wire [7:0]  sub_addr,
    input  wire [7:0]  wr_data,
    output wire [7:0]  rd_data,
    output wire        busy,
    output wire        done,
    output wire [4:0]  dbg_state,

    output wire        sio_c,
    output wire [7:0]  slave_last_sub,
    output wire [7:0]  slave_last_data,
    output wire [7:0]  slave_id_byte
);

    wire sio_d;
    wire sio_d_out;
    wire sio_d_oe;

    pullup pu_sio_d (sio_d);

    assign sio_d = sio_d_oe ? sio_d_out : 1'bz;

    sccb_master #(
        .CLK_FREQ  ( CLK_FREQ  ),
        .SCCB_FREQ ( SCCB_FREQ )
    ) u_dut (
        .clk            ( clk       ),
        .rst            ( rst       ),
        .start          ( start     ),
        .rw             ( rw        ),
        .sub_addr       ( sub_addr  ),
        .wr_data        ( wr_data   ),
        .rd_data        ( rd_data   ),
        .busy           ( busy      ),
        .done           ( done      ),
        .sccb_sio_c     ( sio_c     ),
        .sccb_sio_d_out ( sio_d_out ),
        .sccb_sio_d_oe  ( sio_d_oe  ),
        .sccb_sio_d_in  ( sio_d     ),
        .dbg_state      ( dbg_state )
    );

    ov7670_sccb_slave_model u_slave (
        .sio_c         ( sio_c           ),
        .sio_d         ( sio_d           ),
        .dbg_last_sub  ( slave_last_sub  ),
        .dbg_last_data ( slave_last_data ),
        .dbg_id_byte   ( slave_id_byte   )
    );

endmodule
