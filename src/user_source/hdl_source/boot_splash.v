`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// 【开机画面】开机自检页 / 【内置安全页】/ 【拔卡提示】：插在 video_transition 和 emergency_overlay 之间
// （应急页优先级更高）。三种画面共用一个字库 ROM（splash_rom，BRAM32K）：
//
// ① 开机自检页：上电到自检完成之前整屏画：深蓝渐变底 + 大标题 + 中英文副标题 + 自检清单 + 底部状态
//   自检清单 7 项（显示通道 / 参数存储 / 存储卡 / 背景音乐 / 节目画面 / 应急画面 / 【串口指令】字库），
//   每项的结果都来自真实状态（sd_card_bmp4 的 boot_info），绿 = 正常，黄 = 有问题但能用，红 = 不能用：
//     等待中转圈，有结果打勾 / 警告 / 叉；节目画面一项实时显示“载好几张 / 共几张”
//   逐行出现：上电约 2.5 秒出第一行（这台显示器认信号要 2~3 秒），
//     前一项有结果、并且离上一行至少 0.4 秒，才出下一行 —— 只控制出现的节奏，结果不造假
//   7 项都有结果后停 1 秒，boot_done=1：开机画面在帧头关掉，video_transition 照常黑 2 帧再淡入第一张图
//   上电 12 秒还没自检完（比如应急页载得慢）但已经有图，也直接进入
//   出错：没插卡 → 存储卡一项转圈 + “插入后将自动载入”（插卡后自动继续，不用按键）；
//         没有图 / 全部载不进来 → 底部红字说明原因，要长按 Key1 重启
//   换了一张卡（sd_card_bmp4 清掉旧节目，display_valid 变 0）：从头再走一遍自检
// ② 内置安全页：开机时出了致命问题（没插卡 / 没有图 / 图都载不进来）超过 10 秒，
//   自检页换成一页 FPGA 内置的安全提示（绿色底，消防 / 疏散 / 急救电话），底部仍写着出错原因；
//   问题消失（比如插上了卡）就回到自检页 —— 卡坏了，屏照样有用
// ③ 拔卡提示：已经在放节目时卡被拔掉，右上角显示黄色小框“存储卡已移除，节目照常播放”，
//   插回恢复后变绿色“存储卡已恢复”，3 秒后消失；应急模式下不显示。位置在状态条 / 参数条下面，
//   和下方的波形、字幕都不重叠；不受 SW4 控制（这是给维护人员看的故障提示）
// ④ 【串口通知】串口收到认证不通过 / 重放的指令（notice_uart 的 reject），同一位置显示红色小框
//   “非法指令已拒绝”3 秒，优先于拔卡提示；应急模式下同样不显示
// 文字点阵在 splash_rom（subtitle/gen_splash.ps1 从 splash.txt 生成），这里不存字库。
// 纯组合叠加，不增加视频延迟。sd_card_clk 域的输入在这里打拍同步，连续两拍相同才用。
// -----------------------------------------------------------------------------
module boot_splash #(
    parameter integer FIRST_FRAMES  = 150,      // 上电约 2.5 秒出第一行
    parameter integer STEP_FRAMES   = 24,       // 每行至少隔 0.4 秒
    parameter integer HOLD_FRAMES   = 60,       // 全部有结果后停 1 秒
    parameter integer MAX_FRAMES    = 720,      // 上电 12 秒，有图就进入
    parameter integer NOCARD_FRAMES = 180,      // 3 秒还没初始化完 TF 卡，提示没插卡
    parameter integer SAFE_FRAMES   = 600,      // 【内置安全页】致命问题持续 10 秒
    parameter integer BACK_FRAMES   = 180,      // 【拔卡提示】“已恢复”显示 3 秒
    parameter integer REJ_FRAMES    = 180       // 【串口通知】“非法指令已拒绝”显示 3 秒
)(
    input  wire        clk,                     // video_clk
    input  wire        rst_n,
    input  wire        vs,                      // 低有效
    input  wire        de,
    input  wire [23:0] rgb_in,
    // 以下来自 sd_card_clk 域
    input  wire        display_valid,           // 第一张图已载好
    input  wire [21:0] boot_info,               // 自检状态，格式见 sd_card_bmp4 文件末尾
    input  wire [3:0]  err_code,
    // video_clk 域
    input  wire        alert,                   // 【拔卡提示】应急模式（SW1）：不显示提示框
    input  wire        reject,                  // 【串口通知】单拍：拒绝了一条非法指令
    output wire [23:0] rgb_out,
    output reg         splash_on,               // 1 = 正在显示开机画面（自检页或安全页）
    output reg         boot_done                // 1 = 自检完成，可以显示图片（给 video_transition）
);

// ---------------- 版面：开机自检页 ----------------
localparam integer Y_TITLE = 56;                // 标题 48 行
localparam integer Y_SUBCN = 114;
localparam integer Y_SUBEN = 134;
localparam integer Y_LINE  = 160;               // 副标题下面的细线
localparam integer LINE_X0 = 200, LINE_X1 = 440;
localparam integer Y_HEAD  = 178;               // “系统自检”
localparam integer Y_ROW0  = 206;               // 第一项，每项 26 行
localparam integer ROW_H   = 22;                // 【串口指令】7 项，行距从 26 改成 22
localparam integer Y_STCN  = 378;               // 底部状态
localparam integer Y_STEN  = 400;
localparam integer ICON_X  = 128;               // 图标 16 列
localparam integer LABEL_X = 152;               // 项目名
localparam integer RES_X   = 320;               // 结果（节目画面一项先画 “2/4” 3 格，结果从 RES_X+32 开始）
localparam integer PANEL_X0 = 112, PANEL_X1 = 544, PANEL_Y0 = 170, PANEL_Y1 = 362;
// ---------------- 版面：内置安全页 ----------------
localparam integer S_TITLE = 40;
localparam integer S_SUB   = 96;
localparam integer S_LINE  = 124;
localparam integer S_ROW0  = 150;               // 每项中文一行、英文一行，间隔 48 行
localparam integer S_ROW_H = 48;
localparam integer S_ICON_X = 104;
localparam integer S_TEXT_X = 128;
localparam integer S_PX0 = 72, S_PX1 = 568, S_PY0 = 136, S_PY1 = 346;
localparam integer S_LINE2 = 356;
localparam integer S_NOTE  = 364;
localparam integer S_STCN  = 386;
localparam integer S_STEN  = 406;
// ---------------- 版面：拔卡提示框（右上角，状态条 / 参数条下面） ----------------
localparam integer B_X1  = 632;                 // 右边界（不含）
localparam integer B_Y0  = 32, B_Y1 = 72;
localparam integer B_YCN = 36, B_YEN = 54;

// ---------------- 字符串编号（和 splash_rom 文件头一致，由 gen_splash.ps1 固定） ----------------
localparam [6:0] SID_SUBCN = 7'd3,  SID_SUBEN = 7'd4,  SID_DIGITS = 7'd5, SID_ICONS = 7'd6, SID_HEAD = 7'd7;
localparam [6:0] SID_LABEL0 = 7'd8;                                   // 8~13 六个项目名
localparam [6:0] SID_DISP_OK  = 7'd14;
localparam [6:0] SID_SET_WAIT = 7'd15, SID_SET_OK  = 7'd16, SID_SET_DEF = 7'd17, SID_SET_ERR = 7'd18;
localparam [6:0] SID_CARD_WAIT= 7'd19, SID_CARD_NO = 7'd20, SID_CARD_OK = 7'd21, SID_CARD_ERR = 7'd22;
localparam [6:0] SID_MUS_OK   = 7'd23, SID_MUS_NO  = 7'd24;
localparam [6:0] SID_PIC_WAIT = 7'd25, SID_PIC_OK  = 7'd26, SID_PIC_PART = 7'd27, SID_PIC_ERR = 7'd28;
localparam [6:0] SID_EMG_WAIT = 7'd29, SID_EMG_OK  = 7'd30, SID_EMG_NO  = 7'd31, SID_EMG_ERR = 7'd32;
localparam [6:0] SID_CHECK  = 7'd33, SID_DONE = 7'd35, SID_NOCARD = 7'd37,   // 底部状态：中文 n，英文 n+1
                 SID_FS     = 7'd39, SID_FMT  = 7'd41, SID_READ   = 7'd43;
localparam [6:0] SID_SAFE_T0 = 7'd45, SID_SAFE_SUB = 7'd48, SID_S1 = 7'd49,  // S1~S4：中文 49+2k，英文 50+2k
                 SID_SAFE_NOTE = 7'd57;
localparam [6:0] SID_LOST = 7'd58, SID_BACK = 7'd60, SID_REJ = 7'd62;        // 中文 n，英文 n+1
localparam [6:0] SID_LABEL6 = 7'd64, SID_FONT_OK = 7'd65, SID_FONT_NO = 7'd66, SID_FONT_ERR = 7'd67;   // 【串口指令】第 7 项 字库
localparam [3:0] IC_OK = 4'd0, IC_WARN = 4'd1, IC_FAIL = 4'd2, IC_SPIN = 4'd3, IC_FIRE = 4'd7;   // 7~10 安全页四个图标

localparam [1:0] ST_WAIT = 2'd0, ST_OK = 2'd1, ST_WARN = 2'd2, ST_FAIL = 2'd3;
localparam [1:0] P_NONE = 2'd0, P_CHECK = 2'd1, P_SAFE = 2'd2, P_BADGE = 2'd3;

// ---------------- 跨时钟域：三拍，连续两拍相同才更新 ----------------
reg [26:0] s1, s2, s3;
reg [1:0]  font_s;                  // 【串口指令】字库：0 检查中 1 已安装 2 未安装 3 Flash 不可用
reg        valid_s, miss_s, init_s, scan_s, mus_s, ef_s, eok_s, efail_s;
reg [2:0]  n_s, ld_s, pr_s;
reg [3:0]  ps_s, err_s;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s1 <= 27'd0; s2 <= 27'd0; s3 <= 27'd0;
        {valid_s, font_s, miss_s, init_s, scan_s, n_s, ld_s, pr_s, mus_s, ef_s, eok_s, efail_s, ps_s, err_s} <= 27'd0;
    end else begin
        s1 <= {display_valid, boot_info, err_code};
        s2 <= s1;
        s3 <= s2;
        if (s2 == s3)
            {valid_s, font_s, miss_s, init_s, scan_s, n_s, ld_s, pr_s, mus_s, ef_s, eok_s, efail_s, ps_s, err_s} <= s3;
    end
end

// ---------------- 坐标 ----------------
reg vs_d, de_d;
reg [9:0] x_cnt, y_cnt;
wire frame_start = vs_d & ~vs;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        vs_d  <= 1'b1;
        de_d  <= 1'b0;
        x_cnt <= 10'd0;
        y_cnt <= 10'd0;
    end else begin
        vs_d  <= vs;
        de_d  <= de;
        x_cnt <= de ? (x_cnt + 10'd1) : 10'd0;
        if (frame_start)
            y_cnt <= 10'd0;
        else if (de_d && !de)
            y_cnt <= y_cnt + 10'd1;
    end
end
wire [9:0] px = de ? x_cnt : 10'd0;

// ---------------- 每一项的结果（组合，帧头锁存） ----------------
reg  [9:0]  fcnt;                   // 上电（或重新开始自检）后的帧数，到 1023 停
reg  [3:0]  anim;                   // 转圈动画
wire        nocard = !init_s && (fcnt >= NOCARD_FRAMES);
reg  [13:0] e_st;                   // 7 项 × 2 位状态
reg  [48:0] e_sid;                  // 7 项 × 结果字符串（7 位编号）
always @(*) begin
    // 0 显示通道：能看到这一页就说明正常
    e_st[1:0] = ST_OK;   e_sid[6:0] = SID_DISP_OK;
    // 1 参数存储（param_store 状态：0 启动中 1 已载入 2 默认值 3/5 保存过 E/F 出错）
    case (ps_s)
        4'h0:       begin e_st[3:2] = ST_WAIT; e_sid[13:7] = SID_SET_WAIT; end
        4'h2:       begin e_st[3:2] = ST_OK;   e_sid[13:7] = SID_SET_DEF;  end
        4'hE, 4'hF: begin e_st[3:2] = ST_WARN; e_sid[13:7] = SID_SET_ERR;  end
        default:    begin e_st[3:2] = ST_OK;   e_sid[13:7] = SID_SET_OK;   end
    endcase
    // 2 存储卡
    if (!init_s)          begin e_st[5:4] = ST_WAIT; e_sid[20:14] = nocard ? SID_CARD_NO : SID_CARD_WAIT; end
    else if (!scan_s)     begin e_st[5:4] = ST_WAIT; e_sid[20:14] = SID_CARD_WAIT; end
    else if (n_s == 3'd0) begin e_st[5:4] = ST_FAIL; e_sid[20:14] = SID_CARD_ERR;  end
    else                  begin e_st[5:4] = ST_OK;   e_sid[20:14] = SID_CARD_OK;   end
    // 3 背景音乐
    if (!scan_s)          begin e_st[7:6] = ST_WAIT; e_sid[27:21] = SID_CARD_WAIT; end
    else if (mus_s)       begin e_st[7:6] = ST_OK;   e_sid[27:21] = SID_MUS_OK;    end
    else                  begin e_st[7:6] = ST_WARN; e_sid[27:21] = SID_MUS_NO;    end
    // 4 节目画面
    if (!scan_s || (pr_s < n_s)) begin e_st[9:8] = ST_WAIT; e_sid[34:28] = SID_PIC_WAIT; end
    else if (ld_s == n_s)        begin e_st[9:8] = ST_OK;   e_sid[34:28] = SID_PIC_OK;   end
    else if (ld_s == 3'd0)       begin e_st[9:8] = ST_FAIL; e_sid[34:28] = SID_PIC_ERR;  end
    else                         begin e_st[9:8] = ST_WARN; e_sid[34:28] = SID_PIC_PART; end
    // 5 应急画面（没有 EMERG.BMP 时应急模式用 FPGA 内置警示页，所以是“黄”不是“红”）
    if (!scan_s)          begin e_st[11:10] = ST_WAIT; e_sid[41:35] = SID_EMG_WAIT; end
    else if (!ef_s)       begin e_st[11:10] = ST_WARN; e_sid[41:35] = SID_EMG_NO;   end
    else if (eok_s)       begin e_st[11:10] = ST_OK;   e_sid[41:35] = SID_EMG_OK;   end
    else if (efail_s)     begin e_st[11:10] = ST_WARN; e_sid[41:35] = SID_EMG_ERR;  end
    else                  begin e_st[11:10] = ST_WAIT; e_sid[41:35] = SID_EMG_WAIT; end
    // 6 【串口指令】字库（没装只影响串口通知，所以是“黄”）
    case (font_s)
        2'd0:    begin e_st[13:12] = ST_WAIT; e_sid[48:42] = SID_SET_WAIT;  end
        2'd1:    begin e_st[13:12] = ST_OK;   e_sid[48:42] = SID_FONT_OK;   end
        2'd2:    begin e_st[13:12] = ST_WARN; e_sid[48:42] = SID_FONT_NO;   end
        default: begin e_st[13:12] = ST_WARN; e_sid[48:42] = SID_FONT_ERR;  end
    endcase
end
// 有结果且能用（正常或警告）
wire [6:0] res_ok = {^e_st[13:12], ^e_st[11:10], ^e_st[9:8], ^e_st[7:6], ^e_st[5:4], ^e_st[3:2], ^e_st[1:0]};

// 底部状态
wire fs_fail  = init_s && scan_s && (n_s == 3'd0);                                // 没有图
wire pic_fail = scan_s && (n_s != 3'd0) && (pr_s >= n_s) && (ld_s == 3'd0);       // 有图但一张都载不进来
wire fatal    = nocard || fs_fail || pic_fail;
function [6:0] err_msg;
    input [3:0] e;
    input       no_pic;
    begin
        case (e)
            4'd4, 4'd7, 4'd8: err_msg = SID_FS;     // 没有 PIC1~4.BMP / 没有 55AA / 不是 FAT32
            4'd1, 4'd3:       err_msg = SID_FMT;    // BMP 头不对 / 像素不够
            4'd2, 4'd5:       err_msg = SID_READ;   // 读扇区超时 / FAT 链出错
            default:          err_msg = no_pic ? SID_FS : SID_READ;
        endcase
    end
endfunction

// ---------------- 帧头：逐行出现、什么时候结束、显示哪一页 ----------------
reg  [2:0]  reveal;                 // 已经出现了几项
reg  [5:0]  gap;
reg  [6:0]  hold;
reg  [13:0] st_q;
reg  [48:0] sid_q;
reg  [2:0]  ld_q, n_q;
reg  [6:0]  msg_q;
reg  [1:0]  msg_kind;               // 0 进行中 1 完成 2 出错
reg  [9:0]  fatal_cnt;              // 【内置安全页】致命问题持续了几帧
reg         valid_q, init_q, miss_q;
reg  [7:0]  back_cnt;               // 【拔卡提示】“已恢复”还要显示几帧
reg  [1:0]  page;                   // 这一帧画哪一页
localparam [1:0] BK_LOST = 2'd0, BK_BACK = 2'd1, BK_REJ = 2'd2;
reg  [1:0]  b_kind;                 // 提示框：已移除（黄） / 已恢复（绿） / 非法指令（红）
wire        b_lost = (b_kind == BK_LOST);
wire        b_rej  = (b_kind == BK_REJ);
reg         rej_req;                // 【串口通知】收到 reject，等帧头处理
reg  [7:0]  rej_cnt;                // 还要显示几帧
reg  [9:0]  b_x0;                   // 提示框左边界
wire        all_ok   = (reveal == 3'd7) && (&res_ok);
wire        done_now = valid_s && ((all_ok && (hold >= HOLD_FRAMES)) || (fcnt >= MAX_FRAMES));
wire        restart  = valid_q && !valid_s;            // 换卡：旧节目清掉了，自检从头来
wire [9:0]  w_lost, w_back, w_rej;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        fcnt      <= 10'd0;
        anim      <= 4'd0;
        reveal    <= 3'd0;
        gap       <= 6'd0;
        hold      <= 7'd0;
        st_q      <= 14'd0;
        sid_q     <= 49'd0;
        ld_q      <= 3'd0;
        n_q       <= 3'd0;
        msg_q     <= SID_CHECK;
        msg_kind  <= 2'd0;
        fatal_cnt <= 10'd0;
        valid_q   <= 1'b0;
        init_q    <= 1'b0;
        miss_q    <= 1'b0;
        back_cnt  <= 8'd0;
        page      <= P_CHECK;
        b_kind    <= BK_LOST;
        rej_req   <= 1'b0;
        rej_cnt   <= 8'd0;
        b_x0      <= 10'd0;
        splash_on <= 1'b1;
        boot_done <= 1'b0;
    end else begin
    if (reject)
        rej_req <= 1'b1;
    if (frame_start) begin
        valid_q <= valid_s;
        init_q  <= init_s;
        miss_q  <= miss_s;
        anim    <= anim + 4'd1;

        if (restart) begin
            // 换了卡：重新逐行自检，第一行马上出（显示器早就亮了）
            fcnt   <= FIRST_FRAMES;
            reveal <= 3'd0;
            gap    <= 6'd0;
            hold   <= 7'd0;
        end else begin
            if (init_s && !init_q && !boot_done && (fcnt > FIRST_FRAMES))
                fcnt <= FIRST_FRAMES;               // 开机时没卡、过了很久才插上：12 秒上限从插卡算起
            else if (fcnt != 10'h3FF)
                fcnt <= fcnt + 10'd1;

            if (reveal != 3'd7) begin
                if (gap != 6'd0)
                    gap <= gap - 6'd1;
                else if ((fcnt >= FIRST_FRAMES) && ((reveal == 3'd0) || res_ok[reveal - 3'd1])) begin
                    reveal <= reveal + 3'd1;
                    gap    <= STEP_FRAMES - 1;
                end
            end
            if (!all_ok)
                hold <= 7'd0;
            else if (hold != 7'h7F)
                hold <= hold + 7'd1;
        end

        boot_done <= done_now && !restart;
        splash_on <= !(done_now && !restart);

        // 【内置安全页】
        if (!fatal || boot_done)
            fatal_cnt <= 10'd0;
        else if (fatal_cnt != 10'h3FF)
            fatal_cnt <= fatal_cnt + 10'd1;

        // 【拔卡提示】
        if (miss_s)
            back_cnt <= 8'd0;
        else if (miss_q && valid_s)
            back_cnt <= BACK_FRAMES;
        else if (back_cnt != 8'd0)
            back_cnt <= back_cnt - 8'd1;
        // 【串口通知】
        if (rej_req && !reject) begin
            rej_req <= 1'b0;
            rej_cnt <= REJ_FRAMES;
        end else if (rej_cnt != 8'd0)
            rej_cnt <= rej_cnt - 8'd1;
        b_kind <= (rej_cnt != 8'd0) ? BK_REJ : miss_s ? BK_LOST : BK_BACK;
        b_x0   <= B_X1 - 10'd36 - ((rej_cnt != 8'd0) ? w_rej : miss_s ? w_lost : w_back);

        if (!(done_now && !restart))
            page <= (fatal && (fatal_cnt >= SAFE_FRAMES)) ? P_SAFE : P_CHECK;
        else if (!alert && (miss_s || (back_cnt != 8'd0) || (rej_cnt != 8'd0)))
            page <= P_BADGE;
        else
            page <= P_NONE;

        st_q  <= e_st;
        sid_q <= e_sid;
        ld_q  <= ld_s;
        n_q   <= n_s;
        if (nocard) begin
            msg_q <= SID_NOCARD; msg_kind <= 2'd2;
        end else if (fs_fail || pic_fail) begin
            msg_q <= err_msg(err_s, fs_fail); msg_kind <= 2'd2;
        end else if (all_ok) begin
            msg_q <= SID_DONE;   msg_kind <= 2'd1;
        end else begin
            msg_q <= SID_CHECK;  msg_kind <= 2'd0;
        end
    end
    end
end

// ---------------- 这一行是哪一块（【省资源】查表，每拍比一项） ----------------
// 原来每个像素都用约 30 组比较器判断 y 落在哪一块文字里。现在把每页的文字块列成一张表（每页最多 16 项），
// scan_i 每拍换一项，只用一个减法器和当前行比，16 拍出一次结果（寄存器）。
// y 在行尾才变、页面 / 已出现几项 / 底部状态在帧头才变，行消隐有 160 拍，下一行开始前结果早就对了。
// 各块在 y 方向互不重叠，所以查到哪一项就是哪一项，和原来的 if 链结果相同。
localparam [3:0] B_NONE = 4'd0, B_TITLE = 4'd1, B_CENTER = 4'd2, B_HEAD = 4'd3, B_ROW = 4'd4, B_MSG = 4'd5,
                 B_SROW = 4'd6, B_SROW_EN = 4'd7, B_BADGE = 4'd8, B_BADGE_EN = 4'd9;
reg  [3:0] band;
reg  [6:0] band_sid;                // 居中的字符串（标题 / 副标题 / 底部状态 / 安全页说明）
reg  [2:0] ri;                      // 第几项
reg  [3:0] brow;                    // 文字的第几行（对应 ROM 一个字的 bit）
reg        msg_en;                  // 底部英文行
// 表的一项
reg  [3:0] scan_i;
reg  [9:0] t_y;                     // 起始行
reg        t_tall;                  // 1 = 48 行的大标题（分 3 条字符串），0 = 16 行
reg  [3:0] t_band;
reg  [6:0] t_sid;                   // 字符串（大标题是第一条）
reg        t_msg;                   // 用底部状态 msg_q
reg        t_en;                    // 英文行（底部状态 +1）
reg  [2:0] t_ri;
reg        t_ok;                    // 这一项有没有（没有的项、自检清单里还没出现的行 = 0）
always @(*) begin
    t_y = 10'd0; t_tall = 1'b0; t_band = B_NONE; t_sid = 7'd0; t_msg = 1'b0; t_en = 1'b0; t_ri = 3'd0; t_ok = 1'b0;
    case (page)
        P_CHECK: case (scan_i)
            4'd0:  begin t_ok = 1'b1; t_y = Y_TITLE; t_tall = 1'b1; t_band = B_TITLE; t_sid = 7'd0; end
            4'd1:  begin t_ok = 1'b1; t_y = Y_SUBCN; t_band = B_CENTER; t_sid = SID_SUBCN; end
            4'd2:  begin t_ok = 1'b1; t_y = Y_SUBEN; t_band = B_CENTER; t_sid = SID_SUBEN; end
            4'd3:  begin t_ok = 1'b1; t_y = Y_HEAD;  t_band = B_HEAD;   t_sid = SID_HEAD;  end
            4'd4:  begin t_ok = 1'b1; t_y = Y_STCN;  t_band = B_MSG;    t_msg = 1'b1; end
            4'd5:  begin t_ok = 1'b1; t_y = Y_STEN;  t_band = B_MSG;    t_msg = 1'b1; t_en = 1'b1; end
            4'd6:  begin t_ok = (reveal > 3'd0); t_y = Y_ROW0;             t_band = B_ROW; t_ri = 3'd0; end
            4'd7:  begin t_ok = (reveal > 3'd1); t_y = Y_ROW0 + ROW_H;     t_band = B_ROW; t_ri = 3'd1; end
            4'd8:  begin t_ok = (reveal > 3'd2); t_y = Y_ROW0 + 2 * ROW_H; t_band = B_ROW; t_ri = 3'd2; end
            4'd9:  begin t_ok = (reveal > 3'd3); t_y = Y_ROW0 + 3 * ROW_H; t_band = B_ROW; t_ri = 3'd3; end
            4'd10: begin t_ok = (reveal > 3'd4); t_y = Y_ROW0 + 4 * ROW_H; t_band = B_ROW; t_ri = 3'd4; end
            4'd11: begin t_ok = (reveal > 3'd5); t_y = Y_ROW0 + 5 * ROW_H; t_band = B_ROW; t_ri = 3'd5; end
            4'd12: begin t_ok = (reveal > 3'd6); t_y = Y_ROW0 + 6 * ROW_H; t_band = B_ROW; t_ri = 3'd6; end
            default: ;
        endcase
        P_SAFE: case (scan_i)
            4'd0:  begin t_ok = 1'b1; t_y = S_TITLE; t_tall = 1'b1; t_band = B_TITLE; t_sid = SID_SAFE_T0; end
            4'd1:  begin t_ok = 1'b1; t_y = S_SUB;   t_band = B_CENTER; t_sid = SID_SAFE_SUB;  end
            4'd2:  begin t_ok = 1'b1; t_y = S_NOTE;  t_band = B_CENTER; t_sid = SID_SAFE_NOTE; end
            4'd3:  begin t_ok = 1'b1; t_y = S_STCN;  t_band = B_MSG;    t_msg = 1'b1; end
            4'd4:  begin t_ok = 1'b1; t_y = S_STEN;  t_band = B_MSG;    t_msg = 1'b1; t_en = 1'b1; end
            4'd5:  begin t_ok = 1'b1; t_y = S_ROW0;                     t_band = B_SROW;    t_ri = 3'd0; end
            4'd6:  begin t_ok = 1'b1; t_y = S_ROW0 + 20;                t_band = B_SROW_EN; t_ri = 3'd0; end
            4'd7:  begin t_ok = 1'b1; t_y = S_ROW0 + S_ROW_H;           t_band = B_SROW;    t_ri = 3'd1; end
            4'd8:  begin t_ok = 1'b1; t_y = S_ROW0 + S_ROW_H + 20;      t_band = B_SROW_EN; t_ri = 3'd1; end
            4'd9:  begin t_ok = 1'b1; t_y = S_ROW0 + 2 * S_ROW_H;       t_band = B_SROW;    t_ri = 3'd2; end
            4'd10: begin t_ok = 1'b1; t_y = S_ROW0 + 2 * S_ROW_H + 20;  t_band = B_SROW_EN; t_ri = 3'd2; end
            4'd11: begin t_ok = 1'b1; t_y = S_ROW0 + 3 * S_ROW_H;       t_band = B_SROW;    t_ri = 3'd3; end
            4'd12: begin t_ok = 1'b1; t_y = S_ROW0 + 3 * S_ROW_H + 20;  t_band = B_SROW_EN; t_ri = 3'd3; end
            default: ;
        endcase
        P_BADGE: case (scan_i)
            4'd0:  begin t_ok = 1'b1; t_y = B_YCN; t_band = B_BADGE;    end
            4'd1:  begin t_ok = 1'b1; t_y = B_YEN; t_band = B_BADGE_EN; end
            default: ;
        endcase
        default: ;
    endcase
end
wire [9:0] t_d   = y_cnt - t_y;                                   // 在这一块里的第几行（不在时是很大的数）
wire       t_hit = t_ok && (t_tall ? (t_d < 10'd48) : (t_d[9:4] == 6'd0));
wire [6:0] t_bsid = t_msg ? (msg_q + {6'd0, t_en}) : (t_sid + {5'd0, t_d[5:4]});   // 大标题第 0/1/2 条
// 一轮 16 项里命中的那一项先存在 acc_*，第 15 项比完一起更新到输出
reg  [3:0] acc_band;
reg  [6:0] acc_sid;
reg  [2:0] acc_ri;
reg  [3:0] acc_brow;
reg        acc_en;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        scan_i   <= 4'd0;
        acc_band <= B_NONE; acc_sid <= 7'd0; acc_ri <= 3'd0; acc_brow <= 4'd0; acc_en <= 1'b0;
        band     <= B_NONE; band_sid <= 7'd0; ri <= 3'd0; brow <= 4'd0; msg_en <= 1'b0;
    end else begin
        scan_i <= scan_i + 4'd1;
        if (t_hit || (scan_i == 4'd0)) begin                       // 每轮第一项先清
            acc_band <= t_hit ? t_band : B_NONE;
            acc_sid  <= t_hit ? t_bsid : 7'd0;
            acc_ri   <= t_hit ? t_ri   : 3'd0;
            acc_brow <= t_hit ? t_d[3:0] : 4'd0;
            acc_en   <= t_hit & t_en;
        end
        if (scan_i == 4'd15) begin
            band     <= t_hit ? t_band   : acc_band;
            band_sid <= t_hit ? t_bsid   : acc_sid;
            ri       <= t_hit ? t_ri     : acc_ri;
            brow     <= t_hit ? t_d[3:0] : acc_brow;
            msg_en   <= t_hit ? t_en     : acc_en;
        end
    end
end

wire [1:0] cur_st  = st_q[ri * 2 +: 2];
wire [6:0] cur_res = sid_q[ri * 7 +: 7];
wire       is_pic  = (ri == 3'd4);

// ---------------- 这一列画哪条字符串（ROM 读出晚一拍：按“下一个像素”算） ----------------
wire [9:0]  nx = x_cnt + 10'd1;
localparam [1:0] K_NONE = 2'd0, K_STR = 2'd1, K_ICON = 2'd2, K_DIG = 2'd3;
reg  [1:0]  kind;
reg  [6:0]  sid;
reg  [9:0]  x0;                     // 字符串画在哪一列开始（居中的用 ROM 表里的 s_x0）
reg         centered;
reg  [3:0]  dig;                    // 数字格：0~9，10 = %，11 = /
reg  [3:0]  icon;                   // 图标格（见 IC_*）
reg  [9:0]  ix;                     // 图标左边界
wire [9:0]  b_ix = b_x0 + 10'd8;    // 提示框里的图标
wire [9:0]  b_tx = b_x0 + 10'd28;   // 提示框里的文字
always @(*) begin
    kind     = K_NONE;
    sid      = band_sid;
    x0       = 10'd0;
    centered = 1'b0;
    dig      = 4'd0;
    icon     = IC_OK;
    ix       = ICON_X;
    case (band)
        B_TITLE, B_CENTER, B_MSG: begin kind = K_STR; centered = 1'b1; end
        B_HEAD:                   begin kind = K_STR; x0 = ICON_X; end
        B_ROW: begin
            if ((nx >= ICON_X) && (nx < ICON_X + 16)) begin
                kind = K_ICON; sid = SID_ICONS;
                case (cur_st)
                    ST_OK:   icon = IC_OK;
                    ST_WARN: icon = IC_WARN;
                    ST_FAIL: icon = IC_FAIL;
                    default: icon = IC_SPIN + {2'b00, anim[3:2]};
                endcase
            end else if ((nx >= LABEL_X) && (nx < RES_X)) begin
                kind = K_STR; sid = (ri == 3'd6) ? SID_LABEL6 : (SID_LABEL0 + {4'd0, ri}); x0 = LABEL_X;
            end else if (is_pic && (nx >= RES_X) && (nx < RES_X + 24)) begin
                kind = K_DIG; sid = SID_DIGITS;
                dig  = (nx < RES_X + 8) ? {1'b0, ld_q} : (nx < RES_X + 16) ? 4'd11 : {1'b0, n_q};
            end else if (nx >= RES_X) begin
                kind = K_STR; sid = cur_res; x0 = is_pic ? (RES_X + 32) : RES_X;
            end
        end
        B_SROW: begin
            if ((nx >= S_ICON_X) && (nx < S_ICON_X + 16)) begin
                kind = K_ICON; sid = SID_ICONS; icon = IC_FIRE + {1'b0, ri}; ix = S_ICON_X;
            end else if (nx >= S_TEXT_X) begin
                kind = K_STR; sid = SID_S1 + {3'd0, ri, 1'b0}; x0 = S_TEXT_X;
            end
        end
        B_SROW_EN: begin
            kind = K_STR; sid = SID_S1 + {3'd0, ri, 1'b0} + 7'd1; x0 = S_TEXT_X;
        end
        B_BADGE: begin
            if ((nx >= b_ix) && (nx < b_ix + 16)) begin
                kind = K_ICON; sid = SID_ICONS; icon = b_rej ? IC_FAIL : b_lost ? IC_WARN : IC_OK; ix = b_ix;
            end else if (nx >= b_tx) begin
                kind = K_STR; sid = b_rej ? SID_REJ : b_lost ? SID_LOST : SID_BACK; x0 = b_tx;
            end
        end
        B_BADGE_EN: begin
            kind = K_STR; sid = (b_rej ? SID_REJ : b_lost ? SID_LOST : SID_BACK) + 7'd1; x0 = b_tx;
        end
        default: ;
    endcase
end

wire [13:0] s_start;
wire [9:0]  s_len, s_x0;
reg  [13:0] raddr;
wire [15:0] rdata;

splash_rom u_rom (
    .clk     (clk),
    .raddr   (raddr),
    .rdata   (rdata),
    .sid     (sid),
    .s_start (s_start),
    .s_len   (s_len),
    .s_x0    (s_x0),
    .w_lost  (w_lost),
    .w_back  (w_back),
    .w_rej   (w_rej)
);

wire [9:0] sx0    = centered ? s_x0 : x0;
wire [9:0] col    = nx - sx0;
wire [9:0] icol   = nx - ix;
wire [9:0] dcol   = nx - RES_X;
reg        hit;
reg  [9:0] roff;                    // 【省资源】字符串内的列号：三种情况共用一个加法器
// 地址是组合逻辑（rdata 已经是寄存器输出，地址再打一拍会晚一列）
always @(*) begin
    hit  = 1'b0;
    roff = col;
    case (kind)
        K_STR:  hit = (nx >= sx0) && (col < s_len);
        K_ICON: begin hit = 1'b1; roff = {2'd0, icon, icol[3:0]}; end
        K_DIG:  begin hit = 1'b1; roff = {3'd0, dig, dcol[2:0]};  end
        default: ;
    endcase
    raddr = s_start + {4'd0, roff};
end

// ---------------- 文字颜色 ----------------
function [23:0] st_color;
    input [1:0] st;
    begin
        case (st)
            ST_OK:   st_color = 24'h6EE68C;
            ST_WARN: st_color = 24'hFFC850;
            ST_FAIL: st_color = 24'hFF5A50;
            default: st_color = 24'h7FB4FF;
        endcase
    end
endfunction
reg [23:0] c_next;
always @(*) begin
    case (band)
        B_TITLE:    c_next = 24'hFFFFFF;
        B_CENTER:   c_next = (page == P_SAFE) ? ((band_sid == SID_SAFE_SUB) ? 24'h9BE6B4 : 24'h86B496) :
                             (y_cnt < Y_SUBEN) ? 24'h96C8FF : 24'h6E96D2;
        B_HEAD:     c_next = 24'h96C8FF;
        B_ROW:      c_next = (kind == K_STR && nx < RES_X) ? 24'hDCE8FF :                  // 项目名
                             (cur_res == SID_CARD_NO) ? 24'hFFC850 : st_color(cur_st);     // 没插卡：黄字等待
        B_MSG:      c_next = (msg_kind == 2'd2) ? (msg_en ? 24'hE6AA5A : 24'hFFC850) :
                             (msg_kind == 2'd1) ? (msg_en ? 24'h5AB478 : 24'h6EE68C) :
                                                  (msg_en ? 24'h8CAADC : 24'hE6F0FF);
        B_SROW:     c_next = (kind == K_ICON) ? ((ri == 3'd0) ? 24'hFF7A3C : (ri == 3'd2) ? 24'h6EE68C : 24'hFF5A50) :
                                                24'hF0FFF4;
        B_SROW_EN:  c_next = 24'h8CC8A0;
        B_BADGE:    c_next = b_rej ? 24'hFF5A50 : b_lost ? 24'hFFC850 : 24'h6EE68C;
        B_BADGE_EN: c_next = b_rej ? 24'hE68C82 : b_lost ? 24'hE6AA5A : 24'h5AB478;
        default:    c_next = 24'hFFFFFF;
    endcase
end

reg        txt_on;                  // 当前像素在一条文字的范围里（和 rdata 同拍）
reg [23:0] c_txt;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        txt_on <= 1'b0;
        c_txt  <= 24'd0;
    end else begin
        txt_on <= de && hit;
        c_txt  <= c_next;
    end
end
wire txt_px = txt_on && rdata[brow];

// ---------------- 背景、面板、线条 ----------------
// 开机自检页：深蓝
wire       in_line  = (y_cnt == Y_LINE) && (px >= LINE_X0) && (px < LINE_X1);
wire       in_panel = (y_cnt >= PANEL_Y0) && (y_cnt < PANEL_Y1) && (px >= PANEL_X0) && (px < PANEL_X1);
wire       pan_edge = in_panel && ((y_cnt == PANEL_Y0) || (y_cnt == PANEL_Y1 - 1) || (px == PANEL_X0) || (px == PANEL_X1 - 1));
wire [23:0] bg      = {8'd6, 8'd14 + {3'd0, y_cnt[8:4]}, 8'd48 + {2'd0, y_cnt[8:3]}};
wire [23:0] panel   = {8'd12, 8'd26 + {3'd0, y_cnt[8:4]}, 8'd70 + {2'd0, y_cnt[8:3]}};
wire [23:0] check_px = txt_px   ? c_txt :
                       in_line  ? 24'h3C8CDC :
                       pan_edge ? 24'h2C4C84 :
                       in_panel ? panel :
                                  bg;
// 内置安全页：深绿（安全标志色）
wire       s_line   = ((y_cnt == S_LINE) && (px >= LINE_X0) && (px < LINE_X1)) ||
                      ((y_cnt == S_LINE2) && (px >= S_PX0) && (px < S_PX1));
wire       s_panel  = (y_cnt >= S_PY0) && (y_cnt < S_PY1) && (px >= S_PX0) && (px < S_PX1);
wire       s_edge   = s_panel && ((y_cnt == S_PY0) || (y_cnt == S_PY1 - 1) || (px == S_PX0) || (px == S_PX1 - 1));
wire [23:0] s_bg    = {8'd4, 8'd36 + {2'd0, y_cnt[8:3]}, 8'd26 + {3'd0, y_cnt[8:4]}};
wire [23:0] s_pan   = {8'd10, 8'd58 + {3'd0, y_cnt[8:4]}, 8'd40 + {3'd0, y_cnt[8:4]}};
wire [23:0] safe_px = txt_px  ? c_txt :
                      s_line  ? 24'h3CC878 :
                      s_edge  ? 24'h2C7A50 :
                      s_panel ? s_pan :
                                s_bg;
// 拔卡提示框：画面压暗到 1/4 + 一点深蓝，1 像素边框
wire       in_box   = (y_cnt >= B_Y0) && (y_cnt < B_Y1) && (px >= b_x0) && (px < B_X1);
wire       box_edge = in_box && ((y_cnt == B_Y0) || (y_cnt == B_Y1 - 1) || (px == b_x0) || (px == B_X1 - 1));
wire [7:0]  dim_r   = {2'b00, rgb_in[23:18]} + 8'd8;
wire [7:0]  dim_g   = {2'b00, rgb_in[15:10]} + 8'd12;
wire [7:0]  dim_b   = {2'b00, rgb_in[7:2]}   + 8'd28;
wire [23:0] box_dim = {dim_r, dim_g, dim_b};
wire [23:0] badge_px = !in_box  ? rgb_in :
                       txt_px   ? c_txt :
                       box_edge ? (b_rej ? 24'hFF5A50 : b_lost ? 24'hFFC850 : 24'h6EE68C) :
                                  box_dim;

assign rgb_out = (page == P_CHECK) ? check_px :
                 (page == P_SAFE)  ? safe_px :
                 (page == P_BADGE) ? badge_px :
                                     rgb_in;

endmodule
