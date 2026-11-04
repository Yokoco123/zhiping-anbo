`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// 控制参数 sd_card_clk → video_clk
// 这些量都是按键/拨码改的，几百毫秒才变一次：逐位打两拍后，连续两拍相同才更新输出，
// 避免多位总线在跳变那一拍被采到“一半新一半旧”的中间值。
// 顺便把音量百分数换算成 wav_player / pcm_media_tone 用的 0~255 系数。
// -----------------------------------------------------------------------------
module ctrl_to_video (
    input  wire       clk,              // video_clk
    input  wire       rst_n,
    // sd_card_clk 域
    input  wire [3:0] sw_on,
    input  wire [7:0] bri_pct,
    input  wire [7:0] con_pct,
    input  wire [7:0] vol_pct,
    input  wire       music_pause,
    input  wire [2:0] period_idx,
    input  wire [1:0] menu_sel,
    input  wire       tone_allow,       // 1 = 没有可用的 WAV，允许琶音
    // video_clk 域
    output reg  [3:0] v_sw,
    output reg  [7:0] v_bri,
    output reg  [7:0] v_con,
    output reg  [7:0] v_vol,
    output reg        v_pause,                // 背景音乐暂停：KEY3 暂停或【应急模式】（应急时放警笛，退出后接着放音乐）
    output reg  [2:0] v_period,
    output reg  [1:0] v_menu_sel,
    output reg  [7:0] wav_volume,       // 音量 100% → 250，默认 80% → 200（和原来一样）
    output reg  [7:0] tone_volume       // 琶音再低一些：默认 80% → 150；暂停或不允许时为 0
);

localparam integer W = 4 + 8 + 8 + 8 + 1 + 3 + 2 + 1;

reg          v_tone;
wire [W-1:0] din = {sw_on, bri_pct, con_pct, vol_pct, music_pause | sw_on[0], period_idx, menu_sel, tone_allow};
(* async_reg = "true" *) reg [W-1:0] s1, s2;
reg [W-1:0] s3;

wire [9:0] vol_x25 = {2'd0, v_vol} * 10'd5 >> 1;     // ×2.5

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s1          <= {W{1'b0}};
        s2          <= {W{1'b0}};
        s3          <= {W{1'b0}};
        v_sw        <= 4'd0;
        v_bri       <= 8'd100;
        v_con       <= 8'd100;
        v_vol       <= 8'd80;
        v_pause     <= 1'b0;
        v_period    <= 3'd1;
        v_menu_sel  <= 2'd0;
        v_tone      <= 1'b0;
        wav_volume  <= 8'd200;
        tone_volume <= 8'd0;
    end else begin
        s1 <= din;
        s2 <= s1;
        s3 <= s2;
        if (s2 == s3)
            {v_sw, v_bri, v_con, v_vol, v_pause, v_period, v_menu_sel, v_tone} <= s3;
        wav_volume  <= vol_x25[7:0];
        tone_volume <= (v_pause || !v_tone) ? 8'd0 : (vol_x25[7:0] - (vol_x25[7:0] >> 2));
    end
end

endmodule
