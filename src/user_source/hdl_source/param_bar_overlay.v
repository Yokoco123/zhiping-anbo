`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// 参数条：屏幕上方一行（中文）  亮度 100  对比度 100  音量 80  轮播 3秒
//   SW2 打开参数菜单时显示，当前选中的那一项黄底黑字（Key1/Key2 左右移动）
//   不受字幕开关影响，否则调参数时看不到数值
// 字形：黑体 16 像素（汉字 16 宽、数字 8 宽），存在一块 BRAM（pbrom，初值由 subtitle/gen_pbar.ps1 生成，在本文件末尾），
//   地址 {字号 5 位, 行 4 位}，每行 16 位，bit15 = 最左边；数字只用左边 8 位
// 版面：每 8 个像素一格，共 41 格（328 像素），每格是“哪个字的左半 / 右半”，由 slot_glyph 查表；
// 格子计数器比当前像素超前 1 个像素（BRAM 读出晚 1 拍），当前像素用的是打一拍后的副本。
// 纯组合叠加，不增加视频延迟；像素通路里没有除法。
// -----------------------------------------------------------------------------
module param_bar_overlay #(
    parameter integer BAR_X = 156,          // 第一个字左边（(640 - 328) / 2）
    parameter integer BAR_Y = 8             // 字的第一行
)(
    input  wire        clk,                 // video_clk，以下输入都已在本时钟域
    input  wire        rst_n,
    input  wire        vs,                  // 低有效
    input  wire        de,
    input  wire [9:0]  pixel_x,
    input  wire [23:0] rgb_in,
    input  wire        show,                // 菜单打开
    input  wire [1:0]  sel,                 // 选中项 0 亮度 1 对比度 2 音量 3 轮播周期
    input  wire [7:0]  bri_pct,
    input  wire [7:0]  con_pct,
    input  wire [7:0]  vol_pct,
    input  wire [2:0]  period_idx,          // 0~5 = 1/3/5/10/30/60 秒
    output wire [23:0] rgb_out
);

localparam integer SLOTS = 41;
localparam integer BAR_W = SLOTS * 8;

// ---------------- 帧头、行号 ----------------
reg vs_d, de_d;
reg [9:0] line_y;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        vs_d   <= 1'b1;
        de_d   <= 1'b0;
        line_y <= 10'd0;
    end else begin
        vs_d <= vs;
        de_d <= de;
        if (!vs)
            line_y <= 10'd0;
        else if (de_d && !de)
            line_y <= line_y + 10'd1;
    end
end
wire frame_start = vs_d & ~vs;

// ---------------- 帧头锁存参数，算好十进制各位 ----------------
reg [7:0] bri_f, con_f, vol_f;
reg [2:0] per_f;
reg       show_f;
reg [1:0] hl_f;                             // 高亮哪一项

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bri_f  <= 8'd100;
        con_f  <= 8'd100;
        vol_f  <= 8'd80;
        per_f  <= 3'd1;
        show_f <= 1'b0;
        hl_f   <= 2'd0;
    end else if (frame_start) begin
        bri_f  <= bri_pct;
        con_f  <= con_pct;
        vol_f  <= vol_pct;
        per_f  <= period_idx;
        show_f <= show;
        hl_f   <= sel;
    end
end

// 每项的百、十、个位（0~150），寄存后给像素通路用
reg [3:0] bh, bt, bo, ch, ct, co, vh, vt, vo;
always @(posedge clk) begin
    bh <= bri_f / 100;  bt <= (bri_f % 100) / 10;  bo <= bri_f % 10;
    ch <= con_f / 100;  ct <= (con_f % 100) / 10;  co <= con_f % 10;
    vh <= vol_f / 100;  vt <= (vol_f % 100) / 10;  vo <= vol_f % 10;
end

// ---------------- 字号：0~9 数字，其余汉字 ----------------
localparam [4:0] G_LIANG = 5'd10, G_DU = 5'd11, G_DUI = 5'd12, G_BI = 5'd13, G_YIN = 5'd14,
                 G_LANG = 5'd15, G_LUN = 5'd16, G_BO = 5'd17, G_MIAO = 5'd18, G_SP = 5'd31;

// 百位 / 十位不显示前导 0
function [4:0] d_h; input [3:0] h; begin d_h = (h != 4'd0) ? {1'b0, h} : G_SP; end endfunction
function [4:0] d_t; input [3:0] h; input [3:0] t; begin d_t = ((h != 4'd0) || (t != 4'd0)) ? {1'b0, t} : G_SP; end endfunction

// 第 c 格：{右半, 字号}
//   0~9   亮度 _ 百十个 __      10~21 对比度 _ 百十个 __      22~31 音量 _ 百十个 __      32~40 轮播 _ 十个 秒
function [5:0] slot_glyph;
    input [5:0] c;
    begin
        case (c)
            6'd0:  slot_glyph = {1'b0, G_LIANG};  6'd1:  slot_glyph = {1'b1, G_LIANG};
            6'd2:  slot_glyph = {1'b0, G_DU};     6'd3:  slot_glyph = {1'b1, G_DU};
            6'd5:  slot_glyph = {1'b0, d_h(bh)};
            6'd6:  slot_glyph = {1'b0, d_t(bh, bt)};
            6'd7:  slot_glyph = {1'b0, 1'b0, bo};
            6'd10: slot_glyph = {1'b0, G_DUI};    6'd11: slot_glyph = {1'b1, G_DUI};
            6'd12: slot_glyph = {1'b0, G_BI};     6'd13: slot_glyph = {1'b1, G_BI};
            6'd14: slot_glyph = {1'b0, G_DU};     6'd15: slot_glyph = {1'b1, G_DU};
            6'd17: slot_glyph = {1'b0, d_h(ch)};
            6'd18: slot_glyph = {1'b0, d_t(ch, ct)};
            6'd19: slot_glyph = {1'b0, 1'b0, co};
            6'd22: slot_glyph = {1'b0, G_YIN};    6'd23: slot_glyph = {1'b1, G_YIN};
            6'd24: slot_glyph = {1'b0, G_LANG};   6'd25: slot_glyph = {1'b1, G_LANG};
            6'd27: slot_glyph = {1'b0, d_h(vh)};
            6'd28: slot_glyph = {1'b0, d_t(vh, vt)};
            6'd29: slot_glyph = {1'b0, 1'b0, vo};
            6'd32: slot_glyph = {1'b0, G_LUN};    6'd33: slot_glyph = {1'b1, G_LUN};
            6'd34: slot_glyph = {1'b0, G_BO};     6'd35: slot_glyph = {1'b1, G_BO};
            6'd37: case (per_f)                   // 十位：10 / 30 / 60
                       3'd3:    slot_glyph = {1'b0, 5'd1};
                       3'd4:    slot_glyph = {1'b0, 5'd3};
                       3'd5:    slot_glyph = {1'b0, 5'd6};
                       default: slot_glyph = {1'b0, G_SP};
                   endcase
            6'd38: case (per_f)                   // 个位
                       3'd0:    slot_glyph = {1'b0, 5'd1};
                       3'd1:    slot_glyph = {1'b0, 5'd3};
                       3'd2:    slot_glyph = {1'b0, 5'd5};
                       default: slot_glyph = {1'b0, 5'd0};
                   endcase
            6'd39: slot_glyph = {1'b0, G_MIAO};   6'd40: slot_glyph = {1'b1, G_MIAO};
            default: slot_glyph = {1'b0, G_SP};
        endcase
    end
endfunction

// ---------------- 格子计数（超前 1 个像素）→ 读 BRAM ----------------
reg [2:0] xa;                               // 格内像素 0~7
reg [5:0] ca;                               // 第几格
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        xa <= 3'd0;
        ca <= 6'd0;
    end else if (!de) begin
        xa <= 3'd0;
        ca <= 6'd0;
    end else if (pixel_x >= BAR_X - 1) begin
        xa <= xa + 3'd1;
        if (xa == 3'd7) ca <= ca + 6'd1;
    end
end
wire [9:0] ty   = line_y - BAR_Y;
wire [5:0] sg_a = slot_glyph(ca);
reg  [15:0] pbrom [0:511] /* fehdl force_ram=1, ram_style="bram_32k" */;   // 字形（只读）
reg  [15:0] pb_q;
reg  [2:0]  xq;                             // 当前像素的格内位置
reg  [5:0]  cq;                             // 当前像素是第几格
reg         hq;                             // 当前像素在字的右半
reg         inq;                            // 当前像素在字符区里
always @(posedge clk)
    pb_q <= pbrom[{sg_a[4:0], ty[3:0]}];
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        xq <= 3'd0; cq <= 6'd0; hq <= 1'b0; inq <= 1'b0;
    end else begin
        xq  <= xa;
        cq  <= ca;
        hq  <= sg_a[5];
        inq <= de && (pixel_x >= BAR_X - 1) && (ca < SLOTS);
    end
end

// ---------------- 像素判断 ----------------
wire       in_band = show_f && de &&
                     (pixel_x >= BAR_X - 8) && (pixel_x < BAR_X + BAR_W + 8) &&
                     (line_y >= BAR_Y - 4)  && (line_y < BAR_Y + 20);
wire       text    = in_band && inq && (line_y >= BAR_Y) && (ty < 10'd16) && pb_q[{~hq, ~xq}];
// 选中项的黄框：这一项的格子，左右各多 4 个像素
wire [5:0] f_s = (hl_f == 2'd0) ? 6'd0 : (hl_f == 2'd1) ? 6'd10 : (hl_f == 2'd2) ? 6'd22 : 6'd32;
wire [5:0] f_e = (hl_f == 2'd0) ? 6'd7 : (hl_f == 2'd1) ? 6'd19 : (hl_f == 2'd2) ? 6'd29 : 6'd40;
wire       box_x = inq ? (((cq >= f_s) && (cq <= f_e)) || ((cq == f_e + 6'd1) && !xq[2]) || ((cq + 6'd1 == f_s) && xq[2]))
                       : ((hl_f == 2'd0) && (pixel_x >= BAR_X - 4) && (pixel_x < BAR_X));
wire       in_box  = in_band && box_x && (line_y >= BAR_Y - 3) && (line_y < BAR_Y + 19);

// 底条把画面压暗到 1/4，选中项黄底黑字，其余白字
wire [23:0] dark = {2'b00, rgb_in[23:18], 2'b00, rgb_in[15:10], 2'b00, rgb_in[7:2]};
assign rgb_out = !in_band ? rgb_in :
                 in_box   ? (text ? 24'h000000 : 24'hFFD000) :
                 text     ? 24'hF0F0F0 :
                            dark;

// ---------------- 字形（subtitle/gen_pbar.ps1 生成，不要手改） ----------------
// BEGIN PBAR
// generated 2026-11-03 14:45:49 from: 0123456789 亮度对比音量轮播秒
integer pi;
initial begin
    for (pi = 0; pi < 512; pi = pi + 1) pbrom[pi] = 16'h0000;
    pbrom[3] = 16'h3C00;
    pbrom[4] = 16'h6400;
    pbrom[5] = 16'h4200;
    pbrom[6] = 16'h4200;
    pbrom[7] = 16'h4200;
    pbrom[8] = 16'h4200;
    pbrom[9] = 16'h4200;
    pbrom[10] = 16'h4200;
    pbrom[11] = 16'h4600;
    pbrom[12] = 16'h2C00;
    pbrom[13] = 16'h1800;
    pbrom[19] = 16'h0400;
    pbrom[20] = 16'h0C00;
    pbrom[21] = 16'h3C00;
    pbrom[22] = 16'h2C00;
    pbrom[23] = 16'h0C00;
    pbrom[24] = 16'h0C00;
    pbrom[25] = 16'h0C00;
    pbrom[26] = 16'h0C00;
    pbrom[27] = 16'h0C00;
    pbrom[28] = 16'h0C00;
    pbrom[29] = 16'h0C00;
    pbrom[35] = 16'h3C00;
    pbrom[36] = 16'h6600;
    pbrom[37] = 16'h4200;
    pbrom[38] = 16'h0600;
    pbrom[39] = 16'h0400;
    pbrom[40] = 16'h0C00;
    pbrom[41] = 16'h0800;
    pbrom[42] = 16'h1000;
    pbrom[43] = 16'h2000;
    pbrom[44] = 16'h7E00;
    pbrom[45] = 16'h7E00;
    pbrom[51] = 16'h3C00;
    pbrom[52] = 16'h6600;
    pbrom[53] = 16'h4200;
    pbrom[54] = 16'h0600;
    pbrom[55] = 16'h0C00;
    pbrom[56] = 16'h0C00;
    pbrom[57] = 16'h0600;
    pbrom[58] = 16'h0200;
    pbrom[59] = 16'h4200;
    pbrom[60] = 16'h6400;
    pbrom[61] = 16'h1800;
    pbrom[67] = 16'h0400;
    pbrom[68] = 16'h0C00;
    pbrom[69] = 16'h1C00;
    pbrom[70] = 16'h1400;
    pbrom[71] = 16'h2400;
    pbrom[72] = 16'h6400;
    pbrom[73] = 16'h4400;
    pbrom[74] = 16'hFF00;
    pbrom[75] = 16'h0400;
    pbrom[76] = 16'h0400;
    pbrom[77] = 16'h0400;
    pbrom[83] = 16'h3E00;
    pbrom[84] = 16'h6000;
    pbrom[85] = 16'h4000;
    pbrom[86] = 16'h5000;
    pbrom[87] = 16'h7C00;
    pbrom[88] = 16'h4600;
    pbrom[89] = 16'h0200;
    pbrom[90] = 16'h0200;
    pbrom[91] = 16'hC600;
    pbrom[92] = 16'h6C00;
    pbrom[93] = 16'h3800;
    pbrom[99] = 16'h1000;
    pbrom[100] = 16'h3000;
    pbrom[101] = 16'h2000;
    pbrom[102] = 16'h6000;
    pbrom[103] = 16'hF800;
    pbrom[104] = 16'hC400;
    pbrom[105] = 16'h8600;
    pbrom[106] = 16'h8600;
    pbrom[107] = 16'h8400;
    pbrom[108] = 16'hCC00;
    pbrom[109] = 16'h7800;
    pbrom[115] = 16'h7E00;
    pbrom[116] = 16'h0200;
    pbrom[117] = 16'h0600;
    pbrom[118] = 16'h0400;
    pbrom[119] = 16'h0C00;
    pbrom[120] = 16'h0800;
    pbrom[121] = 16'h1800;
    pbrom[122] = 16'h1000;
    pbrom[123] = 16'h1000;
    pbrom[124] = 16'h3000;
    pbrom[125] = 16'h3000;
    pbrom[131] = 16'h3C00;
    pbrom[132] = 16'h4600;
    pbrom[133] = 16'h4200;
    pbrom[134] = 16'h4600;
    pbrom[135] = 16'h7C00;
    pbrom[136] = 16'h7C00;
    pbrom[137] = 16'h4200;
    pbrom[138] = 16'hC200;
    pbrom[139] = 16'h4200;
    pbrom[140] = 16'h6600;
    pbrom[141] = 16'h3C00;
    pbrom[147] = 16'h3C00;
    pbrom[148] = 16'h4600;
    pbrom[149] = 16'hC200;
    pbrom[150] = 16'hC200;
    pbrom[151] = 16'hC600;
    pbrom[152] = 16'h6C00;
    pbrom[153] = 16'h3C00;
    pbrom[154] = 16'h0800;
    pbrom[155] = 16'h1800;
    pbrom[156] = 16'h1000;
    pbrom[157] = 16'h3000;
    pbrom[161] = 16'h0100;
    pbrom[162] = 16'h7FFE;
    pbrom[164] = 16'h0FF0;
    pbrom[165] = 16'h0810;
    pbrom[166] = 16'h0FF0;
    pbrom[168] = 16'h7FFE;
    pbrom[169] = 16'h7FFE;
    pbrom[170] = 16'h4002;
    pbrom[171] = 16'h07E0;
    pbrom[172] = 16'h0460;
    pbrom[173] = 16'h0C62;
    pbrom[174] = 16'h387E;
    pbrom[175] = 16'h2000;
    pbrom[177] = 16'h0080;
    pbrom[178] = 16'h0080;
    pbrom[179] = 16'h3FFC;
    pbrom[180] = 16'h2210;
    pbrom[181] = 16'h2210;
    pbrom[182] = 16'h2FFC;
    pbrom[183] = 16'h2210;
    pbrom[184] = 16'h23F0;
    pbrom[185] = 16'h2000;
    pbrom[186] = 16'h2FF8;
    pbrom[187] = 16'h2310;
    pbrom[188] = 16'h21A0;
    pbrom[189] = 16'h60C0;
    pbrom[190] = 16'h473E;
    pbrom[191] = 16'h0802;
    pbrom[193] = 16'h0008;
    pbrom[194] = 16'h0008;
    pbrom[195] = 16'h7E08;
    pbrom[196] = 16'h0208;
    pbrom[197] = 16'h03FE;
    pbrom[198] = 16'h2408;
    pbrom[199] = 16'h3488;
    pbrom[200] = 16'h1C88;
    pbrom[201] = 16'h0C48;
    pbrom[202] = 16'h0C48;
    pbrom[203] = 16'h1608;
    pbrom[204] = 16'h3208;
    pbrom[205] = 16'h6008;
    pbrom[206] = 16'h4038;
    pbrom[209] = 16'h0080;
    pbrom[210] = 16'h2080;
    pbrom[211] = 16'h2080;
    pbrom[212] = 16'h2084;
    pbrom[213] = 16'h209C;
    pbrom[214] = 16'h3EF0;
    pbrom[215] = 16'h20C0;
    pbrom[216] = 16'h2080;
    pbrom[217] = 16'h2080;
    pbrom[218] = 16'h2080;
    pbrom[219] = 16'h2280;
    pbrom[220] = 16'h2E86;
    pbrom[221] = 16'h78C6;
    pbrom[222] = 16'h207C;
    pbrom[225] = 16'h0100;
    pbrom[226] = 16'h0180;
    pbrom[227] = 16'h3FFC;
    pbrom[228] = 16'h0C30;
    pbrom[229] = 16'h0420;
    pbrom[230] = 16'h0460;
    pbrom[231] = 16'h7FFE;
    pbrom[233] = 16'h1FF8;
    pbrom[234] = 16'h1818;
    pbrom[235] = 16'h1FF8;
    pbrom[236] = 16'h1818;
    pbrom[237] = 16'h1818;
    pbrom[238] = 16'h1FF8;
    pbrom[239] = 16'h1818;
    pbrom[242] = 16'h1FF8;
    pbrom[243] = 16'h1FF8;
    pbrom[244] = 16'h1008;
    pbrom[245] = 16'h1FF8;
    pbrom[246] = 16'h7FFE;
    pbrom[248] = 16'h1FF8;
    pbrom[249] = 16'h1FF8;
    pbrom[250] = 16'h1188;
    pbrom[251] = 16'h1FF8;
    pbrom[252] = 16'h3FF8;
    pbrom[253] = 16'h0180;
    pbrom[254] = 16'h7FFE;
    pbrom[257] = 16'h1820;
    pbrom[258] = 16'h1060;
    pbrom[259] = 16'h7E50;
    pbrom[260] = 16'h10D8;
    pbrom[261] = 16'h218C;
    pbrom[262] = 16'h2F06;
    pbrom[263] = 16'h4880;
    pbrom[264] = 16'h7E8C;
    pbrom[265] = 16'h08B8;
    pbrom[266] = 16'h08E0;
    pbrom[267] = 16'h7E80;
    pbrom[268] = 16'h6884;
    pbrom[269] = 16'h0886;
    pbrom[270] = 16'h08FC;
    pbrom[271] = 16'h0800;
    pbrom[273] = 16'h100C;
    pbrom[274] = 16'h13FC;
    pbrom[275] = 16'h112C;
    pbrom[276] = 16'h7928;
    pbrom[277] = 16'h13FE;
    pbrom[278] = 16'h10B0;
    pbrom[279] = 16'h11A8;
    pbrom[280] = 16'h3B26;
    pbrom[281] = 16'h77FE;
    pbrom[282] = 16'h1324;
    pbrom[283] = 16'h13FC;
    pbrom[284] = 16'h1324;
    pbrom[285] = 16'h1324;
    pbrom[286] = 16'h73FC;
    pbrom[287] = 16'h0304;
    pbrom[289] = 16'h0020;
    pbrom[290] = 16'h1E20;
    pbrom[291] = 16'h2820;
    pbrom[292] = 16'h08EC;
    pbrom[293] = 16'h08A6;
    pbrom[294] = 16'h7EA2;
    pbrom[295] = 16'h19A0;
    pbrom[296] = 16'h1D24;
    pbrom[297] = 16'h3A24;
    pbrom[298] = 16'h2A0C;
    pbrom[299] = 16'h6818;
    pbrom[300] = 16'h4830;
    pbrom[301] = 16'h0860;
    pbrom[302] = 16'h0B80;
    pbrom[303] = 16'h0800;
end
// END PBAR

endmodule
