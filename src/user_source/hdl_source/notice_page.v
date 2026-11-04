`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// 【启事】启事页：插在 video_delay 和 video_transition 之间，sel（video_transition 的 show_page）= 1 时
//   整屏换成 FPGA 自己画的启事页（不经过 SDRAM、不依赖 TF 卡），跟图片一样参与淡入淡出 / Wipe 转场：
//     顶部标题栏（按类别换颜色：寻人 橙红 / 寻物 蓝 / 招领 绿），左边标题“寻人启事”等（微软雅黑粗体 48 像素，page_rom），
//       右边“2/3”（第几条 / 共几条，宋体 16 像素放大 2 倍）
//     中间白色卡片：启事原文（serial_cmd 用字库画进启事页缓冲，每行 LINE_W 列，最多 4 行），放大 2 倍，按行数上下居中
//     底部一行提示（按类别不同：page.txt 的 F_PERSON / F_THING / F_FOUND）
//   【串口照片】这一条带照片（meta 最高位）：卡片放大，左边 360×320 照片框里直接用 rgb_in（顶层这时让 SDRAM 读照片缓冲，
//     照片已经按屏上位置写好），文字放右边，每行 112 列（7 个汉字），最多 6 行；不带照片的版面不变
//   【自动字号】meta 最高位 = 小字（serial_cmd 大字放不下时按小字排）：字不放大，16 像素，行距 28；
//     不带照片每行 576 列（36 字，最多 4 行），带照片每行 224 列（14 字，最多 10 行），文字区和大字时一样，上下居中
// 纯组合叠加，不增加视频延迟：启事页缓冲和 page_rom 读出都晚 1 拍，用下一个像素的坐标去读（和应急文字一样）。
// 时钟：video_clk；meta（{类别, 列数, 第几条, 共几条}）由 serial_cmd 同步好，只在那块缓冲没显示时才变。
// -----------------------------------------------------------------------------
module notice_page #(
    parameter integer H_ACTIVE = 640,
    parameter integer V_ACTIVE = 480,
    parameter integer LINE_W   = 288                // 和 serial_cmd 一致：每行列数（放大 2 倍后 576 像素）
)(
    input  wire        clk,                 // video_clk
    input  wire        rst_n,
    input  wire        vs,                  // 低有效
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire        sel,                 // 1 = 显示启事页
    input  wire [20:0] meta,                // {小字, 带照片, 类别 2 位（1 寻人 2 寻物 3 招领）, 列数 11 位, 第几条 3 位, 共几条 3 位}
    output wire [10:0] col,                 // 读启事页缓冲的列
    input  wire [15:0] bits,                // 读出的一列（bit0 = 最上面一行）
    output wire [23:0] rgb_out
);

// ---------------- 坐标 ----------------
reg de_d;
reg [9:0] x_cnt, line_y;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        de_d   <= 1'b0;
        x_cnt  <= 10'd0;
        line_y <= 10'd0;
    end else begin
        de_d  <= de;
        x_cnt <= de ? (x_cnt + 10'd1) : 10'd0;
        if (!vs)
            line_y <= 10'd0;
        else if (de_d && !de)
            line_y <= line_y + 10'd1;
    end
end
wire [9:0] px = de ? x_cnt : 10'd0;
wire [9:0] nx = px + 10'd1;                 // 读出晚 1 拍：按下一个像素读

wire        sm_txt = meta[20];             // 【自动字号】
wire        has_ph = meta[19];
wire [1:0]  ty   = meta[18:17];
wire [10:0] len  = meta[16:6];
wire [2:0]  idx  = meta[5:3];
wire [2:0]  tot  = meta[2:0];

// ---------------- 版面 ----------------
localparam integer BAR_H  = 96;                       // 标题栏
localparam integer TT_X   = 40,  TT_Y = 24;           // 标题（48 行）
localparam integer NO_X   = 552, NO_Y = 32;           // “2/3”：3 个字 × 8 列 × 2 = 48 像素宽，32 行
localparam integer CD_X0  = 16,  CD_X1 = 624, CD_Y0 = 112, CD_Y1 = 432;   // 白色卡片
localparam integer TX_X0  = (H_ACTIVE - 2 * LINE_W) / 2, TX_X1 = TX_X0 + 2 * LINE_W;
// 【串口照片】带照片的版面：卡片 8~632 × 104~440，照片 16~376 × 112~432，文字 388~612（112 列 × 2）
localparam integer PH_LW  = 112;
localparam integer PCD_X0 = 8,   PCD_X1 = 632, PCD_Y0 = 104, PCD_Y1 = 440;
localparam integer PH_X0  = 16,  PH_X1  = 376, PH_Y0  = 112, PH_Y1  = 432;
localparam integer PTX_X0 = 388, PTX_X1 = 388 + 2 * PH_LW;
localparam integer FT_Y   = 448;                      // 底部提示（16 行）

// 标题、数字、提示文字都在 page_rom
wire [15:0] rom_q;
wire [11:0] t_s0, d_s, f_s;
wire [8:0]  t_w;
wire [9:0]  f_w, f_x0;
reg  [11:0] rom_a;
page_rom u_rom (.clk(clk), .raddr(rom_a), .rdata(rom_q), .ty(ty), .t_s0(t_s0), .t_w(t_w),
                .d_s(d_s), .f_s(f_s), .f_w(f_w), .f_x0(f_x0));

// 标题：3 段，每段 16 行
wire       in_ty  = (line_y >= TT_Y) && (line_y < TT_Y + 48);
wire [9:0] ty_dy  = line_y - TT_Y;
wire [1:0] band   = ty_dy[5:4];
wire [9:0] tt_dx  = nx - TT_X;
wire       tt_in  = in_ty && (nx >= TT_X) && (tt_dx < {1'b0, t_w});
// “第几条 / 共几条”：放大 2 倍
wire       in_no  = (line_y >= NO_Y) && (line_y < NO_Y + 32);
wire [9:0] no_dy  = line_y - NO_Y;
wire [9:0] no_dx  = nx - NO_X;
wire       no_in  = in_no && (nx >= NO_X) && (no_dx < 10'd48) && (tot != 3'd0);
wire [1:0] no_c   = no_dx[5:4];                       // 第几个字：0 = 第几条，1 = “/”，2 = 共几条
wire [3:0] no_code = (no_c == 2'd0) ? {1'b0, idx} : (no_c == 2'd1) ? 4'd10 : {1'b0, tot};
// 底部提示（每种启事一句，位置、宽度由 page_rom 按类别给出）
wire       in_ft  = (line_y >= FT_Y) && (line_y < FT_Y + 16);
wire [9:0] ft_dx  = nx - f_x0;
wire [9:0] ft_dy  = line_y - FT_Y;
wire       ft_in  = in_ft && (nx >= f_x0) && (ft_dx < f_w);

always @(*) begin
    if (no_in)
        rom_a = d_s + {4'd0, no_code, 3'd0} + {9'd0, no_dx[3:1]};
    else if (ft_in)
        rom_a = f_s + {2'b0, ft_dx};
    else
        rom_a = t_s0 + ((band == 2'd2) ? {2'b0, t_w, 1'b0} : (band == 2'd1) ? {3'b0, t_w} : 12'd0) + {2'b0, tt_dx};
end
// 读出那一拍：哪一块、取第几位
reg        r_tt, r_no, r_ft;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin r_tt <= 1'b0; r_no <= 1'b0; r_ft <= 1'b0; end
    else        begin r_tt <= tt_in && !no_in; r_no <= no_in; r_ft <= ft_in; end
end
wire rom_px = de && ((r_tt && rom_q[ty_dy[3:0]]) || (r_no && rom_q[no_dy[4:1]]) || (r_ft && rom_q[ft_dy[3:0]]));

// ---------------- 正文：nl 行，每行 48 行高（字 32 行 + 间距 16），在卡片里上下居中 ----------------
// 第 k 行从第 k × 行宽 列开始（行宽 288；【串口照片】带照片 112，最多 6 行）
wire [10:0] m1 = has_ph ? PH_LW     : LINE_W;
wire [10:0] m2 = has_ph ? 2 * PH_LW : 2 * LINE_W;
wire [10:0] m3 = has_ph ? 3 * PH_LW : 3 * LINE_W;
wire [10:0] m4 = has_ph ? 4 * PH_LW : 11'd2047;          // 不带照片最多 4 行
wire [10:0] m5 = has_ph ? 5 * PH_LW : 11'd2047;
wire       has_txt = (len != 11'd0);
wire [2:0] nl      = (len > m5) ? 3'd6 : (len > m4) ? 3'd5 : (len > m3) ? 3'd4 : (len > m2) ? 3'd3 : (len > m1) ? 3'd2 : 3'd1;
wire [9:0] t_y     = 10'd280 - {3'd0, nl, 4'd0} - {4'd0, nl, 3'd0};      // 272 - (nl*48-16)/2
wire [9:0] t_dy    = line_y - t_y;
wire [2:0] t_ln    = (t_dy >= 10'd240) ? 3'd5 : (t_dy >= 10'd192) ? 3'd4 : (t_dy >= 10'd144) ? 3'd3 :
                     (t_dy >= 10'd96)  ? 3'd2 : (t_dy >= 10'd48)  ? 3'd1 : 3'd0;
wire [9:0] t_r     = t_dy - ((t_ln == 3'd5) ? 10'd240 : (t_ln == 3'd4) ? 10'd192 : (t_ln == 3'd3) ? 10'd144 :
                             (t_ln == 3'd2) ? 10'd96  : (t_ln == 3'd1) ? 10'd48  : 10'd0);
wire       in_trow = has_txt && (line_y >= t_y) && (t_dy < {2'd0, nl, 5'd0} + {3'd0, nl, 4'd0}) && (t_r < 10'd32);
wire [10:0] k_off  = (t_ln == 3'd5) ? m5 : (t_ln == 3'd4) ? m4 : (t_ln == 3'd3) ? m3 : (t_ln == 3'd2) ? m2 : (t_ln == 3'd1) ? m1 : 11'd0;
wire [9:0] tx0     = has_ph ? PTX_X0 : TX_X0;
wire [9:0] tx1     = has_ph ? PTX_X1 : TX_X1;
wire [9:0] n_dx    = nx - tx0;
wire       n_in    = (nx >= tx0) && (nx < tx1);
// 【自动字号】小字：nl_s 行，行距 28（字 16 + 间距 12），在卡片里上下居中；行号 / 行内第几行 / 这一行从第几列开始
//   不用除法：每行扫描结束时递推（进入文字区时清零，每 28 行换下一行，起始列加一行的列数）
wire [10:0] s_lw   = has_ph ? 11'd224 : 11'd576;
wire [3:0]  nl_s   = has_ph ? ((len > 11'd2016) ? 4'd10 : (len > 11'd1792) ? 4'd9 : (len > 11'd1568) ? 4'd8 : (len > 11'd1344) ? 4'd7 :
                              (len > 11'd1120) ? 4'd6  : (len > 11'd896)  ? 4'd5 : (len > 11'd672)  ? 4'd4 : (len > 11'd448)  ? 4'd3 :
                              (len > 11'd224)  ? 4'd2  : 4'd1) :
                             ((len > 11'd1728) ? 4'd4 : (len > 11'd1152) ? 4'd3 : (len > 11'd576) ? 4'd2 : 4'd1);
wire [9:0]  s_y0   = 10'd278 - {2'd0, nl_s, 4'd0} + {5'd0, nl_s, 1'b0};    // 272 - (nl*28-12)/2 = 278 - nl*14
reg         s_act;                                   // 已经到文字区
reg  [3:0]  s_ln;
reg  [4:0]  s_r;
reg  [11:0] s_off;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s_act <= 1'b0; s_ln <= 4'd0; s_r <= 5'd0; s_off <= 12'd0;
    end else if (!vs) begin
        s_act <= 1'b0; s_ln <= 4'd0; s_r <= 5'd0; s_off <= 12'd0;
    end else if (de_d && !de) begin                  // 这一行扫完：算下一行（line_y + 1）
        if (line_y + 10'd1 == s_y0) begin
            s_act <= 1'b1; s_ln <= 4'd0; s_r <= 5'd0; s_off <= 12'd0;
        end else if (s_act) begin
            if (s_r == 5'd27) begin s_r <= 5'd0; s_ln <= s_ln + 4'd1; s_off <= s_off + {1'b0, s_lw}; end
            else                  s_r <= s_r + 5'd1;
        end
    end
end
wire        in_srow = has_txt && s_act && (s_ln < nl_s) && (s_r < 5'd16);
wire [11:0] s_col   = s_off + {2'b0, n_dx};
assign col = sm_txt ? s_col[10:0] : (k_off + {2'b0, n_dx[9:1]});
reg        t_vis;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) t_vis <= 1'b0;
    else        t_vis <= sel && n_in && (sm_txt ? (in_srow && (s_col < {1'b0, len})) : (in_trow && (col < len)));
end
wire [3:0] t_bit = sm_txt ? s_r[3:0] : t_r[4:1];
wire       t_px = de && t_vis && bits[t_bit];

// ---------------- 颜色 ----------------
reg [23:0] c_main, c_dark;
always @(*) begin
    case (ty)
        2'd1:    begin c_main = 24'hD9480F; c_dark = 24'h9C330A; end   // 寻人 橙红
        2'd2:    begin c_main = 24'h1C6FC4; c_dark = 24'h124C88; end   // 寻物 蓝
        default: begin c_main = 24'h2B8A3E; c_dark = 24'h1D5F2A; end   // 招领 绿
    endcase
end
wire in_bar   = (line_y < BAR_H);
wire bar_edge = (line_y >= BAR_H - 4);
wire [9:0] cx0 = has_ph ? PCD_X0 : CD_X0;
wire [9:0] cx1 = has_ph ? PCD_X1 : CD_X1;
wire [9:0] cy0 = has_ph ? PCD_Y0 : CD_Y0;
wire [9:0] cy1 = has_ph ? PCD_Y1 : CD_Y1;
wire in_card  = (line_y >= cy0) && (line_y < cy1) && (px >= cx0) && (px < cx1);
wire card_bd  = (line_y < cy0 + 10'd2) || (line_y >= cy1 - 10'd2) || (px < cx0 + 10'd2) || (px >= cx1 - 10'd2);
wire in_photo = has_ph && (line_y >= PH_Y0) && (line_y < PH_Y1) && (px >= PH_X0) && (px < PH_X1);   // 【串口照片】

wire [23:0] page = in_bar  ? (rom_px ? 24'hFFFFFF : bar_edge ? c_dark : c_main) :
                   in_photo ? rgb_in :
                   in_card ? (t_px ? 24'h1A1A1A : card_bd ? c_main : 24'hFFFFFF) :
                   (rom_px ? 24'h505050 : 24'hF3EFE6);

assign rgb_out = (sel && de) ? page : rgb_in;

endmodule
