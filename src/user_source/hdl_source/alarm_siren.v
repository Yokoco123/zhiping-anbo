`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// 【应急模式】板上警报音。【三级应急】按等级换声音：
//   一级 紧急撤离：警笛，频率在 600Hz ~ 1200Hz 之间来回扫（约 1.1 秒一个来回），一直响
//   二级 就地避险：880Hz 间歇提示音“嘀、嘀——”，2 秒一组（响 0.25 秒、停 0.25 秒、响 0.25 秒、停 1.25 秒）
//   三级 区域警戒：进入时“叮—咚”响一次（784Hz 0.35 秒 + 523Hz 0.55 秒），之后不再响，背景音乐照常
//   HDMI 音频：三角波，48kHz 采样，跟 WAV / 琶音走同一条音频通路（ACR 不用改）；active = 1 时顶层用它代替音乐
//   蜂鸣器：同频方波，低电平驱动 PNP 三极管发声，空闲保持高电平（不响）
//            板上 SW7 是蜂鸣器硬件开关，演示时嫌吵可以拨掉
// 波形显示会看到它在“扫频”——告警音被看见
// -----------------------------------------------------------------------------
module alarm_siren #(
    parameter [23:0] INC_LO  = 24'd209715,  // 600Hz  = 600  × 2^24 / 48000
    parameter [23:0] INC_HI  = 24'd419430,  // 1200Hz = 1200 × 2^24 / 48000
    parameter [23:0] SWEEP   = 24'd8,       // 每个样本频率字的变化量：(HI-LO)/8 ≈ 26214 个样本 ≈ 0.55 秒
    parameter [23:0] INC_880 = 24'd307582,  // 【三级应急】二级提示音
    parameter [23:0] INC_784 = 24'd274030,  // 三级“叮”
    parameter [23:0] INC_523 = 24'd182890   // 三级“咚”
)(
    input  wire               clk,           // video_clk
    input  wire               rst_n,
    input  wire               sample_tick,   // 48kHz 单拍
    input  wire [1:0]         level,         // 【三级应急】实际等级 0 无 1 紧急撤离 2 就地避险 3 区域警戒（video_clk 域）
    input  wire [7:0]         volume,        // 0~255
    input  wire               mute,          // 【按键改造】1 = 消音：不出声、蜂鸣器不响，但 active 照常（背景音乐不会冒出来）
    output reg  signed [15:0] out,
    output reg                active,        // 1 = 正在用警报音（顶层据此换掉背景音乐）
    output reg                buzzer_n       // 接 BUZZER 引脚，低电平响
);

reg [23:0] phase;
reg [23:0] inc;
reg        up;
reg [1:0]  lvl_d;
reg [16:0] sc;                       // 进入这一级后的样本数（二级每 2 秒从头数）

// 三角波：相位前半周上升、后半周下降，映射到 -32768 ~ +32767
wire [15:0] tri_u = phase[23] ? ~phase[22:7] : phase[22:7];
wire signed [15:0] tri_s = $signed(tri_u ^ 16'h8000);
wire signed [24:0] mul   = tri_s * $signed({1'b0, volume});

// 这一个样本响不响、用什么频率
wire        l1    = (level == 2'd1);
wire        l2    = (level == 2'd2);
wire        l3    = (level == 2'd3);
wire        l3_on = l3 && (sc < 17'd43200);                             // 0.9 秒
wire        tone  = l1 || (l2 && ((sc < 17'd12000) || ((sc >= 17'd24000) && (sc < 17'd36000)))) || l3_on;
wire [23:0] f_inc = l1 ? inc : l2 ? INC_880 : (sc < 17'd16800) ? INC_784 : INC_523;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        phase    <= 24'd0;
        inc      <= INC_LO;
        up       <= 1'b1;
        lvl_d    <= 2'd0;
        sc       <= 17'd0;
        out      <= 16'sd0;
        active   <= 1'b0;
        buzzer_n <= 1'b1;
    end else if (sample_tick) begin
        lvl_d <= level;
        if (level != lvl_d)
            sc <= 17'd0;                                               // 换了等级：从头开始
        else if (l2 && (sc == 17'd95999))
            sc <= 17'd0;
        else if (sc != 17'h1FFFF)
            sc <= sc + 17'd1;
        // 一级扫频
        if (!l1) begin
            inc <= INC_LO;
            up  <= 1'b1;
        end else if (up) begin
            if (inc >= INC_HI) up  <= 1'b0;
            else               inc <= inc + SWEEP;
        end else begin
            if (inc <= INC_LO) up  <= 1'b1;
            else               inc <= inc - SWEEP;
        end
        phase    <= tone ? (phase + f_inc) : 24'd0;
        out      <= (tone && !mute) ? mul[23:8] : 16'sd0;
        active   <= l1 || l2 || l3_on;
        buzzer_n <= (tone && !mute) ? ~phase[23] : 1'b1;
    end
end

endmodule
