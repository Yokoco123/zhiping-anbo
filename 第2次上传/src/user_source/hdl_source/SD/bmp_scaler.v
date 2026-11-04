`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// 【图片缩放】任意分辨率 24 位 BMP → 640×480 流式缩放（双线性插值）
// 在加载时做（fat32_bmp_read 的像素字节 → 本模块 → 写 FIFO），SDRAM 里永远是 640×480，
// 所以显示、缩略图、转场都不用改。
//
// 原版 thumbnail_layout 是“显示时按坐标去读源图”，需要随机访问 SDRAM；
// 本工程读写都是顺序突发，所以换成“加载时边收边缩”，先横向、再纵向（可分离双线性）：
//   - 横向：记住前一个源像素，输出列需要的两个源像素 x0、x0+1 都到了，就按小数部分 wx 混合，
//           每个源行先缩成 w_out 宽，写进行缓冲
//   - 纵向：行缓冲两行轮流用（上一源行 / 当前源行，都已横向缩好），每收完一个源行，
//           把需要这两行的输出行发出去，同一列两行按 wy 混合
//   - 像素中心对齐：源坐标 s = (2·dst+1)·S / (2·D) − 0.5，带 8 位小数，用增量法逐点累加，
//     像素通路里没有除法；超出边缘时取最边上的像素
//   - 混合：out = a + ((b − a)·w + 128) >> 8，四舍五入；尺寸正好 640×480 时权重全为 0，输出和原图逐点相同
//   - KEEP_ASPECT=1：保持宽高比，长边铺满，短边居中补黑边；=0：拉伸铺满（本工程用 0，任意尺寸都铺满屏幕）
//   - BMP 每行按 4 字节对齐，行尾填充字节在这里跳过
//   - 输出顺序和 BMP 一样自下而上，frame_fifo_write 的垂直翻转照常工作
// 大幅缩小（超过 2 倍）时双线性只看相邻 2×2 个点，细线仍可能断续，要彻底解决得用区域平均。
//
// 缓冲：2048 字节 FIFO，用量过半拉高 in_pause，流读器读完当前扇区（最多 512 字节）后暂停，
// 发行时停止取字节也不会丢数据。输出 6 拍一个像素（约 16.7M 像素/秒，一帧约 18ms），比读卡快得多。
// 最近邻旧版备份在 bmp_scaler_nn.v.bak。
// -----------------------------------------------------------------------------
module bmp_scaler #(
    parameter integer OUT_W       = 640,
    parameter integer OUT_H       = 480,
    parameter integer KEEP_ASPECT = 1,
    parameter integer FIFO_AW     = 11
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        clear,              // 1 = 回空闲、清缓冲（不在加载图片时一直为 1）
    input  wire        start,              // 文件头校验通过后的单拍脉冲
    input  wire [12:0] src_w,              // 1 ~ 4096
    input  wire [12:0] src_h,
    input  wire        in_valid,           // 像素区字节（含行尾填充）
    input  wire [7:0]  in_byte,
    output wire        in_pause,
    output reg         out_valid,
    output reg  [23:0] out_data,           // {R,G,B}
    output wire        done,               // 640×480 个像素已全部输出
    output reg         overflow            // 缓冲溢出（正常不会发生），上层按截断报错
);

localparam [3:0] S_IDLE  = 4'd0;
localparam [3:0] S_PREP  = 4'd1;   // 判断横图还是竖图
localparam [3:0] S_DIV   = 4'd2;   // 依次算 5 个除法：缩放后尺寸、水平/垂直的起点和步长
localparam [3:0] S_DIVW  = 4'd3;
localparam [3:0] S_SETUP = 4'd4;
localparam [3:0] S_BOT   = 4'd5;   // 底部黑边（BMP 先存最下面一行）
localparam [3:0] S_PIX   = 4'd6;   // 收 3 个字节拼一个像素
localparam [3:0] S_HCALC = 4'd13;  // 由当前输出列的源坐标算出要等哪个源像素、权重多少
localparam [3:0] S_HFILL = 4'd7;   // 横向混合，写行缓冲
localparam [3:0] S_PAD   = 4'd8;   // 跳过行尾填充
localparam [3:0] S_VCALC = 4'd14;  // 等横向流水线写完，算当前输出行要哪两行、权重多少
localparam [3:0] S_VCHK  = 4'd9;   // 发需要本源行的输出行
localparam [3:0] S_TOP   = 4'd10;  // 顶部黑边
localparam [3:0] S_EMW   = 4'd11;  // 等一行发完
localparam [3:0] S_DONE  = 4'd12;

reg [3:0] state;
reg [3:0] ret_st;
assign done = (state == S_DONE);

// ---------------- 字节 FIFO ----------------
localparam integer FDEPTH = 1 << FIFO_AW;
reg [7:0]       fmem [0:FDEPTH-1];
reg [FIFO_AW:0] wp, rp;
wire [FIFO_AW:0] used    = wp - rp;
wire             f_empty = (used == 0);
wire             f_full  = used[FIFO_AW];
assign in_pause = used[FIFO_AW] | used[FIFO_AW-1];

wire want_byte = (state == S_PIX) || (state == S_PAD);
reg  f_vld;
reg  [7:0] f_q;
wire f_rd = want_byte && !f_empty && !f_vld;      // 2 拍取一个字节，远快于 SD 卡

always @(posedge clk) begin
    if (in_valid && !f_full)
        fmem[wp[FIFO_AW-1:0]] <= in_byte;
    if (f_rd)
        f_q <= fmem[rp[FIFO_AW-1:0]];
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wp       <= 0;
        rp       <= 0;
        f_vld    <= 1'b0;
        overflow <= 1'b0;
    end else if (clear) begin
        wp       <= 0;
        rp       <= 0;
        f_vld    <= 1'b0;
        overflow <= 1'b0;
    end else begin
        if (in_valid) begin
            if (f_full) overflow <= 1'b1;
            else        wp <= wp + 1'b1;
        end
        if (f_rd)
            rp <= rp + 1'b1;
        f_vld <= f_rd;
    end
end

// ---------------- 顺序除法器（24 位 / 14 位，24 拍） ----------------
reg         dv_go;
reg  [23:0] dv_num;
reg  [13:0] dv_den;
reg  [23:0] dv_q;
reg  [14:0] dv_r;
reg  [4:0]  dv_cnt;
reg         dv_busy;
wire [14:0] dv_sh = {dv_r[13:0], dv_q[23]};
wire        dv_ge = (dv_sh >= {1'b0, dv_den});

always @(posedge clk or posedge rst) begin
    if (rst) begin
        dv_q    <= 24'd0;
        dv_r    <= 15'd0;
        dv_cnt  <= 5'd0;
        dv_busy <= 1'b0;
    end else if (clear) begin
        dv_busy <= 1'b0;
    end else if (dv_go) begin
        dv_q    <= dv_num;
        dv_r    <= 15'd0;
        dv_cnt  <= 5'd24;
        dv_busy <= 1'b1;
    end else if (dv_busy) begin
        dv_r    <= dv_ge ? (dv_sh - {1'b0, dv_den}) : dv_sh;
        dv_q    <= {dv_q[22:0], dv_ge};
        dv_cnt  <= dv_cnt - 5'd1;
        if (dv_cnt == 5'd1)
            dv_busy <= 1'b0;
    end
end

wire [21:0] dv_quo = dv_q[21:0];        // 坐标带 8 位小数，最大约 4096×256
wire [13:0] dv_rem = dv_r[13:0];

// ---------------- 一维线性混合：a + ((b − a)·w + 128) >> 8 ----------------
// 分三级：先减（b − a），再乘（乘法器输入输出都打寄存器），最后加，每级都很短，100MHz 下有余量
function signed [8:0] lerp_sub;         // b − a
    input [7:0] a;
    input [7:0] b;
    begin
        lerp_sub = $signed({1'b0, b}) - $signed({1'b0, a});
    end
endfunction

function signed [17:0] lerp_mul;        // (b − a)·w
    input signed [8:0] d;
    input [7:0]        w;
    begin
        lerp_mul = d * $signed({1'b0, w});
    end
endfunction

function [7:0] lerp_add;                // a + round(prod / 256)，结果一定在 a、b 之间，不会越界
    input [7:0]         a;
    input signed [17:0] p;
    reg   signed [17:0] t;
    begin
        t        = (p + 18'sd128) >>> 8;
        lerp_add = a + t[7:0];
    end
endfunction

// ---------------- 坐标 → 要等的源像素、权重 ----------------
// t = 中心对齐坐标 + 0.5（8 位小数，≥ 0），s = t − 0.5 才是真正的源坐标
//   s < 0       ：在第一个像素左边，取第 0 个像素，等第 0 个
//   s ≥ N − 1   ：在最后一个像素右边，取第 N−1 个，等第 N−1 个
//   其余        ：混合第 x0 和 x0+1 个，等第 x0+1 个到了再算（此时第 x0 个在“前一个”里）
reg [21:0] qx, qy;                      // 当前输出列 / 输出行的 t（整数.8 位小数）
reg [13:0] rx, ry;                      // 增量法的余数
reg [12:0] W, H;
reg [13:0] W_m1, H_m1;                  // 【时序收敛】W−1、H−1 在 start 时算好，比较时不再现算减法

wire        hx_neg  = (qx < 22'd128);
wire [21:0] hx_s    = qx - 22'd128;
wire        hx_last = (hx_s[21:8] >= W_m1);

wire        vy_neg  = (qy < 22'd128);
wire [21:0] vy_s    = qy - 22'd128;
wire        vy_last = (vy_s[21:8] >= H_m1);

reg [12:0] hneed, vneed;                // 等到第几个源像素 / 源行
reg [7:0]  hw, vw;                      // 权重
reg        huse, vuse;                  // 1 = 混合“前一个”和“当前”，0 = 只用“当前”

// ---------------- 行缓冲：两行横向缩好的像素，按源行号奇偶轮流写 ----------------
reg [23:0] lb0 [0:OUT_W-1];
reg [23:0] lb1 [0:OUT_W-1];
reg [9:0]  lb_ra;
reg [23:0] lb_q0, lb_q1;

// 横向混合流水线：第 1 级锁存 a、差值 b−a 和权重，第 2 级乘，第 3 级加并写行缓冲
reg        h1_v, h2_v;
reg [9:0]  h1_u, h2_u;
reg [23:0] h1_a;
reg signed [8:0] h1_dr, h1_dg, h1_db;
reg [7:0]  h1_w;
reg [23:0] h2_a;
reg signed [17:0] h2_pr, h2_pg, h2_pb;
reg        h_sel;                       // 写哪一行缓冲（= 当前源行号的最低位）

wire [23:0] h_res = {lerp_add(h2_a[23:16], h2_pr),
                     lerp_add(h2_a[15:8],  h2_pg),
                     lerp_add(h2_a[7:0],   h2_pb)};

always @(posedge clk) begin
    if (h2_v && !h_sel) lb0[h2_u] <= h_res;
    if (h2_v &&  h_sel) lb1[h2_u] <= h_res;
    lb_q0 <= lb0[lb_ra];
    lb_q1 <= lb1[lb_ra];
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        h2_v  <= 1'b0;
        h2_u  <= 10'd0;
        h2_a  <= 24'd0;
        h2_pr <= 18'sd0;
        h2_pg <= 18'sd0;
        h2_pb <= 18'sd0;
    end else begin
        h2_v  <= h1_v;
        h2_u  <= h1_u;
        h2_a  <= h1_a;
        h2_pr <= lerp_mul(h1_dr, h1_w);
        h2_pg <= lerp_mul(h1_dg, h1_w);
        h2_pb <= lerp_mul(h1_db, h1_w);
    end
end

// ---------------- 主状态机 ----------------
reg [21:0] pw, ph;                  // W*OUT_H, H*OUT_W
reg        wide;                    // 比 4:3 更宽：宽度铺满
reg [9:0]  w_out, h_out;            // 缩放后图像尺寸
reg [9:0]  x0, yb;                  // 左侧黑边宽、底部黑边行数
reg [2:0]  dsel;
reg [21:0] qx0, qxs, qy0, qys;      // 起点和步长（商，带 8 位小数）
reg [13:0] rx0, rxs, ry0, rys;      // 余数
reg [9:0]  u, v;                    // 当前输出列 / 输出行
reg [12:0] x, y;                    // 当前源像素列 / 源行
reg [1:0]  bcnt;
reg [1:0]  pad_cnt;
reg [23:0] pix;                     // 当前源像素
reg [23:0] pix_prev;                // 同一行的前一个源像素
reg [9:0]  rows;                    // 已发出的输出行（含黑边）

reg        em_go;
reg        em_busy;
reg        em_black;
reg        em_use;                  // 本输出行：1 = 混合上一行和当前行，0 = 只用当前行
reg [7:0]  em_w;

wire [10:0] den_x = {w_out, 1'b0};
wire [10:0] den_y = {h_out, 1'b0};
wire [14:0] rx_sum  = {1'b0, rx} + {1'b0, rxs};
wire        rx_wrap = (rx_sum >= {4'd0, den_x});
wire [14:0] ry_sum  = {1'b0, ry} + {1'b0, rys};
wire        ry_wrap = (ry_sum >= {4'd0, den_y});

wire hit_x = (u < w_out) && (hneed == x);
wire [23:0] h_a = huse ? pix_prev : pix;    // 混合的左端：前一个源像素（或边缘处就是当前像素）
wire hit_y = (v < h_out) && (vneed == y);

wire [13:0] q_clamp = (dv_q[13:0] == 14'd0) ? 14'd1 : dv_q[13:0];

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state    <= S_IDLE;
        ret_st   <= S_IDLE;
        W        <= 13'd0;
        H        <= 13'd0;
        W_m1     <= 14'h3FFF;
        H_m1     <= 14'h3FFF;
        pw       <= 22'd0;
        ph       <= 22'd0;
        wide     <= 1'b0;
        w_out    <= OUT_W;
        h_out    <= OUT_H;
        x0       <= 10'd0;
        yb       <= 10'd0;
        dsel     <= 3'd0;
        qx0 <= 22'd0; rx0 <= 14'd0; qxs <= 22'd0; rxs <= 14'd0;
        qy0 <= 22'd0; ry0 <= 14'd0; qys <= 22'd0; rys <= 14'd0;
        qx  <= 22'd0; rx  <= 14'd0; qy  <= 22'd0; ry  <= 14'd0;
        hneed    <= 13'd0;
        vneed    <= 13'd0;
        hw       <= 8'd0;
        vw       <= 8'd0;
        huse     <= 1'b0;
        vuse     <= 1'b0;
        u        <= 10'd0;
        v        <= 10'd0;
        x        <= 13'd0;
        y        <= 13'd0;
        bcnt     <= 2'd0;
        pad_cnt  <= 2'd0;
        pix      <= 24'd0;
        pix_prev <= 24'd0;
        rows     <= 10'd0;
        dv_go    <= 1'b0;
        dv_num   <= 24'd0;
        dv_den   <= 14'd1;
        em_go    <= 1'b0;
        em_black <= 1'b1;
        em_use   <= 1'b0;
        em_w     <= 8'd0;
        h1_v     <= 1'b0;
        h1_u     <= 10'd0;
        h1_a     <= 24'd0;
        h1_dr    <= 9'sd0;
        h1_dg    <= 9'sd0;
        h1_db    <= 9'sd0;
        h1_w     <= 8'd0;
        h_sel    <= 1'b0;
    end else if (clear) begin
        state <= S_IDLE;
        dv_go <= 1'b0;
        em_go <= 1'b0;
        h1_v  <= 1'b0;
    end else begin
        dv_go <= 1'b0;
        em_go <= 1'b0;
        h1_v  <= 1'b0;
        case (state)
            S_IDLE: begin
                if (start) begin
                    W     <= src_w;
                    H     <= src_h;
                    W_m1  <= {1'b0, src_w} - 14'd1;
                    H_m1  <= {1'b0, src_h} - 14'd1;
                    pw    <= src_w * OUT_H;
                    ph    <= src_h * OUT_W;
                    state <= S_PREP;
                end
            end

            S_PREP: begin
                wide <= (pw >= ph);
                if (KEEP_ASPECT != 0) begin
                    dsel <= 3'd0;
                end else begin
                    w_out <= OUT_W;
                    h_out <= OUT_H;
                    dsel  <= 3'd1;
                end
                state <= S_DIV;
            end

            S_DIV: begin
                case (dsel)
                    3'd0: begin   // 短边长度 = 四舍五入(短边 × 长边目标 / 长边)
                        dv_num <= wide ? ({2'd0, ph} + W[12:1]) : ({2'd0, pw} + H[12:1]);
                        dv_den <= wide ? {1'b0, W} : {1'b0, H};
                    end
                    // 起点 t0 = S·256 / (2D)，步长 = 2S·256 / (2D)（都带 8 位小数）
                    3'd1: begin dv_num <= {3'd0, W, 8'd0}; dv_den <= {3'd0, den_x}; end
                    3'd2: begin dv_num <= {2'd0, W, 9'd0}; dv_den <= {3'd0, den_x}; end
                    3'd3: begin dv_num <= {3'd0, H, 8'd0}; dv_den <= {3'd0, den_y}; end
                    default: begin dv_num <= {2'd0, H, 9'd0}; dv_den <= {3'd0, den_y}; end
                endcase
                dv_go <= 1'b1;
                state <= S_DIVW;
            end

            S_DIVW: begin
                if (!dv_go && !dv_busy) begin
                    case (dsel)
                        3'd0: begin
                            if (wide) begin
                                w_out <= OUT_W;
                                h_out <= (q_clamp > OUT_H) ? OUT_H : q_clamp[9:0];
                            end else begin
                                h_out <= OUT_H;
                                w_out <= (q_clamp > OUT_W) ? OUT_W : q_clamp[9:0];
                            end
                        end
                        3'd1: begin qx0 <= dv_quo; rx0 <= dv_rem; end
                        3'd2: begin qxs <= dv_quo; rxs <= dv_rem; end
                        3'd3: begin qy0 <= dv_quo; ry0 <= dv_rem; end
                        default: begin qys <= dv_quo; rys <= dv_rem; end
                    endcase
                    dsel  <= dsel + 3'd1;
                    state <= (dsel == 3'd4) ? S_SETUP : S_DIV;
                end
            end

            S_SETUP: begin
                x0    <= (OUT_W - w_out) >> 1;
                yb    <= (OUT_H - h_out) - ((OUT_H - h_out) >> 1);
                qy    <= qy0;
                ry    <= ry0;
                v     <= 10'd0;
                y     <= 13'd0;
                x     <= 13'd0;
                u     <= 10'd0;
                qx    <= qx0;
                rx    <= rx0;
                bcnt  <= 2'd0;
                rows  <= 10'd0;
                state <= S_BOT;
            end

            S_BOT: begin
                if (rows < yb) begin
                    em_go    <= 1'b1;
                    em_black <= 1'b1;
                    rows     <= rows + 10'd1;
                    ret_st   <= S_BOT;
                    state    <= S_EMW;
                end else begin
                    state <= S_PIX;
                end
            end

            S_PIX: begin
                if (f_vld) begin
                    case (bcnt)
                        2'd0: begin pix[7:0]   <= f_q; bcnt <= 2'd1; end   // B
                        2'd1: begin pix[15:8]  <= f_q; bcnt <= 2'd2; end   // G
                        default: begin
                            pix[23:16] <= f_q;                              // R
                            bcnt       <= 2'd0;
                            state      <= S_HCALC;
                        end
                    endcase
                end
            end

            S_HCALC: begin
                hneed <= hx_neg ? 13'd0 : hx_last ? W_m1[12:0] : (hx_s[20:8] + 13'd1);
                hw    <= (hx_neg || hx_last) ? 8'd0 : hx_s[7:0];
                huse  <= !hx_neg && !hx_last;
                state <= S_HFILL;
            end

            S_HFILL: begin
                if (hit_x) begin
                    // 本源像素到了，输出列 u 可以算了；放大时同一个源像素会连续对应多列
                    h1_v  <= 1'b1;
                    h1_u  <= u;
                    h1_a  <= h_a;
                    h1_dr <= lerp_sub(h_a[23:16], pix[23:16]);
                    h1_dg <= lerp_sub(h_a[15:8],  pix[15:8]);
                    h1_db <= lerp_sub(h_a[7:0],   pix[7:0]);
                    h1_w  <= hw;
                    h_sel <= y[0];
                    u     <= u + 10'd1;
                    qx    <= qx + qxs + rx_wrap;
                    rx    <= rx_wrap ? (rx_sum[13:0] - {3'd0, den_x}) : rx_sum[13:0];
                    state <= S_HCALC;
                end else if (x == W_m1[12:0]) begin   // 【时序 t5】用 start 时算好的 W−1
                    pad_cnt <= W[1:0];               // 行字节数 3W 补到 4 的倍数，需要补 W%4 个
                    state   <= (W[1:0] == 2'd0) ? S_VCALC : S_PAD;
                end else begin
                    pix_prev <= pix;
                    x        <= x + 13'd1;
                    state    <= S_PIX;
                end
            end

            S_PAD: begin
                if (f_vld) begin
                    pad_cnt <= pad_cnt - 2'd1;
                    if (pad_cnt == 2'd1)
                        state <= S_VCALC;
                end
            end

            S_VCALC: begin
                // 横向流水线还有没写进行缓冲的像素，先等它写完
                if (!h1_v && !h2_v) begin
                    vneed <= vy_neg ? 13'd0 : vy_last ? H_m1[12:0] : (vy_s[20:8] + 13'd1);
                    vw    <= (vy_neg || vy_last) ? 8'd0 : vy_s[7:0];
                    vuse  <= !vy_neg && !vy_last;
                    state <= S_VCHK;
                end
            end

            S_VCHK: begin
                if (hit_y) begin
                    em_go    <= 1'b1;
                    em_black <= 1'b0;
                    em_use   <= vuse;
                    em_w     <= vw;
                    rows     <= rows + 10'd1;
                    v        <= v + 10'd1;
                    qy       <= qy + qys + ry_wrap;
                    ry       <= ry_wrap ? (ry_sum[13:0] - {3'd0, den_y}) : ry_sum[13:0];
                    ret_st   <= S_VCALC;
                    state    <= S_EMW;
                end else if (y == H_m1[12:0]) begin   // 【时序 t5】用 start 时算好的 H−1
                    state <= S_TOP;
                end else begin
                    y     <= y + 13'd1;
                    x     <= 13'd0;
                    u     <= 10'd0;
                    qx    <= qx0;
                    rx    <= rx0;
                    bcnt  <= 2'd0;
                    state <= S_PIX;
                end
            end

            S_TOP: begin
                if (rows < OUT_H) begin
                    em_go    <= 1'b1;
                    em_black <= 1'b1;
                    rows     <= rows + 10'd1;
                    ret_st   <= S_TOP;
                    state    <= S_EMW;
                end else begin
                    state <= S_DONE;
                end
            end

            S_EMW: begin
                if (!em_go && !em_busy)
                    state <= ret_st;
            end

            S_DONE: ;

            default: state <= S_IDLE;
        endcase
    end
end

// ---------------- 发一行：左黑边 + 纵向混合两行缓冲 + 右黑边，6 拍一个像素 ----------------
// 第 0 拍给读地址，第 2 拍两行数据到了、选出 a/b，第 3 拍减，第 4 拍乘，第 5 拍加完输出
reg [9:0]  em_x;
reg [2:0]  em_ph;
reg        em_in;
reg [23:0] e_a, e_b;
reg signed [8:0]  e_dr, e_dg, e_db;
reg signed [17:0] e_pr, e_pg, e_pb;
wire [9:0] x1 = x0 + w_out;

wire [23:0] lb_cur  = y[0] ? lb_q1 : lb_q0;     // 当前源行
wire [23:0] lb_prev = y[0] ? lb_q0 : lb_q1;     // 上一源行

always @(posedge clk or posedge rst) begin
    if (rst) begin
        em_busy   <= 1'b0;
        em_x      <= 10'd0;
        em_ph     <= 3'd0;
        em_in     <= 1'b0;
        lb_ra     <= 10'd0;
        e_a       <= 24'd0;
        e_b       <= 24'd0;
        e_dr      <= 9'sd0;
        e_dg      <= 9'sd0;
        e_db      <= 9'sd0;
        e_pr      <= 18'sd0;
        e_pg      <= 18'sd0;
        e_pb      <= 18'sd0;
        out_valid <= 1'b0;
        out_data  <= 24'd0;
    end else if (clear) begin
        em_busy   <= 1'b0;
        out_valid <= 1'b0;
    end else begin
        out_valid <= 1'b0;
        if (em_go) begin
            em_busy <= 1'b1;
            em_x    <= 10'd0;
            em_ph   <= 3'd0;
        end else if (em_busy) begin
            em_ph <= (em_ph == 3'd5) ? 3'd0 : (em_ph + 3'd1);
            case (em_ph)
                3'd0: begin
                    lb_ra <= em_x - x0;
                    em_in <= !em_black && (em_x >= x0) && (em_x < x1);
                end
                3'd2: begin
                    e_a <= em_use ? lb_prev : lb_cur;
                    e_b <= lb_cur;
                end
                3'd3: begin
                    e_dr <= lerp_sub(e_a[23:16], e_b[23:16]);
                    e_dg <= lerp_sub(e_a[15:8],  e_b[15:8]);
                    e_db <= lerp_sub(e_a[7:0],   e_b[7:0]);
                end
                3'd4: begin
                    e_pr <= lerp_mul(e_dr, em_w);
                    e_pg <= lerp_mul(e_dg, em_w);
                    e_pb <= lerp_mul(e_db, em_w);
                end
                3'd5: begin
                    out_valid <= 1'b1;
                    out_data  <= em_in ? {lerp_add(e_a[23:16], e_pr),
                                          lerp_add(e_a[15:8],  e_pg),
                                          lerp_add(e_a[7:0],   e_pb)} : 24'd0;
                    if (em_x == OUT_W - 1)
                        em_busy <= 1'b0;
                    else
                        em_x <= em_x + 10'd1;
                end
                default: ;
            endcase
        end
    end
end

endmodule
