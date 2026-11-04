`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// Key1 长按复位：按住满 HOLD_MS 才发复位请求，松手后系统重新启动
// Key1 短按是“下一张”（在 sd_card_bmp4 里处理），两者靠按住时间区分。
// 本模块在 50MHz 原始时钟域，自己不接复位（上电靠寄存器初值），
// 否则复位请求会把自己也复位掉。
// 按键抖动会让计数清零，所以不需要另外消抖。
// -----------------------------------------------------------------------------
module key_reset_req #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer HOLD_MS     = 3000
)(
    input  wire clk,
    input  wire key_n,          // 按下为 0
    output reg  rst_req = 1'b0  // 1 = 请求复位，一直保持到松手
);

localparam integer HOLD_CYCLES = (CLK_FREQ_HZ / 1000) * HOLD_MS;

(* async_reg = "true" *) reg k_s1 = 1'b1, k_s2 = 1'b1;
reg [31:0] cnt = 32'd0;

always @(posedge clk) begin
    k_s1 <= key_n;
    k_s2 <= k_s1;
    if (k_s2) begin
        cnt     <= 32'd0;
        rst_req <= 1'b0;
    end else if (cnt < HOLD_CYCLES - 1) begin
        cnt <= cnt + 32'd1;
    end else begin
        rst_req <= 1'b1;
    end
end

endmodule
