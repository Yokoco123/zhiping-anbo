`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// WAV 背景音乐播放器（参考参考例程 wav_stream_player.v 改写）
//
// 和原版的区别：
//   - 原版要求把裸 PCM 写到卡上固定扇区；这里直接吃 FAT32 读出来的 MUSIC.WAV 字节流，
//     自己解析 RIFF/fmt/data 块，Windows 直接拷文件就能用（会跳过 LIST 等附加块）
//   - 原版没有流量控制（注释里说“隐含在消费速率里”，实际 TF 卡比播放快很多，会覆盖未播数据），
//     这里用 hold 信号让 FAT32 流读器暂停发扇区请求
//   - 支持单声道和立体声，要求 48kHz、16 位 PCM
//   - 文件播完由上游从头重读，本模块识别到偏移回到 0 就重新解析文件头，实现循环播放
//
// 写侧 wr_clk（sd_card_clk 100MHz）：字节流 → 解析 → 组装成 {左,右} 32 位 → 环形缓冲
// 读侧 rd_clk（video_clk 25MHz）：每个 sample_tick 取一个样本，下溢时输出静音
// 读写指针用格雷码 + 两级触发器跨时钟域
// -----------------------------------------------------------------------------
module wav_player #(
    parameter integer ADDR_W     = 12,               // 4096 × 32 位 ≈ 立体声 85ms
    parameter integer HOLD_FREE  = 512               // 剩余空间少于它就暂停读卡（一个扇区最多 256 项）
)(
    // ---------------- 写侧：sd_card_clk ----------------
    input  wire        wr_clk,
    input  wire        wr_rst,                       // 高有效，与 sd_card_bmp4 一致
    input  wire        byte_valid,
    input  wire [7:0]  byte_data,
    input  wire [31:0] byte_off,                     // 文件内偏移，从 0 开始
    output reg         hold,                         // 1 = 缓冲快满，暂停读下一个扇区
    output reg  [3:0]  status,                       // 0 无音乐 1 播放中 2 出现过断流 6 格式不支持

    // ---------------- 读侧：video_clk ----------------
    input  wire        rd_clk,
    input  wire        rd_rst_n,
    input  wire        sample_tick,                  // 48kHz 单拍，与 HDMI 音频 valid 同一个信号
    input  wire [7:0]  volume,                       // 0~255
    input  wire        pause,                        // 1 = 暂停：输出静音、读指针不动（rd_clk 域）
    output reg  signed [15:0] out_left,
    output reg  signed [15:0] out_right,
    output wire        active                        // 1 = 正在用 WAV（顶层据此替换琶音）
);

localparam integer DEPTH = (1 << ADDR_W);

// =============================================================================
// 写侧：WAV 解析
// =============================================================================
localparam [2:0] P_RIFF = 3'd0;   // 偏移 0~11：RIFF....WAVE
localparam [2:0] P_HDR  = 3'd1;   // 块头 8 字节：ID + 长度
localparam [2:0] P_FMT  = 3'd2;   // fmt 块内容
localparam [2:0] P_SKIP = 3'd3;   // 跳过不认识的块（LIST 等）
localparam [2:0] P_DATA = 3'd4;   // PCM 数据
localparam [2:0] P_END  = 3'd5;   // data 块读完，等下一轮
localparam [2:0] P_ERR  = 3'd6;   // 不是 WAV 或格式不支持

// 【省资源 第4轮】文件头里的标记和 fmt 字段不再整段存下来再比较，收到一个字节就和期望值比，只留 1 位标志
reg [2:0]  pst;
reg        rw_ok;                 // "RIFF" ... "WAVE" 到目前为止都对
reg [2:0]  hcnt;
reg        id_data, id_fmt;       // 块 ID 到目前为止是 "data" / "fmt "
reg [31:0] ck_len;
reg [31:0] remain;
reg [4:0]  fcnt;
reg        f_t0, f_t1;            // fmt 第 0~1 字节：格式 = 1（PCM）
reg        f_c1, f_c2, f_c3;      // 第 2 字节 = 1 / = 2，第 3 字节 = 0（声道数 1 或 2）
reg        f_r4, f_r5, f_r6, f_r7;// 第 4~7 字节：采样率 = 48000（0x0000BB80）
reg        f_b14, f_b15;          // 第 14~15 字节：16 位
reg        fmt_seen;
reg [1:0]  bsel;                  // 当前样本帧里的第几个字节
reg [7:0]  lo_byte;
reg [15:0] left_s;

// 【时序】输入字节先打一拍，文件偏移的比较也在这一拍算好（原来 32 位偏移比较直接进状态机，路径太长）。
//   hold 留了 HOLD_FREE 项余量，晚一拍收字节没有影响
reg        bv;
reg  [7:0] bd;
// 【省资源 第4轮】只用到偏移 0~11：打一拍的是 低 4 位 + “高 28 位全 0”，原来是 4 个 32 位比较
reg        off_hi0;
reg  [3:0] off_lo;
always @(posedge wr_clk or posedge wr_rst) begin
    if (wr_rst) begin
        bv <= 1'b0; bd <= 8'd0; off_hi0 <= 1'b0; off_lo <= 4'd0;
    end else begin
        bv      <= byte_valid;
        bd      <= byte_data;
        off_hi0 <= (byte_off[31:4] == 28'd0);
        off_lo  <= byte_off[3:0];
    end
end
wire off_0   = off_hi0 && (off_lo == 4'd0);
wire off_11  = off_hi0 && (off_lo == 4'd11);
// "RIFF????WAVE" 第 1~3、8~11 字节应该是什么（第 0 字节在 off_0 里比）
reg  [7:0] rw_exp;
always @* begin
    case (off_lo)
        4'd1:  rw_exp = "I";
        4'd2:  rw_exp = "F";
        4'd3:  rw_exp = "F";
        4'd8:  rw_exp = "W";
        4'd9:  rw_exp = "A";
        4'd10: rw_exp = "V";
        default: rw_exp = "E";
    endcase
end
wire rw_chk = off_hi0 && (off_lo[3:2] != 2'b01);   // 第 4~7 字节（文件长度）不比

// 块头最后一个字节到达时的完整长度；长度为奇数时块后还有 1 个填充字节
wire [31:0] ck_len_full = {bd, ck_len[31:8]};
wire [31:0] ck_len_pad  = ck_len_full + {31'd0, ck_len_full[0]};

wire fmt_ok = fmt_seen && f_t0 && f_t1 && f_b14 && f_b15 &&
              f_r4 && f_r5 && f_r6 && f_r7 && f_c3 && (f_c1 || f_c2);
wire stereo = f_c2 && f_c3;

// 环形缓冲写口
reg  [ADDR_W:0]   wr_ptr;         // 多一位区分空/满
reg               we;
reg  [ADDR_W-1:0] waddr;
reg  [31:0]       wdata;
reg               data_seen;      // 至少开始过一次 PCM 数据

// 读指针同步过来（格雷码）
reg  [ADDR_W:0]   rd_gray_s1, rd_gray_s2;
wire [ADDR_W:0]   rd_ptr_w = gray2bin(rd_gray_s2);
wire [ADDR_W:0]   used_w   = wr_ptr - rd_ptr_w;

// 读侧断流标志同步过来
reg               under_s1, under_s2;
reg               fmt_err_seen;   // 出现过格式错误（保持到复位）

// 读侧寄存器（写侧要用到，先声明）
reg  [ADDR_W:0]   rd_ptr;
reg  [ADDR_W:0]   rd_gray;
reg               underflow_seen;

function [ADDR_W:0] gray2bin;
    input [ADDR_W:0] g;
    integer i;
    begin
        gray2bin[ADDR_W] = g[ADDR_W];
        for (i = ADDR_W - 1; i >= 0; i = i - 1)
            gray2bin[i] = gray2bin[i+1] ^ g[i];
    end
endfunction

always @(posedge wr_clk or posedge wr_rst) begin
    if (wr_rst) begin
        pst        <= P_RIFF;
        rw_ok      <= 1'b0;
        hcnt       <= 3'd0;
        id_data    <= 1'b0;
        id_fmt     <= 1'b0;
        ck_len     <= 32'd0;
        remain     <= 32'd0;
        fcnt       <= 5'd0;
        {f_t0, f_t1, f_c1, f_c2, f_c3, f_r4, f_r5, f_r6, f_r7, f_b14, f_b15} <= 11'd0;
        fmt_seen   <= 1'b0;
        bsel       <= 2'd0;
        lo_byte    <= 8'd0;
        left_s     <= 16'd0;
        wr_ptr     <= {(ADDR_W+1){1'b0}};
        we         <= 1'b0;
        waddr      <= {ADDR_W{1'b0}};
        wdata      <= 32'd0;
        data_seen  <= 1'b0;
        rd_gray_s1 <= {(ADDR_W+1){1'b0}};
        rd_gray_s2 <= {(ADDR_W+1){1'b0}};
        under_s1   <= 1'b0;
        under_s2   <= 1'b0;
        hold       <= 1'b0;
        status     <= 4'd0;
        fmt_err_seen <= 1'b0;
    end else begin
        rd_gray_s1 <= rd_gray;
        rd_gray_s2 <= rd_gray_s1;
        under_s1   <= underflow_seen;
        under_s2   <= under_s1;
        we         <= 1'b0;

        hold <= (used_w > (DEPTH - HOLD_FREE));

        if (pst == P_ERR)
            fmt_err_seen <= 1'b1;

        if (fmt_err_seen)
            status <= 4'd6;
        else if (under_s2)
            status <= 4'd2;
        else if (data_seen)
            status <= 4'd1;
        else
            status <= 4'd0;

        if (bv) begin
            if (off_0) begin
                // 新一轮（开机第一次，或播完从头重读）：重新解析文件头
                rw_ok    <= (bd == "R");
                fmt_seen <= 1'b0;
                pst      <= P_RIFF;
            end else begin
                case (pst)
                    P_RIFF: begin
                        if (rw_chk)
                            rw_ok <= rw_ok && (bd == rw_exp);
                        if (off_11) begin
                            if (rw_ok && (bd == "E")) begin
                                pst  <= P_HDR;
                                hcnt <= 3'd0;
                            end else begin
                                pst  <= P_ERR;
                            end
                        end
                    end

                    P_HDR: begin
                        // 小端：ID 第一个字节最先到，所以 "data" 存成 "atad"
                        case (hcnt)
                            3'd0: begin id_data <= (bd == "d"); id_fmt <= (bd == "f"); end
                            3'd1: begin id_data <= id_data && (bd == "a"); id_fmt <= id_fmt && (bd == "m"); end
                            3'd2: begin id_data <= id_data && (bd == "t"); id_fmt <= id_fmt && (bd == "t"); end
                            3'd3: begin id_data <= id_data && (bd == "a"); id_fmt <= id_fmt && (bd == " "); end
                            default: ck_len <= {bd, ck_len[31:8]};
                        endcase
                        hcnt <= hcnt + 3'd1;
                        if (hcnt == 3'd7) begin
                            hcnt <= 3'd0;
                            // 这一拍收到的是长度最高字节，完整长度 = ck_len_full
                            if (id_data) begin
                                if (fmt_ok && (ck_len_full != 32'd0)) begin
                                    pst    <= P_DATA;
                                    remain <= ck_len_full;
                                    bsel   <= 2'd0;
                                end else begin
                                    pst    <= P_ERR;
                                end
                            end else if (id_fmt) begin
                                if (ck_len_full[31:4] == 28'd0) begin
                                    pst    <= P_ERR;
                                end else begin
                                    pst    <= P_FMT;
                                    fcnt   <= 5'd0;
                                    remain <= ck_len_pad;
                                end
                            end else if ((ck_len_full != 32'd0) && (ck_len_full != 32'hFFFFFFFF)) begin   // = 补齐后长度不为 0（不经过加法器）
                                pst    <= P_SKIP;
                                remain <= ck_len_pad;
                            end
                            // 长度为 0 的块：留在 P_HDR，下一个字节就是下一个块头
                        end
                    end

                    P_FMT: begin
                        case (fcnt)
                            5'd0:  f_t0 <= (bd == 8'h01);
                            5'd1:  f_t1 <= (bd == 8'h00);
                            5'd2:  begin f_c1 <= (bd == 8'h01); f_c2 <= (bd == 8'h02); end
                            5'd3:  f_c3 <= (bd == 8'h00);
                            5'd4:  f_r4 <= (bd == 8'h80);
                            5'd5:  f_r5 <= (bd == 8'hBB);
                            5'd6:  f_r6 <= (bd == 8'h00);
                            5'd7:  f_r7 <= (bd == 8'h00);
                            5'd14: f_b14 <= (bd == 8'h10);
                            5'd15: begin
                                f_b15 <= (bd == 8'h00);
                                fmt_seen       <= 1'b1;
                            end
                            default: ;
                        endcase
                        if (fcnt != 5'd31)
                            fcnt <= fcnt + 5'd1;
                        remain <= remain - 32'd1;
                        if (remain == 32'd1) begin
                            pst  <= P_HDR;
                            hcnt <= 3'd0;
                        end
                    end

                    P_SKIP: begin
                        remain <= remain - 32'd1;
                        if (remain == 32'd1) begin
                            pst  <= P_HDR;
                            hcnt <= 3'd0;
                        end
                    end

                    P_DATA: begin
                        data_seen <= 1'b1;
                        remain    <= remain - 32'd1;
                        if (remain == 32'd1)
                            pst <= P_END;
                        case (bsel)
                            2'd0: begin
                                lo_byte <= bd;
                                bsel    <= 2'd1;
                            end
                            2'd1: begin
                                if (stereo) begin
                                    left_s <= {bd, lo_byte};
                                    bsel   <= 2'd2;
                                end else begin
                                    // 单声道：左右相同
                                    we     <= 1'b1;
                                    waddr  <= wr_ptr[ADDR_W-1:0];
                                    wdata  <= {bd, lo_byte, bd, lo_byte};
                                    wr_ptr <= wr_ptr + 1'b1;
                                    bsel   <= 2'd0;
                                end
                            end
                            2'd2: begin
                                lo_byte <= bd;
                                bsel    <= 2'd3;
                            end
                            default: begin
                                we     <= 1'b1;
                                waddr  <= wr_ptr[ADDR_W-1:0];
                                wdata  <= {left_s, bd, lo_byte};
                                wr_ptr <= wr_ptr + 1'b1;
                                bsel   <= 2'd0;
                            end
                        endcase
                    end

                    default: ;   // P_END / P_ERR：等下一轮
                endcase
            end
        end
    end
end

// 写侧 → 读侧：是否已经在放 WAV（准静态，两拍同步即可）
reg act_s1, act_s2;

// =============================================================================
// 环形缓冲：简单双口 RAM，写 wr_clk、读 rd_clk，TD 会推断成 BRAM
// =============================================================================
reg [31:0] mem [0:DEPTH-1];
always @(posedge wr_clk) begin
    if (we)
        mem[waddr] <= wdata;
end

reg  [31:0]       rdata;
always @(posedge rd_clk) begin
    rdata <= mem[rd_ptr[ADDR_W-1:0]];
end

// =============================================================================
// 读侧
// =============================================================================
reg  [ADDR_W:0] wr_gray;          // 写指针格雷码（在写时钟域打一拍，避免组合输出跨域）
always @(posedge wr_clk or posedge wr_rst) begin
    if (wr_rst)
        wr_gray <= {(ADDR_W+1){1'b0}};
    else
        wr_gray <= wr_ptr ^ (wr_ptr >> 1);
end

reg  [ADDR_W:0] wr_gray_s1, wr_gray_s2;
wire [ADDR_W:0] wr_ptr_r = gray2bin(wr_gray_s2);
wire [ADDR_W:0] used_r   = wr_ptr_r - rd_ptr;
reg             playing;          // 预填充到一半后才开始放，断流后重新预填充
reg  [1:0]      fetch_wait;       // 读指针变化后等 2 拍，rdata 才是新地址的数据
reg  signed [15:0] cur_l, cur_r;

assign active = act_s2;

wire signed [24:0] mul_l = $signed(rdata[31:16]) * $signed({1'b0, volume});
wire signed [24:0] mul_r = $signed(rdata[15:0])  * $signed({1'b0, volume});

always @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
        rd_ptr         <= {(ADDR_W+1){1'b0}};
        rd_gray        <= {(ADDR_W+1){1'b0}};
        wr_gray_s1     <= {(ADDR_W+1){1'b0}};
        wr_gray_s2     <= {(ADDR_W+1){1'b0}};
        act_s1         <= 1'b0;
        act_s2         <= 1'b0;
        playing        <= 1'b0;
        underflow_seen <= 1'b0;
        fetch_wait     <= 2'd0;
        cur_l          <= 16'sd0;
        cur_r          <= 16'sd0;
        out_left       <= 16'sd0;
        out_right      <= 16'sd0;
    end else begin
        wr_gray_s1 <= wr_gray;
        wr_gray_s2 <= wr_gray_s1;
        act_s1     <= data_seen;
        act_s2     <= act_s1;
        rd_gray    <= rd_ptr ^ (rd_ptr >> 1);

        if (fetch_wait != 2'd0)
            fetch_wait <= fetch_wait - 2'd1;
        else begin
            // rdata 已经是 rd_ptr 处的样本：先乘音量存起来，等下一个节拍输出
            cur_l <= mul_l[23:8];
            cur_r <= mul_r[23:8];
        end

        if (!playing && (used_r >= (DEPTH / 2)))
            playing <= 1'b1;

        if (sample_tick) begin
            if (pause) begin
                // 暂停：缓冲会被写满，hold 拉高，FAT32 流读器自然停在扇区边界；
                // 继续时从暂停处接着放，不算断流
                out_left  <= 16'sd0;
                out_right <= 16'sd0;
            end else if (playing && (used_r != 0) && (fetch_wait == 2'd0)) begin
                out_left   <= cur_l;
                out_right  <= cur_r;
                rd_ptr     <= rd_ptr + 1'b1;
                fetch_wait <= 2'd3;
            end else begin
                out_left  <= 16'sd0;
                out_right <= 16'sd0;
                if (playing && act_s2) begin
                    // 播放中缓冲空了：静音并重新预填充，状态显示 2
                    playing        <= 1'b0;
                    underflow_seen <= 1'b1;
                end
            end
        end
    end
end

endmodule
