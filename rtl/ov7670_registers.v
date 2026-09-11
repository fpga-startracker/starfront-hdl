`timescale 1ns / 1ps

//============================================================================
// Module: ov7670_registers
// Description: 94-entry OV7670 configuration ROM for native RGB444 output.
//
// Carried over unchanged from the Basys 3 OV7670 project, where this exact
// table produced a correct live colour image. Sources: westonb/OV7670-Verilog
// (MIT 6.111), the Linux kernel ov7670.c driver, and the Hamsterworks project.
//
// Output format: RGB565 (COM15[5:4] = 01, with RGB444 switched off at 0x8C),
// full VGA 640x480 with camera-side scaling OFF - the FPGA does the
// downsampling. RGB565 replaced the original RGB444 because four bits per
// channel is only sixteen levels: in a dim scene almost every pixel sits in the
// bottom two or three of them, so a single LSB of sensor noise is a sixth of the
// signal and the picture looks like coloured static. Green gets six bits here
// and red and blue five, which is three to four times finer.
//
// color_bar selects the sensor's built-in 8-bar test pattern. Per the datasheet
// the two selector bits are (SCALING_YSC[7], SCALING_XSC[7]) in that order:
// 01 is a shifting "1", 10 is the 8-bar colour bar. Setting XSC[7] alone - which
// is what the Basys 3 project's notes said to do - gives the shifting pattern,
// confirmed on hardware. The colour bar needs YSC[7].
// The bars bypass the image sensor entirely, which splits "is the problem in the
// FPGA or in the camera?" in one step - see docs/ov7670_notes.md, pitfall 8.
// It is an input rather than a parameter so KEY3 can toggle it on the bench
// instead of costing a nine minute rebuild.
//
// Every value here is load bearing. Read docs/ov7670_notes.md before changing
// any of them; several are undocumented registers that other projects found the
// hard way (0xB0 = 0x84 in particular).
//============================================================================

module ov7670_registers (
    input  wire [7:0]  index,
    input  wire        color_bar,    // 1 = 8-bar test pattern instead of the image
    input  wire        gray_mode,    // 1 = YUV422 grayscale mode, 0 = RGB565 mode
    input  wire [1:0]  hstart_sel,   // horizontal window position, see below
    output reg  [15:0] data
);

    //------------------------------------------------------------------------
    // Horizontal window position.
    //
    // HSTART and HSTOP pick which 640 of the sensor's 784 column clocks come
    // out. All four options below are 640 wide; they differ only in where that
    // window sits. Landing it over the array's dummy columns produces a band of
    // junk at one edge of the picture, which is not fixable downstream - so the
    // position is selectable at runtime rather than being a rebuild away.
    //
    //   HSTART_full = (0x17 << 3) | HREF[2:0]
    //   HSTOP_full  = (0x18 << 3) | HREF[5:3]
    //   width       = (HSTOP_full - HSTART_full) mod 784
    //------------------------------------------------------------------------
    reg [7:0] hstart_reg;
    reg [7:0] hstop_reg;
    reg [7:0] href_reg;

    always @(*) begin
        case (hstart_sel)
        2'd0: begin   // start 176 - as inherited from the Basys 3 project
            hstart_reg = 8'h16; hstop_reg = 8'h04; href_reg = 8'h80;
        end
        2'd1: begin   // start 158 - the Linux kernel ov7670.c values
            hstart_reg = 8'h13; hstop_reg = 8'h01; href_reg = 8'hB6;
        end
        2'd2: begin   // start 144
            hstart_reg = 8'h12; hstop_reg = 8'h00; href_reg = 8'h80;
        end
        default: begin // start 192
            hstart_reg = 8'h18; hstop_reg = 8'h06; href_reg = 8'h80;
        end
        endcase
    end

    localparam SENTINEL = 16'hFF_FF;

    always @(*) begin
        case (index)

        //==============================================================
        // SOFTWARE RESET (must be first, wait >=1ms after)
        //==============================================================
        8'd0:  data = 16'h12_80;  // COM7: Reset all registers

        //==============================================================
        // OUTPUT FORMAT — RGB565 or YUV422 grayscale
        //==============================================================
        8'd1:  data = gray_mode ? 16'h12_00 : 16'h12_04;  // COM7: YUV422 grayscale or RGB output
        8'd2:  data = gray_mode ? 16'h40_00 : 16'h40_D0;  // COM15: default YUV path or RGB565
        8'd3:  data = 16'h8C_00;  // RGB444 off; harmless in either mode
        8'd4:  data = 16'h04_00;  // COM1: No CCIR656

        //==============================================================
        // CLOCK
        //==============================================================
        8'd5:  data = 16'h11_80;  // CLKRC: Use external clock directly
        8'd6:  data = 16'h6B_0A;  // DBLV: PLL bypass, reserved bits

        //==============================================================
        // DATA FORMAT & BYTE ORDER
        //==============================================================
        8'd7:  data = 16'h3A_04;  // TSLB: Standard byte order, auto-window
        8'd8:  data = 16'h3D_C0;  // COM13: Gamma enable + UV sat auto

        //==============================================================
        // COLOR MATRIX (RGB565 coefficients — Linux kernel / OmniVision)
        //==============================================================
        8'd9:  data = 16'h4F_B3;  // MTX1
        8'd10: data = 16'h50_B3;  // MTX2
        8'd11: data = 16'h51_00;  // MTX3
        8'd12: data = 16'h52_3D;  // MTX4
        8'd13: data = 16'h53_A7;  // MTX5
        8'd14: data = 16'h54_E4;  // MTX6
        8'd15: data = 16'h58_9E;  // MTXS: Matrix sign register

        //==============================================================
        // AGC / AEC / AWB
        //==============================================================
        8'd16: data = 16'h13_E0;  // COM8: Disable AGC+AEC+AWB temporarily
        8'd17: data = 16'h00_00;  // GAIN: Reset gain
        8'd18: data = 16'h10_00;  // AECH: Reset exposure
        8'd19: data = 16'h0D_40;  // COM4: Reserved magic bit
        8'd20: data = 16'h14_18;  // COM9: AGC ceiling 4x
        8'd21: data = 16'hA5_05;  // BD50MAX
        8'd22: data = 16'hAB_07;  // BD60MAX
        8'd23: data = 16'h24_95;  // AEW: AGC upper limit
        8'd24: data = 16'h25_33;  // AEB: AGC lower limit
        8'd25: data = 16'h26_E3;  // VPT: AGC/AEC fast mode region
        8'd26: data = 16'h9F_78;  // HAECC1
        8'd27: data = 16'hA0_68;  // HAECC2
        8'd28: data = 16'hA1_03;  // HAECC3
        8'd29: data = 16'hA6_D8;  // HAECC4
        8'd30: data = 16'hA7_D8;  // HAECC5
        8'd31: data = 16'hA8_F0;  // HAECC6
        8'd32: data = 16'hA9_90;  // HAECC7
        8'd33: data = 16'hAA_94;  // HAECC8
        8'd34: data = 16'h13_E7;  // COM8: Re-enable AGC + AEC + AWB

        //==============================================================
        // GAMMA CURVE
        //==============================================================
        8'd35: data = 16'h7A_20;  // SLOP
        8'd36: data = 16'h7B_10;  // GAM1
        8'd37: data = 16'h7C_1E;  // GAM2
        8'd38: data = 16'h7D_35;  // GAM3
        8'd39: data = 16'h7E_5A;  // GAM4
        8'd40: data = 16'h7F_69;  // GAM5
        8'd41: data = 16'h80_76;  // GAM6
        8'd42: data = 16'h81_80;  // GAM7
        8'd43: data = 16'h82_88;  // GAM8
        8'd44: data = 16'h83_8F;  // GAM9
        8'd45: data = 16'h84_96;  // GAM10
        8'd46: data = 16'h85_A3;  // GAM11
        8'd47: data = 16'h86_AF;  // GAM12
        8'd48: data = 16'h87_C4;  // GAM13
        8'd49: data = 16'h88_D7;  // GAM14
        8'd50: data = 16'h89_E8;  // GAM15

        //==============================================================
        // WINDOW / TIMING
        //==============================================================
        8'd51: data = {8'h17, hstart_reg};   // HSTART, see hstart_sel above
        8'd52: data = {8'h18, hstop_reg};    // HSTOP
        8'd53: data = {8'h32, href_reg};     // HREF (low bits of both, plus edge offset)
        8'd54: data = 16'h19_03;  // VSTRT
        8'd55: data = 16'h1A_7B;  // VSTOP
        8'd56: data = 16'h03_00;  // VREF (original working value)

        //==============================================================
        // SCALING — DISABLED
        // Camera outputs full VGA (640x480), FPGA downsamples to
        // 320x240 via even_pixel / even_line in capture logic.
        //==============================================================
        8'd57: data = 16'h0C_00;  // COM3: Scaling DISABLED
        8'd58: data = 16'h3E_00;  // COM14: Normal PCLK
        // Test pattern select is (SCALING_YSC[7], SCALING_XSC[7]):
        //   00 none, 01 shifting "1", 10 eight-bar colour bar, 11 fade to gray
        8'd59: data = 16'h70_3A;                            // SCALING_XSC[7] = 0
        8'd60: data = color_bar ? 16'h71_B5 : 16'h71_35;    // SCALING_YSC[7] = colour bar
        8'd61: data = 16'h72_11;  // SCALING_DCWCTR (no effect when COM3[3:2]=0)
        8'd62: data = 16'h73_F0;  // SCALING_PCLK_DIV
        8'd63: data = 16'hA2_02;  // SCALING_PCLK_DELAY

        //==============================================================
        // CRITICAL "MAGIC" / RESERVED REGISTERS
        // (Required for correct color — documented in multiple projects)
        //==============================================================
        8'd64: data = 16'hB0_84;  // RSVD: "required for good color"
        8'd65: data = 16'hB1_0C;  // ABLC1
        8'd66: data = 16'hB2_0E;  // RSVD
        8'd67: data = 16'hB3_80;  // THL_ST: ABLC target

        //==============================================================
        // MISC CONFIGURATION
        //==============================================================
        8'd68: data = 16'h0F_43;  // COM6: Reset timings (default)
        8'd69: data = 16'h1E_07;  // MVFP: Mirror + VFlip (adjust per mounting)
        8'd70: data = 16'h33_0B;  // CHLF: Array current control
        8'd71: data = 16'h3C_78;  // COM12: No HREF when VSYNC low
        8'd72: data = 16'h69_00;  // GFIX: Fix gain control
        8'd73: data = 16'h74_00;  // REG74: Digital gain control
        8'd74: data = 16'h15_00;  // COM10: Normal PCLK, VSYNC, HREF

        //==============================================================
        // AWB CONTROL
        //==============================================================
        8'd75: data = 16'h43_0A;  // AWBC1
        8'd76: data = 16'h44_F0;  // AWBC2
        8'd77: data = 16'h45_34;  // AWBC3
        8'd78: data = 16'h46_58;  // AWBC4
        8'd79: data = 16'h47_28;  // AWBC5
        8'd80: data = 16'h48_3A;  // AWBC6
        8'd81: data = 16'h59_88;  // AWBC7
        8'd82: data = 16'h5A_88;  // AWBC8
        8'd83: data = 16'h5B_44;  // AWBC9
        8'd84: data = 16'h5C_67;  // AWBC10
        8'd85: data = 16'h5D_49;  // AWBC11
        8'd86: data = 16'h5E_0E;  // AWBC12
        8'd87: data = 16'h6C_0A;  // AWBCTR3
        8'd88: data = 16'h6D_55;  // AWBCTR2
        8'd89: data = 16'h6E_11;  // AWBCTR1
        8'd90: data = 16'h6F_9F;  // AWBCTR0: Advanced AWB, 4x gain

        //==============================================================
        // EDGE / DENOISE
        //==============================================================
        8'd91: data = 16'h41_18;  // COM16: Edge enhance + denoise enable
        8'd92: data = 16'h4E_20;  // Edge enhance factor
        8'd93: data = 16'h76_E1;  // DNSTH: Denoise threshold

        //==============================================================
        // SENTINEL — end of configuration
        //==============================================================
        default: data = SENTINEL;

        endcase
    end

endmodule
