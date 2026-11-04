`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// 【数码管】8 位数码管只显示关键参数（代替原来的 seg_decoder ×5 + seg_scan 调试码）
//   左 4 位 = 节目，右 4 位 = 参数（一个字母 + 三位数）：
//     正常播放          P2-4  U 80      第 2 张 / 共 4 张，音量 80
//     菜单打开（SW2）   P2-4  b100      右边换成正在调的那一项：b 亮度 / C 对比度 / U 音量 / t 轮播周期（秒）
//     【启事】放启事页  n2-3  U 80      第 2 条 / 共 3 条启事
//     还没有图可放      ----  U 80      开机中 / 没插卡
//     图都读不出来      Er 4  U 80      错误码同 fat32_bmp_read（1 头错 2 超时 3 不完整 4 没有图 5 FAT 链）
//     应急模式（SW1）   SOS   9.6       左边 SOS 闪烁；右边 = 【应急时延实测】这次从拨开关到应急画面出现用了几毫秒
//     【按键改造】消音后 SOS. ：第二个 S 后面的小数点常亮
//                                       （video_transition 测的，0.1ms 一档；还没测完显示 ---）
//   只有一部分图读不出来时照常显示（开机自检页已经报过）
// 板上是两块 4 位共阳数码管，从左到右 = 原理图 SEL7 SEL6 SEL5 … SEL0（低有效）。
//   pin.adc 里 seg_sel[0..5] = SEL5..SEL0（沿用原来的 6 行），seg_sel[6] = SEL6（E16），seg_sel[7] = SEL7（F16），
//   所以从左数第 k 位对应的 seg_sel 位是 POS_BIT 表里的值。
// seg_data：bit0~6 = a~g，bit7 = 小数点，低电平点亮（和原来的 seg_decoder 一样）。
// 在 sd_card_clk 域；只有 lat_val / lat_ok 来自 video_clk 域，这里打两拍、连续两拍相同才用（测完以后不再变）。
// 每位亮约 160us，换位时先灭 1/8 的时间再点下一位，消除串影。
// -----------------------------------------------------------------------------
module seg_status (
    input  wire       clk,              // sd_card_clk 100MHz
    input  wire       rst,
    input  wire       emerg,            // SW1 应急
    input  wire       menu_on,          // SW2 参数菜单
    input  wire       display_valid,    // 已经有图在放
    input  wire [3:0] img_num,          // 当前第几张（1 起）
    input  wire [2:0] img_total,        // 一共找到几张
    input  wire [3:0] err_code,
    input  wire [7:0] bri_pct,
    input  wire [7:0] con_pct,
    input  wire [7:0] vol_pct,
    input  wire [2:0] period_idx,       // 0~5 = 1/3/5/10/30/60 秒
    input  wire [1:0] menu_sel,         // 0 亮度 1 对比度 2 音量 3 轮播周期
    input  wire [7:0] lat_val,          // 【应急时延实测】video_clk 域，单位 0.1ms
    input  wire       lat_ok,           // 1 = 已测完
    input  wire       muted,            // 【按键改造】已消音：SOS 的第二个 S 后面亮小数点
    input  wire [6:0] page_info,        // 【启事】{正在放启事页, 第几条, 共几条}（sd_card_bmp4）
    output reg  [7:0] seg_sel,
    output reg  [7:0] seg_data
);

// 字符编码
localparam [4:0] C_BL = 5'd10, C_DASH = 5'd11, C_P = 5'd12, C_U = 5'd13, C_B = 5'd14,
                 C_C  = 5'd15, C_T    = 5'd16, C_S = 5'd17, C_E = 5'd18, C_R = 5'd19, C_N = 5'd20;

// 【应急时延实测】跨时钟域
reg [8:0] lat_s1, lat_s2, lat_r;
always @(posedge clk) begin
    lat_s1 <= {lat_ok, lat_val};
    lat_s2 <= lat_s1;
    if (lat_s1 == lat_s2) lat_r <= lat_s2;
end

reg [25:0] cnt;
wire [2:0] pos   = cnt[16:14];          // 正在点第几位（0 = 最左）
wire       gap   = (cnt[13:11] == 3'd0);// 每位开头的 1/8：全灭
wire       blink = cnt[25];             // 约 0.67 秒一个周期
reg        emerg_d;                     // 进入应急时 SOS 从“亮”开始闪

// ---------------- 右边：字母 + 数值 ----------------
reg  [4:0] r_let;
reg  [7:0] r_val;
always @(posedge clk) begin
    if (emerg) begin
        r_let <= C_BL; r_val <= lat_r[7:0];              // 应急：右边显示响应时间（xx.x 毫秒）
    end else if (menu_on) begin
        case (menu_sel)
            2'd0:    begin r_let <= C_B; r_val <= bri_pct; end
            2'd1:    begin r_let <= C_C; r_val <= con_pct; end
            2'd2:    begin r_let <= C_U; r_val <= vol_pct; end
            default: begin
                r_let <= C_T;
                case (period_idx)
                    3'd0:    r_val <= 8'd1;
                    3'd1:    r_val <= 8'd3;
                    3'd2:    r_val <= 8'd5;
                    3'd3:    r_val <= 8'd10;
                    3'd4:    r_val <= 8'd30;
                    default: r_val <= 8'd60;
                endcase
            end
        endcase
    end else begin
        r_let <= C_U; r_val <= vol_pct;
    end
end
// 二进制 → 百位 / 十位 / 个位（0~255），分三拍算（显示不急，【时序】每拍逻辑都很短）
wire [1:0] d_h  = (r_val >= 8'd200) ? 2'd2 : (r_val >= 8'd100) ? 2'd1 : 2'd0;
reg  [1:0] d_h1, d_h_r;
reg  [6:0] r_99, r_99b;
reg  [4:0] r_let1, r_let2, r_let_r;
always @(posedge clk) begin
    d_h1   <= d_h;
    r_99   <= r_val - ((d_h == 2'd2) ? 8'd200 : (d_h == 2'd1) ? 8'd100 : 8'd0);
    r_let1 <= r_let;
end
wire [3:0] d_t  = (r_99 >= 7'd90) ? 4'd9 : (r_99 >= 7'd80) ? 4'd8 : (r_99 >= 7'd70) ? 4'd7 :
                  (r_99 >= 7'd60) ? 4'd6 : (r_99 >= 7'd50) ? 4'd5 : (r_99 >= 7'd40) ? 4'd4 :
                  (r_99 >= 7'd30) ? 4'd3 : (r_99 >= 7'd20) ? 4'd2 : (r_99 >= 7'd10) ? 4'd1 : 4'd0;
reg  [3:0] d_t2, d_t_r, d_o_r;
reg  [1:0] d_h2;
always @(posedge clk) begin
    d_h2   <= d_h1;
    d_t2   <= d_t;
    r_99b  <= r_99;
    r_let2 <= r_let1;
end
wire [6:0] t10  = {d_t2, 3'b0} + {2'b0, d_t2, 1'b0};  // 十位 × 10
wire [6:0] d_o  = r_99b - t10;
always @(posedge clk) begin
    d_h_r   <= d_h2;
    d_t_r   <= d_t2;
    d_o_r   <= d_o[3:0];
    r_let_r <= r_let2;
end

// ---------------- 8 位要显示的字符 ----------------
reg [5:0] ch [0:7];                     // bit5 = 小数点
always @(posedge clk) begin
    if (emerg) begin
        ch[0] <= blink ? {1'b0, C_S} : {1'b0, C_BL};
        ch[1] <= blink ? 6'd0        : {1'b0, C_BL};    // O 用 0 显示
        ch[2] <= blink ? {muted, C_S} : {muted, C_BL};   // 【按键改造】消音时小数点常亮
        ch[3] <= {1'b0, C_BL};
        ch[4] <= {1'b0, C_BL};
        if (lat_r[8]) begin                              // 例如  9.6 / 17.9（毫秒）
            ch[5] <= (d_h_r == 2'd0) ? {1'b0, C_BL} : {4'b0, d_h_r};
            ch[6] <= {2'b10, d_t_r};
            ch[7] <= {2'b00, d_o_r};
        end else begin
            ch[5] <= {1'b0, C_DASH}; ch[6] <= {1'b0, C_DASH}; ch[7] <= {1'b0, C_DASH};
        end
    end else begin
        if (display_valid && page_info[6]) begin
            ch[0] <= {1'b0, C_N}; ch[1] <= {3'b0, page_info[5:3]}; ch[2] <= {1'b0, C_DASH}; ch[3] <= {3'b0, page_info[2:0]};
        end else if (display_valid) begin
            ch[0] <= {1'b0, C_P}; ch[1] <= {2'b0, img_num}; ch[2] <= {1'b0, C_DASH}; ch[3] <= {3'b0, img_total};
        end else if (err_code != 4'd0) begin
            ch[0] <= {1'b0, C_E}; ch[1] <= {1'b0, C_R}; ch[2] <= {1'b0, C_BL}; ch[3] <= {2'b0, err_code};
        end else begin
            ch[0] <= {1'b0, C_DASH}; ch[1] <= {1'b0, C_DASH}; ch[2] <= {1'b0, C_DASH}; ch[3] <= {1'b0, C_DASH};
        end
        ch[4] <= {1'b0, r_let_r};
        ch[5] <= (d_h_r == 2'd0) ? {1'b0, C_BL} : {4'b0, d_h_r};
        ch[6] <= (d_h_r == 2'd0 && d_t_r == 4'd0) ? {1'b0, C_BL} : {2'b0, d_t_r};
        ch[7] <= {2'b0, d_o_r};
    end
end

// ---------------- 字符 → 段码（低有效，g~a） ----------------
function [6:0] seg7; input [4:0] c; begin
    case (c)
        5'd0:  seg7 = 7'b100_0000;
        5'd1:  seg7 = 7'b111_1001;
        5'd2:  seg7 = 7'b010_0100;
        5'd3:  seg7 = 7'b011_0000;
        5'd4:  seg7 = 7'b001_1001;
        5'd5:  seg7 = 7'b001_0010;
        5'd6:  seg7 = 7'b000_0010;
        5'd7:  seg7 = 7'b111_1000;
        5'd8:  seg7 = 7'b000_0000;
        5'd9:  seg7 = 7'b001_0000;
        C_DASH: seg7 = 7'b011_1111;
        C_P:   seg7 = 7'b000_1100;
        C_U:   seg7 = 7'b100_0001;
        C_B:   seg7 = 7'b000_0011;
        C_C:   seg7 = 7'b100_0110;
        C_T:   seg7 = 7'b000_0111;
        C_S:   seg7 = 7'b001_0010;
        C_E:   seg7 = 7'b000_0110;
        C_R:   seg7 = 7'b010_1111;
        C_N:   seg7 = 7'b100_1000;          // 大 n（∩）：a b c e f
        default: seg7 = 7'b111_1111;             // 空
    endcase
end endfunction
// 从左数第 p 位 → seg_sel 的哪一位
function [2:0] pos_bit; input [2:0] p; begin
    case (p)
        3'd0: pos_bit = 3'd7;   3'd1: pos_bit = 3'd6;
        3'd2: pos_bit = 3'd0;   3'd3: pos_bit = 3'd1;
        3'd4: pos_bit = 3'd2;   3'd5: pos_bit = 3'd3;
        3'd6: pos_bit = 3'd4;   default: pos_bit = 3'd5;
    endcase
end endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        cnt      <= 26'd0;
        emerg_d  <= 1'b0;
        seg_sel  <= 8'hFF;
        seg_data <= 8'hFF;
    end else begin
        emerg_d  <= emerg;
        cnt      <= (emerg && !emerg_d) ? {1'b1, cnt[24:0]} : cnt + 26'd1;
        seg_sel  <= gap ? 8'hFF : ~(8'd1 << pos_bit(pos));
        seg_data <= {~ch[pos][5], seg7(ch[pos][4:0])};
    end
end
endmodule
