`timescale 1ns / 1ps

//============================================================================
// Module: cam_capture_tb_wrapper
// Description: cam_capture writing into a real fb_mem, with a read port
//              brought out so cocotb can check what actually landed in the
//              frame buffer rather than just watching the write strobes.
//
// SIMULATION ONLY.
//============================================================================

module cam_capture_tb_wrapper (
    // Camera side
    input  wire        pclk,
    input  wire        href,
    input  wire        vsync,
    input  wire [7:0]  data,

    // Read-back side, driven by the testbench
    input  wire        rd_clk,
    input  wire [16:0] rd_addr,
    output wire [15:0] rd_data,

    // Observation
    output wire        cap_wr_en,
    output wire [16:0] cap_addr,
    output wire [15:0] cap_data
);

    cam_capture u_capture (
        .ov7670_pclk  ( pclk      ),
        .ov7670_href  ( href      ),
        .ov7670_vsync ( vsync     ),
        .ov7670_data  ( data      ),
        .cap_wr_en    ( cap_wr_en ),
        .cap_addr     ( cap_addr  ),
        .cap_data     ( cap_data  )
    );

    fb_mem u_fb_mem (
        .clk_wr  ( pclk      ),
        .wr_en   ( cap_wr_en ),
        .addr_wr ( cap_addr  ),
        .data_wr ( cap_data  ),
        .clk_rd  ( rd_clk    ),
        .addr_rd ( rd_addr   ),
        .data_rd ( rd_data   )
    );

endmodule
