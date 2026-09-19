`timescale 1ns / 1ps

//============================================================================
// Module: region_grow
// Description: The 8-connected component of a WIN x WIN threshold mask that
//              contains the window's centre pixel. Combinational.
//
//   This is the paper's region growing (section 4.2) with the stack taken out.
//   The paper walks a stack of candidate pixels over an image held in RAM,
//   which costs random access to a frame store and a number of cycles that
//   depends on the cluster. Inside a fixed window the same set falls out of
//   HALF rounds of dilation intersected with the mask, because every pixel of
//   a WIN x WIN window is within HALF steps of the centre under 8-connectivity
//   and the iteration is therefore at its fixed point after HALF rounds. Not
//   an approximation - the same set, in no cycles at all.
//
//   HALF rounds is about eight levels of LUT logic. At a 25 MHz pixel clock
//   there are 40 ns to spend and this uses a quarter of it, so the whole thing
//   sits inside the cycle that captures the cluster and the centroid engine
//   never has to spend a state on it. That matters more than it sounds: the
//   engine can only hold one cluster, so every cycle it stays busy is a cycle
//   in which a second star arriving would be dropped.
//============================================================================

module region_grow #(
    parameter integer WIN  = 9
) (
    input  wire [WIN*WIN-1:0] mask,     // pixels above the grow threshold
    output wire [WIN*WIN-1:0] region    // the component containing the centre
);

    localparam integer NPIX  = WIN * WIN;
    localparam integer HALF  = WIN / 2;
    localparam integer CTR   = HALF * WIN + HALF;

    function [NPIX-1:0] dilate8;
        input [NPIX-1:0] m;
        integer rr, cc;
        reg [NPIX-1:0] o;
        begin
            o = m;
            for (rr = 0; rr < WIN; rr = rr + 1)
                for (cc = 0; cc < WIN; cc = cc + 1) begin
                    if (rr > 0)                   o[rr*WIN+cc] = o[rr*WIN+cc] | m[(rr-1)*WIN+cc];
                    if (rr < WIN-1)               o[rr*WIN+cc] = o[rr*WIN+cc] | m[(rr+1)*WIN+cc];
                    if (cc > 0)                   o[rr*WIN+cc] = o[rr*WIN+cc] | m[rr*WIN+cc-1];
                    if (cc < WIN-1)               o[rr*WIN+cc] = o[rr*WIN+cc] | m[rr*WIN+cc+1];
                    if (rr > 0     && cc > 0)     o[rr*WIN+cc] = o[rr*WIN+cc] | m[(rr-1)*WIN+cc-1];
                    if (rr > 0     && cc < WIN-1) o[rr*WIN+cc] = o[rr*WIN+cc] | m[(rr-1)*WIN+cc+1];
                    if (rr < WIN-1 && cc > 0)     o[rr*WIN+cc] = o[rr*WIN+cc] | m[(rr+1)*WIN+cc-1];
                    if (rr < WIN-1 && cc < WIN-1) o[rr*WIN+cc] = o[rr*WIN+cc] | m[(rr+1)*WIN+cc+1];
                end
            dilate8 = o;
        end
    endfunction

    wire [NPIX-1:0] step [0:HALF];

    assign step[0] = {{(NPIX-1){1'b0}}, 1'b1} << CTR;

    genvar k;
    generate
        for (k = 0; k < HALF; k = k + 1) begin : g_grow
            assign step[k+1] = step[k] | (dilate8(step[k]) & mask);
        end
    endgenerate

    assign region = step[HALF];

endmodule
