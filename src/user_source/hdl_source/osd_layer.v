`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// OSD 图层：插在 video_delay 输出和 video_rgb_to_axis 之间
//   第1层 【分辨率显示】左上角原图分辨率标签（例如 1078x1262 -> 640x480），串口 分辨率开 / 分辨率关
//          （原来这里是调试用的 4 字符状态条“1E00”，已去掉；图片序号在数码管上）
//   第2层 subtitle_strip：底部滚动字幕条（中文 + 英文点阵，每张图一条，原 promax_text_overlay 已换掉）
//   第3层 promax_audio_waveform（参考模块）：字幕上方的音频波形 + 峰值条
//   第4层 param_bar_overlay：上方参数条，调参数 / 切轮播周期时显示
//   字幕受 osd_on（字幕开关）控制，波形受 res_info[33]（波形开关）控制，两者分开；第 4 层不受影响
// 两个参考模块原样使用，本文件只负责：
//   - 从 de 生成 pixel_x（官方时序没有坐标输出）
//   - 把 sd_card_clk 域的状态打两拍同步到 video_clk 域
//   - 两层串接
// 纯组合叠加，不增加视频延迟，hs/vs/de 不用改。
// -----------------------------------------------------------------------------
module osd_layer #(
    parameter integer SUBTITLE_Y = 448,           // 字幕条顶端行号（条高约 20 行）
    parameter integer WAVE_Y     = 376            // 波形框顶端行号（框高 64 行，在字幕上方）
)(
    input  wire        clk,                       // video_clk
    input  wire        rst_n,
    input  wire        vs,                        // 低有效场同步（官方 VS_POL=0）
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [3:0]  img_num,                   // sd_card_clk 域：1~4，0=未出图
    input  wire        auto_on,                   // sd_card_clk 域
    input  wire [3:0]  err_code,                  // sd_card_clk 域
    input  wire        subtitle_on,
    input  wire [95:0] subtitle_text,             // 第 k 个字符放在 [k*8 +: 8]
    input  wire [5:0]  subtitle_len,              // 1~12
    // 送进 HDMI 的音频样本（video_clk 域）
    input  wire        wave_on,
    input  wire        pcm_valid,
    input  wire signed [15:0] pcm_left,
    // 以下都已同步到 video_clk（ctrl_to_video）
    input  wire        osd_on,                    // SW4：1 = 显示状态条、字幕、波形
    input  wire        menu_on,                   // SW2：参数菜单打开
    input  wire [1:0]  menu_sel,                  // 选中项 0 亮度 1 对比度 2 音量 3 轮播周期
    input  wire [7:0]  bri_pct,
    input  wire [7:0]  con_pct,
    input  wire [7:0]  vol_pct,
    input  wire [2:0]  period_idx,                // 0~5 = 1/3/5/10/30/60 秒
    // 【应急模式】video_clk 域：字幕换成红底白字的应急指令并强制显示（不受 SW4 影响），状态条和波形隐藏
    input  wire        alert,
    // 【缩略图】video_clk 域（video_transition 的 show_thumb，只在全黑时变）：1 = 正在显示 2×2 缩略图，
    // 状态条、字幕、波形都不显示，免得挡住格子；应急字幕和参数条不受影响
    input  wire        thumb_on,
    // 【串口通知】notice_uart（video_clk 域）：字幕条换成通知，不受 SW4 和缩略图影响，应急时让位给应急字幕
    input  wire        notice_on,
    input  wire [10:0] notice_len,
    input  wire        notice_new,
    output wire [9:0]  notice_col,
    input  wire [15:0] notice_bits,
    input  wire        notice_cs,                 // 【自定义字幕】这张图的字幕换成串口设的（在通知 RAM 里）
    // 【波形开关】【分辨率显示】video_clk 域（sd_card_bmp4 的 v_res）：
    //   [33] 波形开（已排除启事页）  [32] 显示分辨率（已排除启事页、未出图）  [31:16] 原图宽 BCD  [15:0] 原图高 BCD
    input  wire [33:0] res_info,
    input  wire [1:0]  alm_level,                 // 【应急改版】video_clk 域实际等级：二级字幕条橙色；三级时不显示分辨率（顶部有警戒标签）
    output wire [23:0] rgb_out
);

// 【字幕】subtitle_text / subtitle_len 是原版字幕的端口，改用点阵条字幕后不再使用，
// 保留端口只是为了不用改顶层；字幕内容在 subtitle/subtitles.txt 里改

// ---------------- 跨时钟域：两拍同步，OSD 内部还会在帧头再锁存一次 ----------------
reg [3:0] img_s1, img_s2;
reg       auto_s1, auto_s2;
reg [3:0] err_s1, err_s2;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        img_s1 <= 4'd0;  img_s2 <= 4'd0;
        auto_s1 <= 1'b0; auto_s2 <= 1'b0;
        err_s1 <= 4'd0;  err_s2 <= 4'd0;
    end else begin
        img_s1 <= img_num;  img_s2 <= img_s1;
        auto_s1 <= auto_on; auto_s2 <= auto_s1;
        err_s1 <= err_code; err_s2 <= err_s1;
    end
end

// ---------------- 行内像素坐标：de 有效期间从 0 计数 ----------------
reg [9:0] x_cnt;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        x_cnt <= 10'd0;
    else if (de)
        x_cnt <= x_cnt + 10'd1;
    else
        x_cnt <= 10'd0;
end
wire [9:0] pixel_x = de ? x_cnt : 10'd0;

// ---------------- 第1层：【分辨率显示】左上角原图分辨率 ----------------
wire [1:0]  active_index = (img_s2 == 4'd0) ? 2'd0 : (img_s2[1:0] - 2'd1);
// 字幕：字幕开关打开（osd_on 已排除启事页）；【应急模式】【缩略图】不显示
wire        normal_osd = osd_on && !alert && !thumb_on;
wire [23:0] rgb_status;
wire [23:0] rgb_subtitle;
wire [23:0] rgb_wave;

// 内容：宽（去掉前导 0）+ x + 高 + " -> 640x480"，5×7 字模放大 2 倍，每格 12×16，样式同参数条（压暗底 + 白字）。
// 每一行从左到右按格子推进一个小状态机：先宽的各位，再 x，再高的各位，再固定的后缀，像素通路里没有除法和查表移位。
localparam integer LBL_X = 16;
localparam integer LBL_Y = 10;
localparam [3:0] RC_X = 4'd10, RC_DASH = 4'd11, RC_GT = 4'd12, RC_SP = 4'd15;

reg       vs_q, de_q;
reg [9:0] line_y;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        vs_q   <= 1'b1;
        de_q   <= 1'b0;
        line_y <= 10'd0;
    end else begin
        vs_q <= vs;
        de_q <= de;
        if (!vs)
            line_y <= 10'd0;
        else if (de_q && !de)
            line_y <= line_y + 10'd1;
    end
end
wire frame_start = vs_q & ~vs;

// 帧头锁存：显示与否、各位数字、位数、标签右边界
reg        rl_show;
reg [15:0] rl_w, rl_h;
reg [1:0]  rl_nw, rl_nh;                 // 位数 - 1
reg [9:0]  rl_xe;                        // 字符区右边界（不含）
wire [1:0] nw_c = (res_info[31:28] != 4'd0) ? 2'd3 : (res_info[27:24] != 4'd0) ? 2'd2 : (res_info[23:20] != 4'd0) ? 2'd1 : 2'd0;
wire [1:0] nh_c = (res_info[15:12] != 4'd0) ? 2'd3 : (res_info[11:8]  != 4'd0) ? 2'd2 : (res_info[7:4]   != 4'd0) ? 2'd1 : 2'd0;
wire [4:0] ncell_c = {3'd0, nw_c} + {3'd0, nh_c} + 5'd14;   // 宽位数 + 高位数 + 12（x 和 11 个后缀字符）
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rl_show <= 1'b0;
        rl_w    <= 16'd0;
        rl_h    <= 16'd0;
        rl_nw   <= 2'd0;
        rl_nh   <= 2'd0;
        rl_xe   <= 10'd0;
    end else if (frame_start) begin
        rl_show <= res_info[32] && !alert && !thumb_on && !menu_on && (img_s2 != 4'd0) && (alm_level != 2'd3);   // 菜单打开时让位给参数条
        rl_w    <= res_info[31:16];
        rl_h    <= res_info[15:0];
        rl_nw   <= nw_c;
        rl_nh   <= nh_c;
        rl_xe   <= LBL_X + {ncell_c, 3'b000} + {1'b0, ncell_c, 2'b00};   // LBL_X + 格数 × 12
    end
end

// 格子推进：rp 0 = 宽，1 = x，2 = 高，3 = 后缀；rd 当前位（从高位往低位数），rs 后缀第几个
reg [3:0] rcx;                           // 格内像素 0~11
reg [1:0] rp, rd;
reg [3:0] rs;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rcx <= 4'd0; rp <= 2'd0; rd <= 2'd0; rs <= 4'd0;
    end else if (!de) begin
        rcx <= 4'd0; rp <= 2'd0; rd <= rl_nw; rs <= 4'd0;
    end else if (pixel_x >= LBL_X) begin
        if (rcx == 4'd11) begin
            rcx <= 4'd0;
            case (rp)
                2'd0: if (rd == 2'd0) rp <= 2'd1; else rd <= rd - 2'd1;
                2'd1: begin rp <= 2'd2; rd <= rl_nh; end
                2'd2: if (rd == 2'd0) begin rp <= 2'd3; rs <= 4'd0; end else rd <= rd - 2'd1;
                default: if (rs != 4'd15) rs <= rs + 4'd1;
            endcase
        end else begin
            rcx <= rcx + 4'd1;
        end
    end
end

wire [15:0] rl_dig = (rp == 2'd0) ? rl_w : rl_h;
reg  [3:0]  rl_c;
always @(*) begin
    case (rp)
        2'd1:    rl_c = RC_X;
        2'd3:    case (rs)
                     4'd0:  rl_c = RC_SP;
                     4'd1:  rl_c = RC_DASH;
                     4'd2:  rl_c = RC_GT;
                     4'd3:  rl_c = RC_SP;
                     4'd4:  rl_c = 4'd6;
                     4'd5:  rl_c = 4'd4;
                     4'd6:  rl_c = 4'd0;
                     4'd7:  rl_c = RC_X;
                     4'd8:  rl_c = 4'd4;
                     4'd9:  rl_c = 4'd8;
                     4'd10: rl_c = 4'd0;
                     default: rl_c = RC_SP;
                 endcase
        default: case (rd)                    // 宽或高的第 rd 位
                     2'd3:    rl_c = rl_dig[15:12];
                     2'd2:    rl_c = rl_dig[11:8];
                     2'd1:    rl_c = rl_dig[7:4];
                     default: rl_c = rl_dig[3:0];
                 endcase
    endcase
end

// 5×7 字模（数字同参数条），x、-、> 是本工程加的
function [4:0] rglyph;
    input [3:0] c;
    input [2:0] r;
    begin
        rglyph = 5'b00000;
        case (c)
            4'd0: case(r) 0:rglyph=5'b01110;1:rglyph=5'b10001;2:rglyph=5'b10011;3:rglyph=5'b10101;4:rglyph=5'b11001;5:rglyph=5'b10001;6:rglyph=5'b01110;default:rglyph=0;endcase
            4'd1: case(r) 0:rglyph=5'b00100;1:rglyph=5'b01100;2:rglyph=5'b00100;3:rglyph=5'b00100;4:rglyph=5'b00100;5:rglyph=5'b00100;6:rglyph=5'b01110;default:rglyph=0;endcase
            4'd2: case(r) 0:rglyph=5'b01110;1:rglyph=5'b10001;2:rglyph=5'b00001;3:rglyph=5'b00010;4:rglyph=5'b00100;5:rglyph=5'b01000;6:rglyph=5'b11111;default:rglyph=0;endcase
            4'd3: case(r) 0:rglyph=5'b11110;1:rglyph=5'b00001;2:rglyph=5'b00001;3:rglyph=5'b01110;4:rglyph=5'b00001;5:rglyph=5'b00001;6:rglyph=5'b11110;default:rglyph=0;endcase
            4'd4: case(r) 0:rglyph=5'b00010;1:rglyph=5'b00110;2:rglyph=5'b01010;3:rglyph=5'b10010;4:rglyph=5'b11111;5:rglyph=5'b00010;6:rglyph=5'b00010;default:rglyph=0;endcase
            4'd5: case(r) 0:rglyph=5'b11111;1:rglyph=5'b10000;2:rglyph=5'b10000;3:rglyph=5'b11110;4:rglyph=5'b00001;5:rglyph=5'b00001;6:rglyph=5'b11110;default:rglyph=0;endcase
            4'd6: case(r) 0:rglyph=5'b01110;1:rglyph=5'b10000;2:rglyph=5'b10000;3:rglyph=5'b11110;4:rglyph=5'b10001;5:rglyph=5'b10001;6:rglyph=5'b01110;default:rglyph=0;endcase
            4'd7: case(r) 0:rglyph=5'b11111;1:rglyph=5'b00001;2:rglyph=5'b00010;3:rglyph=5'b00100;4:rglyph=5'b01000;5:rglyph=5'b01000;6:rglyph=5'b01000;default:rglyph=0;endcase
            4'd8: case(r) 0:rglyph=5'b01110;1:rglyph=5'b10001;2:rglyph=5'b10001;3:rglyph=5'b01110;4:rglyph=5'b10001;5:rglyph=5'b10001;6:rglyph=5'b01110;default:rglyph=0;endcase
            4'd9: case(r) 0:rglyph=5'b01110;1:rglyph=5'b10001;2:rglyph=5'b10001;3:rglyph=5'b01111;4:rglyph=5'b00001;5:rglyph=5'b00001;6:rglyph=5'b01110;default:rglyph=0;endcase
            RC_X:    case(r) 2:rglyph=5'b10001;3:rglyph=5'b01010;4:rglyph=5'b00100;5:rglyph=5'b01010;6:rglyph=5'b10001;default:rglyph=0;endcase
            RC_DASH: case(r) 3:rglyph=5'b11111;default:rglyph=0;endcase
            RC_GT:   case(r) 0:rglyph=5'b10000;1:rglyph=5'b01000;2:rglyph=5'b00100;3:rglyph=5'b00010;4:rglyph=5'b00100;5:rglyph=5'b01000;6:rglyph=5'b10000;default:rglyph=0;endcase
            default: rglyph = 5'b00000;
        endcase
    end
endfunction

wire [9:0] rly     = line_y - LBL_Y;
wire       rl_band = rl_show && de && (pixel_x >= LBL_X - 6) && (pixel_x < rl_xe + 10'd6) &&
                     (line_y >= LBL_Y - 4) && (line_y < LBL_Y + 20);
wire [4:0] rl_row  = rglyph(rl_c, rly[3:1]);
wire [2:0] rl_gc   = rcx[3:1];
wire       rl_text = rl_band && (pixel_x >= LBL_X) && (pixel_x < rl_xe) && (line_y >= LBL_Y) && (rly < 10'd14) &&
                     (rl_gc < 3'd5) && rl_row[3'd4 - rl_gc];
wire [23:0] rl_dark = {2'b00, rgb_in[23:18], 2'b00, rgb_in[15:10], 2'b00, rgb_in[7:2]};
assign rgb_status = !rl_band ? rgb_in : rl_text ? 24'hF0F0F0 : rl_dark;

// ---------------- 第2层：滚动字幕（中文 + 英文，每张图一条） ----------------
// 跟着当前显示的图片换字幕，应急时换成应急字幕；缩略图里不显示
subtitle_strip #(
    .BAND_X0       (8),
    .BAND_X1       (632),
    .BAND_Y        (SUBTITLE_Y),
    .FRAMES_PER_PX (1)
) u_subtitle (
    .clk     (clk),
    .rst_n   (rst_n),
    .vs      (vs),
    .de      (de),
    .pixel_x (pixel_x),
    .rgb_in  (rgb_status),
    .enable  (alert || (subtitle_on && normal_osd && (img_s2 != 4'd0))),   // 出图后才显示；应急时一直显示
    .slot    (alert ? 3'd4 : {1'b0, active_index}),
    .alert   (alert),
    .alert_l2 (alm_level == 2'd2),
    .notice      (notice_on),
    .notice_len  (notice_len),
    .notice_new  (notice_new),
    .notice_col  (notice_col),
    .notice_bits (notice_bits),
    .custom      (notice_cs),
    .rgb_out (rgb_subtitle)
);

// ---------------- 第3层：音频波形 ----------------
promax_audio_waveform #(
    .WAVE_X      (64),
    .WAVE_Y      (WAVE_Y),
    .WAVE_WIDTH  (512),
    .WAVE_HEIGHT (64),
    .DECIMATE    (12)
) u_waveform (
    .clk             (clk),
    .rst_n           (rst_n),
    .vsync           (vs),
    .de              (de),
    .rgb_in          (rgb_subtitle),
    .pixel_x         (pixel_x),
    .enable          (wave_on && res_info[33] && !alert && !thumb_on && (img_s2 != 4'd0)),   // 【波形开关】单独开关；出图后才显示；应急、缩略图、启事页不显示
    .pcm_tap_valid   (pcm_valid),
    .pcm_tap_left    (pcm_left),
    .rgb_out         (rgb_wave),
    .waveform_active ()
);

// ---------------- 第4层：参数条，不受 SW4 控制 ----------------
param_bar_overlay #(
    .BAR_X        (156),
    .BAR_Y        (8)
) u_param_bar (
    .clk          (clk),
    .rst_n        (rst_n),
    .vs           (vs),
    .de           (de),
    .pixel_x      (pixel_x),
    .rgb_in       (rgb_wave),
    .show         (menu_on),
    .sel          (menu_sel),
    .bri_pct      (bri_pct),
    .con_pct      (con_pct),
    .vol_pct      (vol_pct),
    .period_idx   (period_idx),
    .rgb_out      (rgb_out)
);

endmodule
