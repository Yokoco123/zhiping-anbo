`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// 【字幕】点阵条滚动字幕（video_clk 域，替代原来的 promax_text_overlay）
// FPGA 里不放字库：电脑上用宋体 16 像素把整句“中文 + 空隙 + English”画好，
// 由 subtitle/gen_subtitle.ps1 生成 subtitle_rom.v，每列一个 16 位字（bit0 = 最上面一行）。
// 所以中文、英文、标点、符号都能显示，以后串口发来的寻物/寻人启事也用同样的格式。
//
//   字幕槽：0~3 = PIC1~PIC4，4 = 应急，5 = 预留（串口启事）
//   滚动：从字幕条右端进入、向左移出，移完再从右端进入；每 FRAMES_PER_PX 帧移 1 像素
//   换槽（换图 / 进出应急）时从右端重新开始；某条字幕为空时不画字幕条
//   alert = 1：红底白字（应急；alert_l2 = 1 时橙底白字），否则浅底黑字
//   【串口通知】notice = 1：换成 RAM 里的文字（notice_col / notice_bits），不受 enable 控制：
//     不在应急 = 普通通知或三级应急文字，黄底黑字；应急接管中 = 串口发的应急文字，红 / 橙底白字
//     （应急接管但没有文字时 notice = 0，显示固定的应急字幕槽 4）
// ROM 读出有 1 拍延迟，所以用下一个像素的坐标去读，输出仍是纯组合叠加，不增加视频延迟。
// -----------------------------------------------------------------------------
module subtitle_strip #(
    parameter integer BAND_X0       = 8,        // 字幕条左端（含）
    parameter integer BAND_X1       = 632,      // 字幕条右端（不含）
    parameter integer BAND_Y        = 448,      // 字幕条顶端行号，条高 20 行，字在第 2~17 行
    parameter integer FRAMES_PER_PX = 1         // 1 = 每秒 60 像素，约每秒 4 个汉字
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vs,                      // 低有效场同步
    input  wire        de,
    input  wire [9:0]  pixel_x,
    input  wire [23:0] rgb_in,
    input  wire        enable,                  // 1 = 显示字幕条
    input  wire [2:0]  slot,                    // 显示哪一条
    input  wire        alert,
    input  wire        alert_l2,                // 【应急改版】二级：橙底
    // 【串口通知】
    input  wire        notice,                  // 1 = 显示通知
    input  wire [10:0] notice_len,
    input  wire        notice_new,              // 单拍：换了一条通知，从右端重新进入
    output wire [9:0]  notice_col,              // 读通知 RAM 的列（读出寄存 1 拍，和 ROM 一样）
    input  wire [15:0] notice_bits,
    // 【自定义字幕】1 = 这张图有串口设的字幕，已经画在通知 RAM 里（长度 notice_len）：照普通字幕显示（浅底黑字、受 enable 控制）
    input  wire        custom,
    output wire [23:0] rgb_out
);

localparam integer BAND_W = BAND_X1 - BAND_X0;
localparam integer TEXT_Y = BAND_Y + 2;

// ---------------- 字幕点阵 ROM ----------------
wire [15:0] rom_bits;
wire        show_ntc = notice;              // 【应急改版】应急时 notice = 串口应急文字（serial_cmd 已按等级选好）
reg         ntc_q;                          // 这一帧在显示通知（帧头锁存）
wire        use_cs = custom && !show_ntc && !alert;   // 【自定义字幕】
reg         cs_q;                           // 这一帧在显示自定义字幕（帧头锁存）
wire [15:0] col_bits = (ntc_q || cs_q) ? notice_bits : rom_bits;
wire [10:0] len0, len1, len2, len3, len4, len5;
wire [12:0] raddr;

subtitle_rom u_rom (
    .clk   (clk),
    .raddr (raddr),
    .rdata (rom_bits),
    .len0  (len0), .len1 (len1), .len2 (len2),
    .len3  (len3), .len4 (len4), .len5 (len5)
);

function [10:0] slot_len;
    input [2:0] s;
    begin
        case (s)
            3'd0: slot_len = len0;
            3'd1: slot_len = len1;
            3'd2: slot_len = len2;
            3'd3: slot_len = len3;
            3'd4: slot_len = len4;
            3'd5: slot_len = len5;
            default: slot_len = 11'd0;
        endcase
    end
endfunction

// ---------------- 行号、帧头 ----------------
reg       vs_q, de_q;
reg [9:0] line_y;
wire      frame_start = vs_q && !vs;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        vs_q   <= 1'b1;
        de_q   <= 1'b0;
        line_y <= 10'd0;
    end else begin
        vs_q <= vs;
        de_q <= de;
        if (frame_start)
            line_y <= 10'd0;
        else if (de_q && !de)
            line_y <= line_y + 10'd1;
    end
end

// ---------------- 每帧更新：当前槽、长度、滚动位置 ----------------
// pos = 字幕已经从右端移进来多少像素，0 ~ len + BAND_W
reg [2:0]  cur_slot;
reg [10:0] cur_len;
reg [11:0] pos;
reg [7:0]  frame_div;
wire [10:0] new_len = (show_ntc || use_cs) ? notice_len : slot_len(slot);
reg         ntc_new_q;                      // 帧中间来的 notice_new 留到帧头

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cur_slot  <= 3'd0;
        cur_len   <= 11'd0;
        pos       <= 12'd0;
        frame_div <= 8'd0;
        ntc_q     <= 1'b0;
        ntc_new_q <= 1'b0;
        cs_q      <= 1'b0;
    end else begin
      if (notice_new)
        ntc_new_q <= 1'b1;
      if (frame_start) begin
        cur_slot  <= slot;
        cur_len   <= new_len;
        ntc_q     <= show_ntc;
        cs_q      <= use_cs;
        ntc_new_q <= notice_new;               // 正好和帧头同一拍来的留到下一帧
        // 【自定义字幕】在默认字幕和自定义字幕之间切换（换图后自定义字幕画好）也从右端重新进入
        if ((slot != cur_slot) || !(enable || show_ntc) || (show_ntc != ntc_q) || (use_cs != cs_q) || ntc_new_q) begin
            pos       <= 12'd0;                 // 换了字幕或者没在显示：下次从右端重新进入
            frame_div <= 8'd0;
        end else if (frame_div != FRAMES_PER_PX - 1) begin
            frame_div <= frame_div + 8'd1;
        end else begin
            frame_div <= 8'd0;
            pos <= (pos >= {1'b0, cur_len} + BAND_W) ? 12'd0 : (pos + 12'd1);
        end
      end
    end
end

// ---------------- 取列：按下一个像素的坐标读 ROM ----------------
// 屏幕 x 处对应字幕第 c = x − BAND_X1 + pos 列
wire [9:0]         nx = pixel_x + 10'd1;
wire signed [13:0] nc = $signed({4'd0, nx}) - BAND_X1 + $signed({2'd0, pos});
wire               n_in_band = (nx >= BAND_X0) && (nx < BAND_X1);
wire               n_vis = n_in_band && (nc >= 0) && (nc < $signed({3'd0, cur_len}));

assign raddr = {cur_slot, nc[9:0]};         // ROM 读出寄存 1 拍，正好对上下一个像素
assign notice_col = nc[9:0];                // 通知 RAM 同样

reg vis_q;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        vis_q <= 1'b0;
    else
        vis_q <= n_vis;
end

// ---------------- 叠加 ----------------
wire       show     = (enable || ntc_q) && (cur_len != 11'd0);
wire       band     = show && de && (pixel_x >= BAND_X0) && (pixel_x < BAND_X1) &&
                      (line_y >= BAND_Y) && (line_y < BAND_Y + 20);
wire [9:0] text_row = line_y - TEXT_Y;
wire       text_px  = band && (line_y >= TEXT_Y) && (line_y < TEXT_Y + 16) &&
                      vis_q && col_bits[text_row[3:0]];

assign rgb_out = text_px ? (alert ? 24'hffffff : 24'h000000) :
                 band    ? (alert ? (alert_l2 ? 24'hd86000 : 24'hc00000) : ntc_q ? 24'hffd23c : 24'he8eef2) : rgb_in;

endmodule
