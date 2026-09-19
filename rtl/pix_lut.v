`timescale 1ns / 1ps

//==========================================================================
// Module: pix_lut
// Description: 8-bit display code -> 12-bit linear light. GENERATED
//              by bench/gen_tables.py - edit that, not this.
//
//   The images this design consumes are sRGB encoded, so that a monitor
//   showing them emits light proportional to the scene rather than to a
//   gamma-warped version of it. A centroid is a first moment of light, so
//   the pipeline has to undo the encoding before it weights anything. A
//   camera pointed at the screen does this in the optics; when the image
//   is fed to the FPGA digitally, this table stands in for the monitor.
//
//   Twelve bits out, not eight: the sky background sits near code 35,
//   which is 1.7% of full scale. Rounded to eight bits the entire faint
//   end of the scene would land inside four values.
//
//   The table is strictly increasing, which is what lets the detector
//   keep its line buffers in linear values and still threshold in code
//   space: it simply passes the threshold through the same table.
//
//   Inferred as distributed ROM - 256 x 12 bits is 48 LUTs, against the
//   several hundred a case statement would build.
//==========================================================================

module pix_lut (
    input  wire [7:0]  code,
    output wire [11:0] lin
);

    (* rom_style = "distributed" *) reg [11:0] tbl [0:255];

    initial begin
        tbl[  0] = 12'd   0; tbl[  1] = 12'd   1; tbl[  2] = 12'd   2; tbl[  3] = 12'd   4; tbl[  4] = 12'd   5; tbl[  5] = 12'd   6; tbl[  6] = 12'd   7; tbl[  7] = 12'd   9;
        tbl[  8] = 12'd  10; tbl[  9] = 12'd  11; tbl[ 10] = 12'd  12; tbl[ 11] = 12'd  14; tbl[ 12] = 12'd  15; tbl[ 13] = 12'd  16; tbl[ 14] = 12'd  18; tbl[ 15] = 12'd  20;
        tbl[ 16] = 12'd  21; tbl[ 17] = 12'd  23; tbl[ 18] = 12'd  25; tbl[ 19] = 12'd  27; tbl[ 20] = 12'd  29; tbl[ 21] = 12'd  31; tbl[ 22] = 12'd  33; tbl[ 23] = 12'd  35;
        tbl[ 24] = 12'd  37; tbl[ 25] = 12'd  40; tbl[ 26] = 12'd  42; tbl[ 27] = 12'd  45; tbl[ 28] = 12'd  48; tbl[ 29] = 12'd  50; tbl[ 30] = 12'd  53; tbl[ 31] = 12'd  56;
        tbl[ 32] = 12'd  59; tbl[ 33] = 12'd  62; tbl[ 34] = 12'd  66; tbl[ 35] = 12'd  69; tbl[ 36] = 12'd  72; tbl[ 37] = 12'd  76; tbl[ 38] = 12'd  79; tbl[ 39] = 12'd  83;
        tbl[ 40] = 12'd  87; tbl[ 41] = 12'd  91; tbl[ 42] = 12'd  95; tbl[ 43] = 12'd  99; tbl[ 44] = 12'd 103; tbl[ 45] = 12'd 107; tbl[ 46] = 12'd 112; tbl[ 47] = 12'd 116;
        tbl[ 48] = 12'd 121; tbl[ 49] = 12'd 126; tbl[ 50] = 12'd 131; tbl[ 51] = 12'd 136; tbl[ 52] = 12'd 141; tbl[ 53] = 12'd 146; tbl[ 54] = 12'd 151; tbl[ 55] = 12'd 156;
        tbl[ 56] = 12'd 162; tbl[ 57] = 12'd 168; tbl[ 58] = 12'd 173; tbl[ 59] = 12'd 179; tbl[ 60] = 12'd 185; tbl[ 61] = 12'd 191; tbl[ 62] = 12'd 197; tbl[ 63] = 12'd 204;
        tbl[ 64] = 12'd 210; tbl[ 65] = 12'd 216; tbl[ 66] = 12'd 223; tbl[ 67] = 12'd 230; tbl[ 68] = 12'd 237; tbl[ 69] = 12'd 244; tbl[ 70] = 12'd 251; tbl[ 71] = 12'd 258;
        tbl[ 72] = 12'd 265; tbl[ 73] = 12'd 273; tbl[ 74] = 12'd 280; tbl[ 75] = 12'd 288; tbl[ 76] = 12'd 296; tbl[ 77] = 12'd 304; tbl[ 78] = 12'd 312; tbl[ 79] = 12'd 320;
        tbl[ 80] = 12'd 329; tbl[ 81] = 12'd 337; tbl[ 82] = 12'd 346; tbl[ 83] = 12'd 354; tbl[ 84] = 12'd 363; tbl[ 85] = 12'd 372; tbl[ 86] = 12'd 381; tbl[ 87] = 12'd 390;
        tbl[ 88] = 12'd 400; tbl[ 89] = 12'd 409; tbl[ 90] = 12'd 419; tbl[ 91] = 12'd 428; tbl[ 92] = 12'd 438; tbl[ 93] = 12'd 448; tbl[ 94] = 12'd 458; tbl[ 95] = 12'd 469;
        tbl[ 96] = 12'd 479; tbl[ 97] = 12'd 490; tbl[ 98] = 12'd 500; tbl[ 99] = 12'd 511; tbl[100] = 12'd 522; tbl[101] = 12'd 533; tbl[102] = 12'd 544; tbl[103] = 12'd 555;
        tbl[104] = 12'd 567; tbl[105] = 12'd 578; tbl[106] = 12'd 590; tbl[107] = 12'd 602; tbl[108] = 12'd 614; tbl[109] = 12'd 626; tbl[110] = 12'd 639; tbl[111] = 12'd 651;
        tbl[112] = 12'd 664; tbl[113] = 12'd 676; tbl[114] = 12'd 689; tbl[115] = 12'd 702; tbl[116] = 12'd 715; tbl[117] = 12'd 728; tbl[118] = 12'd 742; tbl[119] = 12'd 755;
        tbl[120] = 12'd 769; tbl[121] = 12'd 783; tbl[122] = 12'd 797; tbl[123] = 12'd 811; tbl[124] = 12'd 825; tbl[125] = 12'd 840; tbl[126] = 12'd 854; tbl[127] = 12'd 869;
        tbl[128] = 12'd 884; tbl[129] = 12'd 899; tbl[130] = 12'd 914; tbl[131] = 12'd 929; tbl[132] = 12'd 945; tbl[133] = 12'd 960; tbl[134] = 12'd 976; tbl[135] = 12'd 992;
        tbl[136] = 12'd1008; tbl[137] = 12'd1024; tbl[138] = 12'd1041; tbl[139] = 12'd1057; tbl[140] = 12'd1074; tbl[141] = 12'd1091; tbl[142] = 12'd1108; tbl[143] = 12'd1125;
        tbl[144] = 12'd1142; tbl[145] = 12'd1159; tbl[146] = 12'd1177; tbl[147] = 12'd1195; tbl[148] = 12'd1213; tbl[149] = 12'd1231; tbl[150] = 12'd1249; tbl[151] = 12'd1267;
        tbl[152] = 12'd1286; tbl[153] = 12'd1304; tbl[154] = 12'd1323; tbl[155] = 12'd1342; tbl[156] = 12'd1361; tbl[157] = 12'd1381; tbl[158] = 12'd1400; tbl[159] = 12'd1420;
        tbl[160] = 12'd1440; tbl[161] = 12'd1459; tbl[162] = 12'd1480; tbl[163] = 12'd1500; tbl[164] = 12'd1520; tbl[165] = 12'd1541; tbl[166] = 12'd1562; tbl[167] = 12'd1582;
        tbl[168] = 12'd1603; tbl[169] = 12'd1625; tbl[170] = 12'd1646; tbl[171] = 12'd1668; tbl[172] = 12'd1689; tbl[173] = 12'd1711; tbl[174] = 12'd1733; tbl[175] = 12'd1755;
        tbl[176] = 12'd1778; tbl[177] = 12'd1800; tbl[178] = 12'd1823; tbl[179] = 12'd1846; tbl[180] = 12'd1869; tbl[181] = 12'd1892; tbl[182] = 12'd1916; tbl[183] = 12'd1939;
        tbl[184] = 12'd1963; tbl[185] = 12'd1987; tbl[186] = 12'd2011; tbl[187] = 12'd2035; tbl[188] = 12'd2059; tbl[189] = 12'd2084; tbl[190] = 12'd2109; tbl[191] = 12'd2133;
        tbl[192] = 12'd2159; tbl[193] = 12'd2184; tbl[194] = 12'd2209; tbl[195] = 12'd2235; tbl[196] = 12'd2260; tbl[197] = 12'd2286; tbl[198] = 12'd2312; tbl[199] = 12'd2339;
        tbl[200] = 12'd2365; tbl[201] = 12'd2392; tbl[202] = 12'd2419; tbl[203] = 12'd2446; tbl[204] = 12'd2473; tbl[205] = 12'd2500; tbl[206] = 12'd2527; tbl[207] = 12'd2555;
        tbl[208] = 12'd2583; tbl[209] = 12'd2611; tbl[210] = 12'd2639; tbl[211] = 12'd2668; tbl[212] = 12'd2696; tbl[213] = 12'd2725; tbl[214] = 12'd2754; tbl[215] = 12'd2783;
        tbl[216] = 12'd2812; tbl[217] = 12'd2841; tbl[218] = 12'd2871; tbl[219] = 12'd2901; tbl[220] = 12'd2931; tbl[221] = 12'd2961; tbl[222] = 12'd2991; tbl[223] = 12'd3022;
        tbl[224] = 12'd3052; tbl[225] = 12'd3083; tbl[226] = 12'd3114; tbl[227] = 12'd3146; tbl[228] = 12'd3177; tbl[229] = 12'd3209; tbl[230] = 12'd3240; tbl[231] = 12'd3272;
        tbl[232] = 12'd3304; tbl[233] = 12'd3337; tbl[234] = 12'd3369; tbl[235] = 12'd3402; tbl[236] = 12'd3435; tbl[237] = 12'd3468; tbl[238] = 12'd3501; tbl[239] = 12'd3535;
        tbl[240] = 12'd3568; tbl[241] = 12'd3602; tbl[242] = 12'd3636; tbl[243] = 12'd3670; tbl[244] = 12'd3705; tbl[245] = 12'd3739; tbl[246] = 12'd3774; tbl[247] = 12'd3809;
        tbl[248] = 12'd3844; tbl[249] = 12'd3879; tbl[250] = 12'd3915; tbl[251] = 12'd3950; tbl[252] = 12'd3986; tbl[253] = 12'd4022; tbl[254] = 12'd4059; tbl[255] = 12'd4095;
    end

    assign lin = tbl[code];

endmodule
