`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// 图片转场：插在 vout_data 和 osd_layer 之间（OSD 不参与淡入淡出）
// 由参考例程 video_fade_transition.v 改写，适配本工程的单读口四 bank 架构：
//   - 原版 Wipe 需要同时读新旧两帧（old_frame_rgb），单读口做不到，
//     这里改为“淡出到黑 → 黑屏时换 bank → 新图从黑底上揭示出来”
//   - 显示 bank 号由本模块管理（show_idx → frame_read_write.read_addr_index），
//     只在全黑时更新，所以切换绝不撕裂
//   - 原版要握手 next_event，这里直接比较“想显示的 bank”和“正在显示的 bank”，
//     不同就开始转场，连按多次也只会落到最后一张
//
// 效果：
//   手动切换（Key2 / Key4 长按）：淡出 → 黑 → 淡入
//   自动轮播：淡出 → 黑 → Wipe 揭示，每次换一种：左→右、上→下、中间向两边、百叶窗
//   上电第一张：从黑淡入
//   缩略图：want_thumb=1 时淡出 → 黑屏时切到 2×2 网格 → 淡入；
//              网格里移动焦点只动黄框，不转场；分隔线、焦点框、未载入格子涂灰都在这里画（会跟着淡入淡出）
//   【应急模式】SW1 打开且 EMERG.BMP 已载入：不转场，直接硬切到应急 bank（有效显示区任意一行都可以换地址，
//              只避开帧头读请求前后（y_cnt = 0 / 480），不会和读侧锁存地址撞车，下一帧整帧就是应急页；
//              最坏约 570 行 ≈ 18ms）；
//              关掉 SW1 时按普通切换淡出淡入回来。“紧急信息不等转场”——转场分级使用
//   【应急时延实测】从 SW1 打开到第一个应急画面像素输出的时间（0.1ms 为单位），给数码管显示
//   【启事】启事页也是一种“画面”：want_page = 1 时淡出 → 黑屏时切到启事页（show_page，顶层用 notice_page 代替 SDRAM 的图）→ 淡入；
//          两块启事页缓冲（want_pbuf）不同也算换画面，所以启事一条换一条也有转场
//
// 一次转场 = 淡出 FADE_FRAMES 帧 + 黑 (HOLD_FRAMES+2) 帧 + 淡入 FADE_FRAMES 帧
// FADE_FRAMES=16 时约 0.57 秒（60Hz）
// -----------------------------------------------------------------------------
module video_transition #(
    parameter integer FADE_FRAMES = 16,          // 只能取 8 / 16 / 32
    parameter integer HOLD_FRAMES = 2,           // 换 bank 后保持黑屏的帧数
    parameter integer H_ACTIVE    = 640,
    parameter integer V_ACTIVE    = 480,
    parameter integer TICK_01MS   = 2500        // 【应急时延实测】0.1ms 有几拍（video_clk 25MHz）
)(
    input  wire        clk,                      // video_clk
    input  wire        rst_n,
    input  wire        vs,                       // video_delay 输出的 vs（低有效）
    input  wire        de,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out,

    // 来自 sd_card_clk 域，内部同步
    input  wire        display_valid,            // 已有图片可显示
    input  wire [1:0]  want_idx,                 // sd_card_bmp4 的 disp_buf_idx
    input  wire        want_auto,                // 1 = 这次切换来自自动轮播
    input  wire        want_thumb,               // 1 = 想看 2×2 缩略图（此时 want_idx 是焦点）
    input  wire [3:0]  loaded,                   // 哪几个 bank 已经载好（没载好的格子涂黑）
    input  wire        want_page,                // 【启事】1 = 想显示启事页（sd_card_bmp4）
    input  wire        want_pbuf,                // 【启事】哪块启事页缓冲
    // 亮度 / 对比度百分数（已同步到 video_clk，帧头锁存）
    input  wire [7:0]  bri_pct,                  // 20~150
    input  wire [7:0]  con_pct,                  // 50~150
    // 【应急模式】sd_card_clk 域，内部同步
    input  wire        want_emerg,               // SW1：应急模式
    input  wire        emerg_ok,                 // EMERG.BMP 已载入应急 bank

    output reg  [1:0]  show_idx,                 // → frame_read_write.read_addr_index
    output reg         show_thumb,               // → frame_read_write.thumb_mode，只在全黑时变
    output reg         show_emerg,               // 【应急模式】1 = 显示应急 bank（顶层据此换读地址）
    output reg         show_page,                // 【启事】1 = 显示启事页（只在全黑时变）
    output reg         show_pbuf,                // 【启事】显示哪块启事页缓冲
    output wire        need_builtin,             // 【应急模式】应急模式但没有可显示的 EMERG.BMP：用内置警示页
    output wire [3:0]  shown_num,                // 正在显示的图片号 1~4，0=黑屏未出图（给 OSD）
    output reg         busy,                     // 转场进行中（sd_card_bmp4 用它暂停轮播计时）
    output reg  [7:0]  emg_lat,                  // 【应急时延实测】最近一次进入应急的响应时间，单位 0.1ms（四舍五入，最多 25.5ms）
    output reg         emg_lat_ok                // 1 = 已测完（emg_lat 有效）
);

localparam integer STEP = 256 / FADE_FRAMES;
localparam integer WX   = H_ACTIVE / FADE_FRAMES;          // 左→右每帧推进
localparam integer WY   = V_ACTIVE / FADE_FRAMES;          // 上→下
localparam integer WC   = (H_ACTIVE / 2) / FADE_FRAMES;    // 中间向两边，单侧
localparam integer WB   = 64 / FADE_FRAMES;                // 百叶窗，每条 64 像素宽

localparam [2:0] S_WAIT = 3'd0;   // 没有图片，黑屏
localparam [2:0] S_IDLE = 3'd1;   // 正常显示
localparam [2:0] S_OUT  = 3'd2;   // 淡出
localparam [2:0] S_HOLD = 3'd3;   // 全黑，在这里换 bank
localparam [2:0] S_IN   = 3'd4;   // 淡入 / Wipe 揭示

// ---------------- 跨时钟域 ----------------
reg       valid_s1, valid_s2;
reg [4:0] want_s1, want_s2, want_s3;            // {【启事】启事页, 启事页缓冲, 缩略图, 图片号}
reg       auto_s1, auto_s2;
reg [3:0] loaded_s1, loaded_s2;
reg       emg_s1, emg_s2, emok_s1, emok_s2;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        valid_s1  <= 1'b0; valid_s2  <= 1'b0;
        want_s1   <= 5'd0; want_s2   <= 5'd0; want_s3 <= 5'd0;
        auto_s1   <= 1'b0; auto_s2   <= 1'b0;
        loaded_s1 <= 4'd0; loaded_s2 <= 4'd0;
        emg_s1    <= 1'b0; emg_s2    <= 1'b0;
        emok_s1   <= 1'b0; emok_s2   <= 1'b0;
    end else begin
        valid_s1  <= display_valid;          valid_s2  <= valid_s1;
        want_s1   <= {want_page, want_pbuf, want_thumb, want_idx}; want_s2 <= want_s1;  want_s3 <= want_s2;
        auto_s1   <= want_auto;              auto_s2   <= auto_s1;
        loaded_s1 <= loaded;                 loaded_s2 <= loaded_s1;
        emg_s1    <= want_emerg;             emg_s2    <= emg_s1;
        emok_s1   <= emerg_ok;               emok_s2   <= emok_s1;
    end
end
// 多位总线逐位同步时可能出现一拍中间值，连续两拍相同才认
wire want_stable = (want_s2 == want_s3);
wire [1:0] want_i  = want_s3[1:0];
wire       want_t  = want_s3[2];
wire       want_p  = want_s3[4] && !want_s3[2];     // 【启事】缩略图优先
wire       want_pb = want_s3[3];
// 【应急模式】要显示应急 bank
wire       e_req   = emg_s2 && emok_s2;
assign need_builtin = emg_s2 && !(emok_s2 && valid_s2);
// 缩略图模式下焦点移动不算切换画面（只是边框动），所以比较时去掉图片号
wire [5:0] want_view = e_req      ? 6'b100000 : want_t     ? 6'b010000 : want_p    ? {5'b00100, want_pb}   : {4'b0000, want_i};
wire [5:0] cur_view  = show_emerg ? 6'b100000 : show_thumb ? 6'b010000 : show_page ? {5'b00100, show_pbuf} : {4'b0000, show_idx};

// ---------------- 帧头与像素坐标 ----------------
reg vs_d, de_d;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        vs_d <= 1'b1;
        de_d <= 1'b0;
    end else begin
        vs_d <= vs;
        de_d <= de;
    end
end
wire frame_start = vs_d & ~vs;      // 与官方 read_req 同一个沿，处在消隐区

reg [9:0] x_cnt;
reg [9:0] y_cnt;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        x_cnt <= 10'd0;
        y_cnt <= 10'd0;
    end else begin
        x_cnt <= de ? (x_cnt + 10'd1) : 10'd0;
        if (frame_start)
            y_cnt <= 10'd0;
        else if (de_d && !de)
            y_cnt <= y_cnt + 10'd1;
    end
end

// ---------------- 状态机：所有影响画面的量只在帧头变化 ----------------
reg [2:0] state;
reg [5:0] ramp;                     // 0 ~ FADE_FRAMES
reg [3:0] hold_cnt;
reg       wipe_on;
reg [1:0] wipe_mode;
reg [1:0] wipe_next;
reg       e_pend;                   // 【应急模式】已在本帧中途换了地址，下一帧头切到全亮

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state     <= S_WAIT;
        ramp      <= 6'd0;
        hold_cnt  <= 4'd0;
        show_idx  <= 2'd0;
        show_thumb <= 1'b0;
        show_emerg <= 1'b0;
        show_page <= 1'b0;
        show_pbuf <= 1'b0;
        e_pend    <= 1'b0;
        wipe_on   <= 1'b0;
        wipe_mode <= 2'd0;
        wipe_next <= 2'd0;
    end else if (!valid_s2) begin
        // 没有图（上电、拔卡重新初始化）：黑屏，等图
        state   <= S_WAIT;
        ramp    <= 6'd0;
        wipe_on <= 1'b0;
        show_emerg <= 1'b0;
        show_page <= 1'b0;
        e_pend  <= 1'b0;
    end else begin
        case (state)
            S_WAIT: begin
                // 第一张图：直接进入黑屏保持，换到它的 bank 后淡入
                state    <= S_HOLD;
                hold_cnt <= HOLD_FRAMES;
                wipe_on  <= 1'b0;
            end

            S_IDLE: begin
                if (want_stable && (want_view != cur_view) && !e_req) begin   // 进入应急由下面的硬切处理
                    state <= S_OUT;
                    ramp  <= FADE_FRAMES;     // 当前帧保持全亮，下一帧开始变暗
                end
            end

            S_OUT: begin
                if (frame_start) begin
                    if (ramp == 6'd0) begin
                        // 已经完整显示过一帧全黑，进入保持并换 bank
                        state    <= S_HOLD;
                        hold_cnt <= HOLD_FRAMES;
                        wipe_on  <= auto_s2 && !want_t && !show_emerg;     // 从应急页回来用淡入
                        if (auto_s2 && !want_t && !show_emerg) begin
                            wipe_mode <= wipe_next;
                            wipe_next <= wipe_next + 2'd1;
                        end
                    end else begin
                        ramp <= ramp - 6'd1;
                    end
                end
            end

            S_HOLD: begin
                // 全黑期间跟随最新的目标，保持期内连按也只显示最后一张
                if (want_stable && !e_req) begin
                    show_emerg <= 1'b0;         // 【应急模式】退出应急：黑屏时换回普通 bank
                    show_thumb <= want_t;
                    show_page  <= want_p;       // 【启事】
                    show_pbuf  <= want_pb;
                    if (!want_t)
                        show_idx <= want_i;     // 缩略图期间 show_idx 保持不变，读侧不用它
                end
                if (frame_start) begin
                    if (hold_cnt == 4'd0) begin
                        state <= S_IN;
                        ramp  <= 6'd0;
                    end else begin
                        hold_cnt <= hold_cnt - 4'd1;
                    end
                end
            end

            S_IN: begin
                if (frame_start) begin
                    if (ramp == FADE_FRAMES)
                        state <= S_IDLE;
                    else
                        ramp <= ramp + 6'd1;
                end
            end

            default: state <= S_WAIT;
        endcase

        // 【应急模式】硬切，不管当前在转场的哪一步（写在 case 后面，优先级最高）：
        //   有效显示区内换读地址（本帧剩下的部分读侧早已锁存旧地址，不受影响）
        //   下一帧头：状态直接回到正常显示，全亮，不淡入
        if (e_req && !show_emerg && (y_cnt != 10'd0) && (y_cnt != V_ACTIVE)) begin
            show_emerg <= 1'b1;
            show_thumb <= 1'b0;
            show_page  <= 1'b0;
            e_pend     <= 1'b1;
        end
        if (e_pend && frame_start) begin
            state   <= S_IDLE;
            ramp    <= FADE_FRAMES;
            wipe_on <= 1'b0;
            e_pend  <= 1'b0;
        end
    end
end

// 转场进行中，或者目标已变但还没开始（给轮播计时用）
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        busy <= 1'b0;
    else
        busy <= (state != S_IDLE) || (want_view != cur_view);
end

// 缩略图模式下 OSD 显示焦点所在的图片号
wire [1:0] num_idx = show_thumb ? want_i : show_idx;
assign shown_num = (valid_s2 && (state != S_WAIT)) ? ({2'b00, num_idx} + 4'd1) : 4'd0;

// ---------------- 每帧的亮度和揭示边界（寄存，帧头后一拍更新，仍在消隐区） ----------------
reg [8:0] alpha;                    // 0 ~ 256，256 = 原样输出
reg [9:0] bound_x;
reg [9:0] bound_y;
reg [9:0] bound_c;
reg [6:0] bound_b;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        alpha   <= 9'd0;
        bound_x <= 10'd0;
        bound_y <= 10'd0;
        bound_c <= 10'd0;
        bound_b <= 7'd0;
    end else begin
        case (state)
            S_IDLE:  alpha <= 9'd256;
            S_OUT:   alpha <= ramp * STEP;
            S_IN:    alpha <= wipe_on ? 9'd256 : (ramp * STEP);
            default: alpha <= 9'd0;           // S_WAIT / S_HOLD 全黑
        endcase
        bound_x <= ramp * WX;
        bound_y <= ramp * WY;
        bound_c <= ramp * WC;
        bound_b <= ramp * WB;
    end
end

// ---------------- 像素运算（组合逻辑，不增加延迟，hs/vs/de 不用改） ----------------
wire [9:0] px = de ? x_cnt : 10'd0;
wire [9:0] dist_c = (px >= (H_ACTIVE / 2)) ? (px - (H_ACTIVE / 2)) : ((H_ACTIVE / 2) - 1 - px);

reg inside;
always @(*) begin
    case (wipe_mode)
        2'd0:    inside = (px < bound_x);                    // 左 → 右
        2'd1:    inside = (y_cnt < bound_y);                 // 上 → 下
        2'd2:    inside = (dist_c < bound_c);                // 中间向两边
        default: inside = ({1'b0, px[5:0]} < bound_b);       // 百叶窗
    endcase
end

wire masked = (state == S_IN) && wipe_on && !inside;

// ---------------- 缩略图装饰：分隔线、焦点黄框、未载入格子涂黑 ----------------
// 焦点和载入状态在帧头锁存，一帧内不变，边框不会撕裂
reg [1:0] focus_f;
reg [3:0] loaded_f;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        focus_f  <= 2'd0;
        loaded_f <= 4'd0;
    end else if (frame_start) begin
        focus_f  <= want_i;
        loaded_f <= loaded_s2;
    end
end

localparam integer HALF_W = H_ACTIVE / 2;
localparam integer HALF_H = V_ACTIVE / 2;
wire       cell_r  = (px >= HALF_W);
wire       cell_b  = (y_cnt >= HALF_H);
wire [1:0] t_cell    = {cell_b, cell_r};
wire [9:0] lx      = cell_r ? (px - HALF_W) : px;
wire [9:0] ly      = cell_b ? (y_cnt - HALF_H) : y_cnt;
wire       grid    = (lx == 10'd0) || (lx == HALF_W - 1) || (ly == 10'd0) || (ly == HALF_H - 1);
wire       border  = (lx < 10'd5) || (lx >= HALF_W - 5) || (ly < 10'd5) || (ly >= HALF_H - 5);

wire [23:0] rgb_src = !show_thumb               ? rgb_in   :
                      (border && t_cell == focus_f) ? 24'hFFD000 :   // 焦点黄框
                      grid                      ? 24'h000000 :   // 格子之间的黑线
                      !loaded_f[t_cell]           ? 24'h202020 :   // 没载好的格子
                                                  rgb_in;

// ---------------- 亮度 / 对比度，和淡入淡出合成一次乘加 ----------------
// 参考例程 brightness_contrast_adjust.v 的公式：y = ((x-128)·c + 128)·b，再乘转场亮度 a
//   展开：y = x·(c·b·a) + 128·(1-c)·b·a = (x·G + O) / 1024
//   b、c 用 Q8 定点（256 = 100%），pct×41/16 ≈ pct×2.56，100% 正好是 256
//   E = b·a（Q10），G = c·E（Q10），O = (256-c)·E/2
//   多留 2 位小数：仿真全组合最大误差 ≤2 级（只留 Q8 时有 3 级）
// G、O 每帧只变一次（帧头锁存参数，alpha 也只在帧头变），在消隐区里几拍就算好；
// 每个像素仍然只有一个乘法（原来的 x·alpha 换成 x·G），再加偏移、限幅到 0~255。
// 100% / 100% 时 G=alpha×4、O=0，结果和原来完全一样。
reg  [7:0]  bri_f, con_f;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bri_f <= 8'd100;
        con_f <= 8'd100;
    end else if (frame_start) begin
        bri_f <= bri_pct;
        con_f <= con_pct;
    end
end

wire [12:0] bq_full = bri_f * 6'd41;
wire [12:0] cq_full = con_f * 6'd41;
reg  [8:0]  bq, cq;                 // 51~384 / 128~384
reg  [10:0] e_k;                    // 0~1536
reg  [11:0] g_k;                    // 0~2304
reg  signed [17:0] o_k;             // -98304~+98304
wire [17:0] e_full = bq * alpha;
wire [19:0] g_full = cq * e_k;
wire signed [19:0] o_full = $signed({1'b0, 9'd256} - {1'b0, cq}) * $signed({1'b0, e_k});
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bq  <= 9'd256;
        cq  <= 9'd256;
        e_k <= 11'd0;
        g_k <= 12'd0;
        o_k <= 18'sd0;
    end else begin
        bq  <= bq_full[12:4];
        cq  <= cq_full[12:4];
        e_k <= e_full[16:6];
        g_k <= g_full[19:8];
        o_k <= o_full >>> 1;
    end
end

function [7:0] bc_pix;
    input [7:0] x;
    input [11:0] g;                 // 系数作为参数传进来：函数体里直接引用模块信号，仿真时不会随它们更新
    input signed [17:0] o;
    reg        [19:0] prod;         // 单独赋值，乘积按 20 位算（放进拼接里会被截短）
    reg signed [21:0] acc;
    begin
        prod = x * g;
        acc  = $signed({2'b00, prod}) + o;
        if (acc < 0)
            bc_pix = 8'd0;
        else if (acc[21:10] > 12'd255)
            bc_pix = 8'd255;
        else
            bc_pix = acc[17:10];
    end
endfunction

assign rgb_out = masked ? 24'd0 : {bc_pix(rgb_src[23:16], g_k, o_k), bc_pix(rgb_src[15:8], g_k, o_k), bc_pix(rgb_src[7:0], g_k, o_k)};

// ---------------- 【应急时延实测】 ----------------
// 计时起点：SW1 打开（同步到本时钟域，比开关动作晚不到 0.1us）
// 计时终点：第一个应急画面像素送出 ——
//   没有 EMERG.BMP（或还没出图）：内置警示页，下一个有效像素就是；
//   有 EMERG.BMP：已经换到应急 bank 的那一帧（e_pend 在帧头清掉）的第一个有效像素
// 0.1ms 一档，计数器从半档开始，相当于四舍五入。测量途中关掉 SW1 就作废
reg        emg_d;
reg        lat_run;
reg [11:0] lat_pre;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        emg_d      <= 1'b0;
        lat_run    <= 1'b0;
        lat_pre    <= 12'd0;
        emg_lat    <= 8'd0;
        emg_lat_ok <= 1'b0;
    end else begin
        emg_d <= emg_s2;
        if (emg_s2 && !emg_d) begin
            lat_run    <= 1'b1;
            lat_pre    <= TICK_01MS / 2;
            emg_lat    <= 8'd0;
            emg_lat_ok <= 1'b0;
        end else if (lat_run) begin
            if (!emg_s2)
                lat_run <= 1'b0;
            else if (de && (need_builtin || (show_emerg && !e_pend))) begin
                lat_run    <= 1'b0;
                emg_lat_ok <= 1'b1;
            end else if (lat_pre == TICK_01MS - 1) begin
                lat_pre <= 12'd0;
                if (emg_lat != 8'hFF) emg_lat <= emg_lat + 8'd1;
            end else
                lat_pre <= lat_pre + 12'd1;
        end
    end
end

endmodule
