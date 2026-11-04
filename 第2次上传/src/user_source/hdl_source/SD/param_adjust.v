`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// 参数菜单（sd_card_clk 域，在 sd_card_bmp4 里例化）
// 参考参考例程 param_menu_controller.v：按键事件 → 改参数 → 下游立即生效。
//
//   SW2 打开菜单（menu_on），菜单里：
//     Key1 短按 = 下一项，Key2 短按 = 上一项（循环）：亮度 → 对比度 → 音量 → 轮播周期
//     KEY3 = 加，Key4 = 减：按下立即走一步（细调），按住超过 HOLD_MS 每 REPEAT_MS 走一大步（粗调）
//   关掉菜单再打开，停在上次选中的那一项
//
// 输出：
//   亮度 20~150%（默认 100），对比度 50~150%（默认 100），音量 0~100%（默认 80）
//   轮播周期档位 0~5 = 1/3/5/10/30/60 秒（默认 1 档 = 3 秒），到头就停，不循环
//   【参数掉电保存】上电后 param_store 从 Flash 读出上次的值，通过 load_valid 覆盖默认值
// -----------------------------------------------------------------------------
module param_adjust #(
    parameter integer CLK_FREQ_HZ = 100_000_000,   // 不再用（定时改数 ms_tick），保留免得改例化
    parameter integer HOLD_MS     = 500,           // HOLD_MS / REPEAT_MS 不超过 1023
    parameter integer REPEAT_MS   = 200,
    parameter [7:0]   FINE_STEP   = 8'd2,
    parameter [7:0]   COARSE_STEP = 8'd10
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       ms_tick,          // 【省资源】上层的 1ms 节拍，长按 / 连发按毫秒数
    input  wire       menu_on,          // SW2
    input  wire       item_prev,        // Key2 短按脉冲
    input  wire       item_next,        // Key1 短按脉冲
    input  wire       plus_level,       // KEY3 消抖后的电平，按下为 0
    input  wire       minus_level,      // Key4
    output reg  [1:0] sel,              // 当前选中项 0 亮度 1 对比度 2 音量 3 轮播周期
    output reg  [7:0] bri_pct,
    output reg  [7:0] con_pct,
    output reg  [7:0] vol_pct,
    output reg  [2:0] period_idx,
    // 【参数掉电保存】param_store 上电从 Flash 读到有效记录时，单拍 load_valid 把值载入
    input  wire       load_valid,
    input  wire [7:0] ld_bri,
    input  wire [7:0] ld_con,
    input  wire [7:0] ld_vol,
    input  wire [2:0] ld_period
);

localparam [2:0]   PERIOD_MAX    = 3'd5;

// ---------------- 按下 / 连发 ----------------
// 按下那一拍出细调脉冲；按满 HOLD 后每 REPEAT 出一个粗调脉冲（计数单位：毫秒）
reg        p_d, m_d;
reg [9:0]  p_cnt, m_cnt;
reg        p_fine, p_coarse, m_fine, m_coarse;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        p_d <= 1'b1; m_d <= 1'b1;
        p_cnt <= 10'd0; m_cnt <= 10'd0;
        p_fine <= 1'b0; p_coarse <= 1'b0;
        m_fine <= 1'b0; m_coarse <= 1'b0;
    end else begin
        p_d <= plus_level;
        m_d <= minus_level;
        p_fine <= 1'b0; p_coarse <= 1'b0;
        m_fine <= 1'b0; m_coarse <= 1'b0;

        if (plus_level) begin
            p_cnt <= 10'd0;
        end else if (p_d) begin
            p_fine <= 1'b1;                       // 刚按下
            p_cnt  <= 10'd0;
        end else if (ms_tick) begin
            if (p_cnt >= HOLD_MS - 1) begin
                p_coarse <= 1'b1;
                p_cnt    <= HOLD_MS - REPEAT_MS;
            end else begin
                p_cnt <= p_cnt + 10'd1;
            end
        end

        if (minus_level) begin
            m_cnt <= 10'd0;
        end else if (m_d) begin
            m_fine <= 1'b1;
            m_cnt  <= 10'd0;
        end else if (ms_tick) begin
            if (m_cnt >= HOLD_MS - 1) begin
                m_coarse <= 1'b1;
                m_cnt    <= HOLD_MS - REPEAT_MS;
            end else begin
                m_cnt <= m_cnt + 10'd1;
            end
        end
    end
end

wire       inc  = menu_on & (p_fine | p_coarse);
wire       dec  = menu_on & (m_fine | m_coarse);
wire [7:0] step = (p_coarse | m_coarse) ? COARSE_STEP : FINE_STEP;

// 带上下限的加减
function [7:0] adj;
    input [7:0] v;
    input [7:0] lo;
    input [7:0] hi;
    input       up;
    input [7:0] s;
    begin
        if (up)
            adj = (v + s > hi) ? hi : (v + s);
        else
            adj = (v < lo + s) ? lo : (v - s);
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sel        <= 2'd0;
        bri_pct    <= 8'd100;
        con_pct    <= 8'd100;
        vol_pct    <= 8'd80;
        period_idx <= 3'd1;
    end else if (load_valid) begin
        bri_pct    <= ld_bri;
        con_pct    <= ld_con;
        vol_pct    <= ld_vol;
        period_idx <= ld_period;
    end else begin
        // 选项：菜单打开时 Key1 / Key2 左右移动，循环
        if (menu_on && item_next && !item_prev)
            sel <= sel + 2'd1;
        else if (menu_on && item_prev && !item_next)
            sel <= sel - 2'd1;

        // 数值：同时按下 KEY3 和 Key4 时不动
        if (inc ^ dec) begin
            case (sel)
                2'd0: bri_pct <= adj(bri_pct, 8'd20, 8'd150, inc, step);
                2'd1: con_pct <= adj(con_pct, 8'd50, 8'd150, inc, step);
                2'd2: vol_pct <= adj(vol_pct, 8'd0,  8'd100, inc, step);
                default: begin
                    // 轮播周期每次只走一档（粗调也一样），到头就停
                    if (inc && (period_idx != PERIOD_MAX))
                        period_idx <= period_idx + 3'd1;
                    else if (dec && (period_idx != 3'd0))
                        period_idx <= period_idx - 3'd1;
                end
            endcase
        end
    end
end

endmodule
