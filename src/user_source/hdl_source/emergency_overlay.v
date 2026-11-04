`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// 【应急模式】应急画面层：插在 video_transition 和 osd_layer 之间
//   emerg_on    ：应急接管（一级 / 二级，按键 / 干接点 / 串口），屏幕四周边框闪烁（约 1Hz）
//                 【应急时延实测】一打开就从“亮”开始闪：下一个有效像素就画出边框（最坏等一个场消隐 ≈ 1.5ms）
//   builtin_on  ：应急接管但没有可显示的 EMERG.BMP（没有 / 没读成功 / 没插卡），整屏换成 FPGA 自己画的警示页：
//                   黄黑警示条 + 警示三角 + 中文大标题（一级“紧急撤离”暗红底 / 二级“就地避险”橙色底、慢呼吸）+ 英文
//                   有应急文字时，标题上移，下面是文字面板（应急文字放大 2 倍）
//   一级有 EMERG.BMP（疏散图）：图片完全不挡，只有红色闪烁边框；二级“就地避险”不显示疏散图，始终用内置橙色页；
//                 应急文字在底部字幕条滚动（osd_layer / subtitle_strip，一级红底 / 二级橙底），按键进入和串口进入的画面一样
//   三级 区域警戒（不接管）：节目照常，整屏一圈不闪的琥珀色细边框 + 小标签“区域警戒”
//                 （节目图上在右上角，免得挡住图片自带的标题；启事页上在标题栏中间的空位，右上角是“第几条”）；
//                 文字同样在底部字幕条滚动，启事照常插播
//   中文标题（黑体 16×16，放大 4 倍 / 2 倍）和英文（5×7）的点阵存在一块 BRAM9K（erom，初值由 subtitle/gen_etitle.ps1 生成，在本文件末尾），
//   不依赖 TF 卡、SDRAM 和 Flash 字库——这些坏了，应急画面照样能发出去（可靠性兜底）
// 应急文字 RAM 只有一个读口：警示页文字面板那几行给面板（a_col 用自己算的列），其余行给字幕条（a_col = s_col）。
// 纯组合叠加，不增加视频延迟（RAM 读出晚 1 拍，用下一个像素的坐标去读）。格子位置用计数器 / 移位，像素通路里没有除法。
// -----------------------------------------------------------------------------
module emergency_overlay #(
    parameter integer H_ACTIVE = 640,
    parameter integer V_ACTIVE = 480,
    parameter integer BORDER   = 10,
    parameter integer LINE_W   = 288               // 和 serial_cmd 一致：应急文字每行列数
)(
    input  wire        clk,                 // video_clk
    input  wire        rst_n,
    input  wire        vs,                  // 低有效
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire        emerg_on,            // video_clk 域：一级 / 二级接管
    input  wire        builtin_on,          // video_clk 域：用内置警示页
    input  wire [1:0]  level,               // 实际等级 0 无 1 紧急撤离 2 就地避险 3 区域警戒
    input  wire [9:0]  a_len,               // 应急文字列数，0 = 没有文字
    output wire [9:0]  a_col,               // 读应急文字 RAM 的列
    input  wire [15:0] a_bits,              // 读出的一列（bit0 = 最上面一行）
    input  wire [9:0]  s_col,               // 底部字幕条要读的列（应急文字滚动）
    input  wire        page_on,             // video_clk 域：正在显示启事页（三级标签放在标题栏中间，节目上放右上角）
    output wire [23:0] rgb_out,
    output wire        blink                // 闪烁节拍，顶层拿去点 LED
);

// ---------------- 坐标、帧计数 ----------------
reg vs_d, de_d;
reg [9:0] x_cnt, line_y;
reg [5:0] frame_cnt;
reg [6:0] br_cnt;                   // 二级背景慢呼吸：128 帧一个来回（约 2 秒）
reg       emg_d;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        vs_d      <= 1'b1;
        de_d      <= 1'b0;
        x_cnt     <= 10'd0;
        line_y    <= 10'd0;
        frame_cnt <= 6'd0;
        br_cnt    <= 7'd0;
        emg_d     <= 1'b0;
    end else begin
        vs_d  <= vs;
        de_d  <= de;
        x_cnt <= de ? (x_cnt + 10'd1) : 10'd0;
        if (!vs)
            line_y <= 10'd0;
        else if (de_d && !de)
            line_y <= line_y + 10'd1;
        emg_d <= emerg_on;
        if (emerg_on && !emg_d)
            frame_cnt <= 6'd32;              // 刚进入应急：闪烁从“亮”的一半开始
        else if (vs_d && !vs)
            frame_cnt <= frame_cnt + 6'd1;
        if (vs_d && !vs)
            br_cnt <= br_cnt + 7'd1;
    end
end
wire [9:0] px = de ? x_cnt : 10'd0;
assign blink = frame_cnt[5];        // 32 帧亮 32 帧灭，约 1Hz
wire [5:0] br = br_cnt[6] ? ~br_cnt[5:0] : br_cnt[5:0];   // 0 → 63 → 0

wire lv2     = (level == 2'd2);
wire l3      = (level == 2'd3) && !emerg_on;   // 三级：不接管
wire pg      = emerg_on && builtin_on;         // 内置警示页
wire has_txt = (a_len != 10'd0);

// ---------------- 警示页的文字面板（只在内置警示页上） ----------------
localparam integer T_X0 = (H_ACTIVE - 2 * LINE_W) / 2;       // 放大 2 倍后居中
localparam integer T_X1 = T_X0 + 2 * LINE_W;
localparam integer P_X0 = T_X0 - 16, P_X1 = T_X1 + 16;        // 面板左右边界
localparam [9:0]   T_Y  = 10'd200;                            // 第一行文字
wire       pg_txt  = pg && has_txt;
wire [1:0] nl      = (a_len > 2 * LINE_W) ? 2'd3 : (a_len > LINE_W) ? 2'd2 : 2'd1;   // 几行
wire [9:0] t_h     = {3'd0, nl, 5'd0};                        // 行数 × 32
wire [9:0] pan_y0  = T_Y - 10'd8;
wire [9:0] pan_y1  = T_Y + t_h + 10'd8;
wire [9:0] t_dy    = line_y - T_Y;
wire       in_trow = pg_txt && (line_y >= T_Y) && (t_dy < t_h);
wire [9:0] k_off   = t_dy[6] ? (2 * LINE_W) : t_dy[5] ? LINE_W : 10'd0;   // 第几行文字
wire [3:0] t_row   = t_dy[4:1];                               // 放大 2 倍：两条扫描线一行点阵
wire [9:0] nx      = px + 10'd1;                              // RAM 读出晚 1 拍：按下一个像素读
wire [9:0] n_dx    = nx - T_X0;
wire       n_in    = (nx >= T_X0) && (nx < T_X1);
wire [9:0] p_col   = k_off + {1'b0, n_dx[9:1]};
assign a_col = in_trow ? p_col : s_col;                       // 面板那几行以外，读口给底部字幕条
reg        t_vis;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) t_vis <= 1'b0;
    else        t_vis <= in_trow && n_in && (p_col < a_len);
end
wire       t_px    = de && t_vis && a_bits[t_row];

// ---------------- 版面：标题、三角、英文的位置 ----------------
// 警示页（放大 4 倍）：三角 64×64 在 x 152，标题 4 字 × 64 在 x 232；有文字时标题在 64 行，没有文字时居中在 148 行；
//                      英文在标题下面 12 行，放大 4 倍（格宽 24）
// 三级标签：框宽 192、y 14~57，三角 + 标题（放大 2 倍），没有英文；节目上 x 432~623，启事页上 x 224~415
wire [9:0] tg_x0 = page_on ? 10'd224 : 10'd432;
wire [9:0] ti_y0 = pg ? (has_txt ? 10'd64 : 10'd148) : 10'd20;
wire [9:0] ti_x0 = pg ? 10'd232 : (tg_x0 + 10'd52);
wire [9:0] ic_x0 = pg ? 10'd152 : (tg_x0 + 10'd12);
wire [9:0] en_y0 = ti_y0 + 10'd76;
wire [9:0] en_x0 = lv2 ? 10'd176 : 10'd80;
wire       big   = pg;                                         // 放大 4 倍（否则 2 倍）
wire       ti_on = pg || l3;
wire [1:0] sel   = l3 ? 2'd2 : lv2 ? 2'd1 : 2'd0;              // 紧急撤离 / 就地避险 / 区域警戒

// 中文标题（行方向的判断用当前行；列方向用下一个像素算好、打一拍，和 BRAM 读出对齐）
wire [9:0]  tdy    = line_y - ti_y0;
wire        ti_iny = ti_on && (line_y >= ti_y0) && (big ? (tdy < 10'd64) : (tdy < 10'd32));
wire [3:0]  ti_row = big ? tdy[5:2] : tdy[4:1];
reg  [15:0] erom [0:511] /* fehdl force_ram=1, ram_style="bram" */;   // 标题 + 英文点阵（只读）

// 警示三角（黄底黑边，中间黑色感叹号），按 64×64 的坐标算，32×32 时坐标乘 2
wire [9:0] idx_  = px - ic_x0;
wire [9:0] idy   = line_y - ti_y0;
wire       ic_in = ti_on && (px >= ic_x0) && (line_y >= ti_y0) &&
                   (big ? ((idx_ < 10'd64) && (idy < 10'd64)) : ((idx_ < 10'd32) && (idy < 10'd32)));
wire [5:0] iu    = big ? idx_[5:0] : {idx_[4:0], 1'b0};
wire [5:0] iv    = big ? idy[5:0]  : {idy[4:0], 1'b0};
wire [5:0] adx   = iu[5] ? (iu - 6'd32) : (6'd31 - iu);          // 离中线多远 0~31
wire       tri_o = ({adx, 1'b0} <= {1'b0, iv});                  // 外三角：顶点朝上
wire       tri_i = ({adx, 1'b0} + 7'd10 <= {1'b0, iv}) && (iv < 6'd59);
wire       excl  = (adx < 6'd3) && (((iv >= 6'd24) && (iv < 6'd44)) || ((iv >= 6'd49) && (iv < 6'd55)));
wire       ic_px = de && ic_in && tri_o;
wire [23:0] ic_rgb = !tri_i ? 24'h1A1A1A : excl ? 24'h101010 : 24'hFFC000;

// 英文（只在警示页上）：一级 EMERGENCY EVACUATION（20 字）/ 二级 TAKE SHELTER（12 字），5×7 字模放大 4 倍（每字 24 像素）
// 中文标题和英文都存在一块 BRAM（erom，见文件末尾，subtitle/gen_etitle.ps1 生成）：
//   0~191   标题 {字号 4 位, 行 4 位}，每行 16 位，bit15 = 最左边
//   256~    英文 {1, 二级, 行 3 位, 第几个 16 列 4 位}，按 1 倍存（每字 6 列 = 5 列字 + 1 列空），显示时放大 4 倍
// BRAM 读出晚 1 拍：地址按下一个像素（nx）算，用这一个像素的列号取位
wire       en_on  = pg;
wire [9:0] edy    = line_y - en_y0;
wire       en_row = en_on && (line_y >= en_y0) && (edy < 10'd28);
wire [9:0] n_edx  = nx - en_x0;
wire [9:0] n_tdx  = nx - ti_x0;
wire [1:0] n_tidx = big ? n_tdx[7:6] : n_tdx[6:5];
wire [8:0] er_a   = en_row ? {1'b1, lv2, edy[4:2], 1'b0, n_edx[8:6]} : {1'b0, sel, n_tidx, ti_row};
reg  [15:0] er_q;
always @(posedge clk)
    er_q <= erom[er_a];
reg        ti_inx, en_inx;
reg  [3:0] ti_c, en_c;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ti_inx <= 1'b0; en_inx <= 1'b0; ti_c <= 4'd0; en_c <= 4'd0;
    end else begin
        ti_inx <= (nx >= ti_x0) && (big ? (n_tdx < 10'd256) : (n_tdx < 10'd128));
        ti_c   <= big ? n_tdx[5:2] : n_tdx[4:1];
        en_inx <= (nx >= en_x0) && (n_edx < 10'd480);
        en_c   <= n_edx[5:2];
    end
end
wire        ti_px  = de && ti_iny && ti_inx && er_q[4'd15 - ti_c];
wire        en_px  = de && en_row && en_inx && er_q[4'd15 - en_c];


// ---------------- 内置警示页 ----------------
wire [9:0] diag   = px + line_y;
wire       stripe = ((line_y >= 10'd20) && (line_y < 10'd44)) || ((line_y >= 10'd404) && (line_y < 10'd428));
wire [23:0] stripe_rgb = diag[4] ? 24'hFFC000 : 24'h101010;
// 一级暗红、从上到下略微变亮；二级橙色、整体慢慢呼吸（和间歇提示音的节奏对上）
wire [7:0]  bg_r  = 8'h60 + {2'b00, line_y[8:3]};
wire [23:0] pg_bg = lv2 ? {8'hA0 + {2'b00, br}, 8'h3C + {3'b000, br[5:1]}, 8'h04} : {bg_r, 8'h08, 8'h08};
wire [23:0] page  = ti_px  ? 24'hFFFFFF :
                    ic_px  ? ic_rgb :
                    en_px  ? 24'hFFE060 :
                    stripe ? stripe_rgb :
                             pg_bg;
// 文字面板：更深的底色 + 细边
wire in_pan   = pg_txt && de && (line_y >= pan_y0) && (line_y < pan_y1) && (px >= P_X0) && (px < P_X1);
wire pan_edge = (line_y == pan_y0) || (line_y == pan_y1 - 10'd1) || (px == P_X0) || (px == P_X1 - 1);
wire [23:0] pan_px = t_px     ? (lv2 ? 24'hFFF0C0 : 24'hFFFFFF) :
                     pan_edge ? (lv2 ? 24'hFFB040 : 24'hFF5050) :
                                {1'b0, pg_bg[23:17], 1'b0, pg_bg[15:9], 1'b0, pg_bg[7:1]};

// ---------------- 三级：琥珀色细边框 + 顶部小标签 ----------------
wire l3_frame = l3 && de && ((px < 10'd6) || (px >= H_ACTIVE - 6) || (line_y < 10'd6) || (line_y >= V_ACTIVE - 6));
// 位置只有两种，用常数比较（不用加法器）
wire in_tag_x = page_on ? ((px >= 10'd224) && (px < 10'd416)) : ((px >= 10'd432) && (px < 10'd624));
wire tag_ex   = page_on ? ((px < 10'd226) || (px >= 10'd414)) : ((px < 10'd434) || (px >= 10'd622));
wire in_tag   = l3 && de && (line_y >= 10'd14) && (line_y < 10'd58) && in_tag_x;
wire tag_edge = (line_y < 10'd16) || (line_y >= 10'd56) || tag_ex;
wire [23:0] tag_px = ti_px    ? 24'hFFD040 :
                     ic_px    ? ic_rgb :
                     tag_edge ? 24'hFFB020 :
                                24'h1C1C1C;

// 闪烁边框：一级红、二级橙
wire border = emerg_on && blink && de &&
              ((px < BORDER) || (px >= H_ACTIVE - BORDER) ||
               (line_y < BORDER) || (line_y >= V_ACTIVE - BORDER));

assign rgb_out = border       ? (lv2 ? 24'hFF8000 : 24'hFF0000) :
                 in_pan       ? pan_px :
                 (pg && de)   ? page :
                 l3_frame     ? 24'hFFB020 :
                 in_tag       ? tag_px :
                                rgb_in;

// ---------------- 标题 + 英文点阵（subtitle/gen_etitle.ps1 生成，不要手改） ----------------
// BEGIN ETITLE
// generated 2026-11-02 13:07:55 from: 紧急撤离就地避险区域警戒 / EMERGENCY EVACUATION / TAKE SHELTER
integer ei;
initial begin
    for (ei = 0; ei < 512; ei = ei + 1) erom[ei] = 16'h0000;
    erom[1] = 16'h0200;
    erom[2] = 16'h12FE;
    erom[3] = 16'h1244;
    erom[4] = 16'h122C;
    erom[5] = 16'h1238;
    erom[6] = 16'h12EF;
    erom[7] = 16'h0110;
    erom[8] = 16'h0630;
    erom[9] = 16'h0FC8;
    erom[10] = 16'h030C;
    erom[11] = 16'h1FFE;
    erom[12] = 16'h04DC;
    erom[13] = 16'h0CCC;
    erom[14] = 16'h19C6;
    erom[15] = 16'h0180;
    erom[17] = 16'h0300;
    erom[18] = 16'h0600;
    erom[19] = 16'h0DF8;
    erom[20] = 16'h1830;
    erom[21] = 16'h3FFE;
    erom[22] = 16'h0006;
    erom[23] = 16'h0FFE;
    erom[24] = 16'h0006;
    erom[25] = 16'h0FFE;
    erom[26] = 16'h0004;
    erom[27] = 16'h1246;
    erom[28] = 16'h1243;
    erom[29] = 16'h320D;
    erom[30] = 16'h23F8;
    erom[33] = 16'h1884;
    erom[34] = 16'h18CC;
    erom[35] = 16'h1BE8;
    erom[36] = 16'h3D4F;
    erom[37] = 16'h192A;
    erom[38] = 16'h1BEA;
    erom[39] = 16'h1C1A;
    erom[40] = 16'h1BEA;
    erom[41] = 16'h3A2A;
    erom[42] = 16'h1BEA;
    erom[43] = 16'h1BE6;
    erom[44] = 16'h1A24;
    erom[45] = 16'h1A2E;
    erom[46] = 16'h3279;
    erom[49] = 16'h0080;
    erom[50] = 16'h3FFF;
    erom[51] = 16'h0010;
    erom[52] = 16'h0BB0;
    erom[53] = 16'h08E2;
    erom[54] = 16'h0F1A;
    erom[55] = 16'h0FFE;
    erom[56] = 16'h0080;
    erom[57] = 16'h0080;
    erom[58] = 16'h1FFF;
    erom[59] = 16'h1313;
    erom[60] = 16'h167B;
    erom[61] = 16'h138B;
    erom[62] = 16'h1007;
    erom[63] = 16'h1004;
    erom[65] = 16'h0C10;
    erom[66] = 16'h0614;
    erom[67] = 16'h3FD2;
    erom[68] = 16'h0013;
    erom[69] = 16'h0010;
    erom[70] = 16'h1FFF;
    erom[71] = 16'h1190;
    erom[72] = 16'h119C;
    erom[73] = 16'h1F9C;
    erom[74] = 16'h151C;
    erom[75] = 16'h1DBC;
    erom[76] = 16'h34AC;
    erom[77] = 16'h246D;
    erom[78] = 16'h1CCF;
    erom[79] = 16'h0800;
    erom[81] = 16'h0810;
    erom[82] = 16'h0810;
    erom[83] = 16'h0890;
    erom[84] = 16'h0892;
    erom[85] = 16'h3E9E;
    erom[86] = 16'h3EF2;
    erom[87] = 16'h0B92;
    erom[88] = 16'h0892;
    erom[89] = 16'h0892;
    erom[90] = 16'h089E;
    erom[91] = 16'h0A90;
    erom[92] = 16'h3C81;
    erom[93] = 16'h2081;
    erom[94] = 16'h00FF;
    erom[97] = 16'h000C;
    erom[98] = 16'h33CC;
    erom[99] = 16'h127F;
    erom[100] = 16'h1252;
    erom[101] = 16'h03DA;
    erom[102] = 16'h3212;
    erom[103] = 16'h323F;
    erom[104] = 16'h17CC;
    erom[105] = 16'h174C;
    erom[106] = 16'h177F;
    erom[107] = 16'h1F4C;
    erom[108] = 16'h13CC;
    erom[109] = 16'h1C0C;
    erom[110] = 16'h23FF;
    erom[113] = 16'h0030;
    erom[114] = 16'h3E30;
    erom[115] = 16'h3458;
    erom[116] = 16'h34CC;
    erom[117] = 16'h3586;
    erom[118] = 16'h3BFB;
    erom[119] = 16'h3C00;
    erom[120] = 16'h3424;
    erom[121] = 16'h35A4;
    erom[122] = 16'h36A4;
    erom[123] = 16'h3CB4;
    erom[124] = 16'h3888;
    erom[125] = 16'h3008;
    erom[126] = 16'h33FF;
    erom[127] = 16'h3000;
    erom[130] = 16'h1FFF;
    erom[131] = 16'h1000;
    erom[132] = 16'h100C;
    erom[133] = 16'h1308;
    erom[134] = 16'h10D8;
    erom[135] = 16'h1070;
    erom[136] = 16'h1070;
    erom[137] = 16'h1058;
    erom[138] = 16'h108C;
    erom[139] = 16'h1306;
    erom[140] = 16'h1200;
    erom[141] = 16'h1000;
    erom[142] = 16'h1FFF;
    erom[145] = 16'h1814;
    erom[146] = 16'h1812;
    erom[147] = 16'h1810;
    erom[148] = 16'h1BFF;
    erom[149] = 16'h1810;
    erom[150] = 16'h3DF2;
    erom[151] = 16'h1972;
    erom[152] = 16'h197A;
    erom[153] = 16'h196C;
    erom[154] = 16'h19EC;
    erom[155] = 16'h1C0C;
    erom[156] = 16'h386D;
    erom[157] = 16'h239D;
    erom[158] = 16'h0233;
    erom[161] = 16'h0918;
    erom[162] = 16'h3FDF;
    erom[163] = 16'h0922;
    erom[164] = 16'h1FD4;
    erom[165] = 16'h3E5C;
    erom[166] = 16'h138E;
    erom[167] = 16'h1FB3;
    erom[168] = 16'h3FFF;
    erom[170] = 16'h0FFC;
    erom[171] = 16'h0FFC;
    erom[173] = 16'h0FFC;
    erom[174] = 16'h0FFC;
    erom[175] = 16'h0804;
    erom[177] = 16'h0024;
    erom[178] = 16'h0026;
    erom[179] = 16'h0024;
    erom[180] = 16'h3FFF;
    erom[181] = 16'h0020;
    erom[182] = 16'h0922;
    erom[183] = 16'h0926;
    erom[184] = 16'h3FF4;
    erom[185] = 16'h3FD4;
    erom[186] = 16'h091C;
    erom[187] = 16'h0918;
    erom[188] = 16'h0918;
    erom[189] = 16'h193D;
    erom[190] = 16'h30E7;
    erom[256] = 16'hFA2F;
    erom[257] = 16'hBC7B;
    erom[258] = 16'hE89E;
    erom[259] = 16'h880F;
    erom[260] = 16'hA271;
    erom[261] = 16'hE89C;
    erom[262] = 16'hF9C7;
    erom[263] = 16'h2200;
    erom[272] = 16'h8368;
    erom[273] = 16'h2282;
    erom[274] = 16'h0CA0;
    erom[275] = 16'h8808;
    erom[276] = 16'h228A;
    erom[277] = 16'h08A2;
    erom[278] = 16'h2088;
    erom[279] = 16'hB200;
    erom[288] = 16'h82A8;
    erom[289] = 16'h2282;
    erom[290] = 16'h0AA0;
    erom[291] = 16'h5008;
    erom[292] = 16'h228A;
    erom[293] = 16'h08A2;
    erom[294] = 16'h2088;
    erom[295] = 16'hAA00;
    erom[304] = 16'hF2AF;
    erom[305] = 16'h3C9B;
    erom[306] = 16'hC9A0;
    erom[307] = 16'h200F;
    erom[308] = 16'h22FA;
    erom[309] = 16'h08BE;
    erom[310] = 16'h2088;
    erom[311] = 16'hA600;
    erom[320] = 16'h8228;
    erom[321] = 16'h288A;
    erom[322] = 16'h08A0;
    erom[323] = 16'h2008;
    erom[324] = 16'h228A;
    erom[325] = 16'h08A2;
    erom[326] = 16'h2088;
    erom[327] = 16'hA200;
    erom[336] = 16'h8228;
    erom[337] = 16'h248A;
    erom[338] = 16'h08A0;
    erom[339] = 16'h2008;
    erom[340] = 16'h148A;
    erom[341] = 16'h08A2;
    erom[342] = 16'h2088;
    erom[343] = 16'hA200;
    erom[352] = 16'hFA2F;
    erom[353] = 16'hA27B;
    erom[354] = 16'hE89E;
    erom[355] = 16'h200F;
    erom[356] = 16'h8889;
    erom[357] = 16'hE722;
    erom[358] = 16'h21C7;
    erom[359] = 16'h2200;
    erom[384] = 16'hF9C8;
    erom[385] = 16'hBE01;
    erom[386] = 16'hE8BE;
    erom[387] = 16'h83EF;
    erom[388] = 16'hBC00;
    erom[400] = 16'h2229;
    erom[401] = 16'h2002;
    erom[402] = 16'h08A0;
    erom[403] = 16'h8088;
    erom[404] = 16'h2200;
    erom[416] = 16'h222A;
    erom[417] = 16'h2002;
    erom[418] = 16'h08A0;
    erom[419] = 16'h8088;
    erom[420] = 16'h2200;
    erom[432] = 16'h23EC;
    erom[433] = 16'h3C01;
    erom[434] = 16'hCFBC;
    erom[435] = 16'h808F;
    erom[436] = 16'h3C00;
    erom[448] = 16'h222A;
    erom[449] = 16'h2000;
    erom[450] = 16'h28A0;
    erom[451] = 16'h8088;
    erom[452] = 16'h2800;
    erom[464] = 16'h2229;
    erom[465] = 16'h2000;
    erom[466] = 16'h28A0;
    erom[467] = 16'h8088;
    erom[468] = 16'h2400;
    erom[480] = 16'h2228;
    erom[481] = 16'hBE03;
    erom[482] = 16'hC8BE;
    erom[483] = 16'hF88F;
    erom[484] = 16'hA200;
end
// END ETITLE

endmodule
