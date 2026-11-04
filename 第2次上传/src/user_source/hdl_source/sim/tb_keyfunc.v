`timescale 1ns/1ps
// 【按键改造】sd_card_bmp4（含 param_store / serial_cmd）+ W25Q64 模型：按键、干接点、开关掉电保存
//   CLK_FREQ_HZ = 100kHz：1ms = 100 拍；卡不接（SD_MISO = 1），只看按键 / 开关 / 应急等级 / 消音
//   1 上电空 Flash：轮播开、字幕波形开
//   2 Key4 短按：轮播关；保存进 Flash；复位后还是关
//   3 KEY3 长按：字幕波形关；KEY3 短按：音乐暂停 / 继续（不再是按下就触发）
//   4 Key4 长按：一级应急；KEY3 短按 = 消音（音乐不动）；Key4 长按：解除，消音取消
//   5 干接点：1ms 毛刺不算；接地 5ms = 一级应急；断开不解除；Key4 长按解除
//   6 菜单（SW2）打开：Key4 长按 / KEY3 长按 / Key4 短按都只调参数，不动开关和应急
//   7 【波形开关】KEY3 + Key2 同时按：波形开关翻转，不触发音乐 / 翻页 / 字幕 / 缩略图；掉电保存；字幕开关不影响波形
module tb_keyfunc;
localparam integer FHZ = 100_000;
localparam integer MS  = FHZ / 1000;
defparam dut.u_param_store.CLK_FREQ_HZ = 100_000_000;   // param_store 按 us 数拍子：给大一点，免得算成 0
reg clk = 0, rst = 1; always #5 clk = ~clk;
reg k_next = 1, k_auto = 1, k_prev = 1, k_plus = 1, xa_n = 1;
reg [3:0] sw = 4'b0000;
wire [3:0] sw_on, ps_status; wire mpause, mute_on, alm_mute; wire [1:0] alm_lvl;
wire cs_n, sclk, mosi, miso;
sd_card_bmp4 #(.CLK_FREQ_HZ(FHZ)) dut (
    .clk(clk), .rst(rst), .key_next(k_next), .key_auto(k_auto), .key_prev(k_prev), .key_plus(k_plus), .sw(sw),
    .sw_on(sw_on), .ext_alarm_n(xa_n), .mute_on(mute_on),
    .bri_pct(), .con_pct(), .vol_pct(), .music_pause(mpause), .period_idx(), .menu_sel(), .tone_allow(),
    .write_emerg(), .emerg_ok(), .bmp_width(16'd640), .bmp_height(16'd480), .display_valid(),
    .state_code(), .img_num(), .err_code(), .auto_on(), .thumb_mode(), .loaded_mask(), .switch_auto(),
    .trans_busy(1'b0), .music_byte_valid(), .music_byte(), .music_off(), .music_hold(1'b0),
    .write_finish_toggle(1'b0), .write_buf_idx(), .disp_buf_idx(), .write_req(),
    .write_req_ack(1'b0), .write_en(), .write_data(),
    .SD_nCS(), .SD_DCLK(), .SD_MOSI(), .SD_MISO(1'b1),
    .FLASH_CS_N(cs_n), .FLASH_SCLK(sclk), .FLASH_MOSI(mosi), .FLASH_WP_N(), .FLASH_HOLD_N(), .FLASH_MISO(miso),
    .param_store_status(ps_status), .boot_info(),
    .uart_rx(1'b1), .uart_tx(), .vclk(clk), .vrst_n(!rst), .ntc_col(10'd0), .ntc_bits(), .ntc_on(), .ntc_len(), .ntc_new(),
    .ntc_reject(), .ntc_sub_off(), .alm_col(10'd0), .alm_lvl(alm_lvl), .alm_len(), .alm_mute(alm_mute),
    .want_page(), .want_pbuf(), .page_info(), .pv_sel(1'b0), .pv_buf(1'b0), .pv_col(11'd0), .pv_meta());
w25q64_model flash (.cs_n(cs_n), .sclk(sclk), .mosi(mosi), .miso(miso));

wire osd = sw_on[3], auto = sw_on[2], take = sw_on[0];
integer fails = 0;
task check; input c; input [8*72-1:0] msg; begin
    if (c) $display("  ok   %0s", msg); else begin $display("  FAIL %0s  (t=%0t)", msg, $time); fails = fails + 1; end
end endtask
task wait_ms; input integer n; begin repeat (n * MS) @(negedge clk); end endtask
task bounce_to; input integer which; input v; integer i; begin
    for (i = 0; i < 6; i = i + 1) begin set_key(which, i[0] ? v : ~v); wait_ms(1); end
    set_key(which, v);
end endtask
task set_key; input integer which; input v; begin
    case (which) 0: k_next = v; 1: k_auto = v; 2: k_prev = v; default: k_plus = v; endcase
end endtask
task press; input integer which; input integer hold_ms; begin
    bounce_to(which, 1'b0); wait_ms(hold_ms); bounce_to(which, 1'b1); wait_ms(200);
end endtask
localparam K4 = 1, K3 = 3;
// 等 param_store 回到空闲（保存完 / 启动读完）
task wait_ps; begin wait_ms(5); wait (dut.u_param_store.pc == 4'd7 && !dut.u_param_store.pend); wait_ms(5); end endtask
task boot; begin
    rst = 1; wait_ms(1); rst = 0;
    wait (dut.u_param_store.pc == 4'd7);                  // 读完记录
    wait (dut.u_serial_cmd.st == 7'd1);                    // 串口读完启事、字库
    wait_ms(5);
end endtask

integer p0, s0;
// 背景音乐暂停 / 继续那段要等 TF 卡初始化完才执行（这里没接卡），所以数“会切音乐的 KEY3 短按”
integer n_mus = 0;
always @(posedge clk) if (dut.key_plus_short && !dut.param_mode && !dut.emerg_mode) n_mus = n_mus + 1;
// 【波形开关】Key2、KEY3 各自的短按 / 长按事件都数一下（组合键时一个都不能有）
integer n_k2 = 0, n_k3 = 0;
always @(posedge clk) begin
    if (dut.key_next_short || dut.key_next_long) n_k2 = n_k2 + 1;
    if (dut.key_plus_short || dut.key_plus_long) n_k3 = n_k3 + 1;
end
// 组合键：先按 first，过 gap 毫秒再按另一个，一起按住 hold 毫秒，first 先松，再过 gap 毫秒松另一个
task combo; input integer first; input integer gap; input integer hold; integer other; begin
    other = (first == K3) ? 0 : K3;
    bounce_to(first, 1'b0); wait_ms(gap); bounce_to(other, 1'b0); wait_ms(hold);
    bounce_to(first, 1'b1); wait_ms(gap); bounce_to(other, 1'b1); wait_ms(200);
end endtask
integer a2, a3;
initial begin
    repeat (20) @(negedge clk);
    $display("== 1 first power-up, blank flash");
    boot;
    check(auto && osd && !take && ps_status == 4'h2, "auto on, OSD on, no emergency, no saved record");

    $display("== 2 Key4 short: auto off, saved, still off after reset");
    press(K4, 150);
    check(!auto && osd, "auto off");
    wait_ps;
    check(ps_status == 4'h5, "saved to flash (status 5)");
    boot;
    check(!auto && osd && ps_status == 4'h1, "after reset: auto still off (record loaded)");
    press(K4, 150);
    check(auto, "Key4 short again: auto on");
    wait_ps;

    $display("== 3 KEY3 long: OSD off; KEY3 short: music");
    p0 = mpause;
    s0 = n_mus;
    press(K3, 1300);
    check(!osd && n_mus == s0, "KEY3 long: OSD off, no music event");
    s0 = n_mus;
    press(K3, 150);
    check(n_mus == s0 + 1, "KEY3 short: music toggle event");
    press(K3, 1300);
    check(osd, "KEY3 long again: OSD on");
    wait_ps;
    boot;
    check(auto && osd, "after reset: both on again");

    $display("== 4 Key4 long: level-1 emergency, KEY3 short = mute");
    press(K4, 1300);
    wait_ms(2);
    check(take && dut.sc_alm == 2'd1 && alm_lvl == 2'd1 && auto, "Key4 long: level 1 (auto switch untouched)");
    s0 = n_mus;
    press(K3, 150);
    wait_ms(2);
    check(mute_on && alm_mute && n_mus == s0, "KEY3 short in emergency: muted, no music event");
    press(K4, 1300);
    wait_ms(2);
    check(!take && dut.sc_alm == 2'd0 && !mute_on && !alm_mute, "Key4 long again: cleared, mute reset");
    s0 = n_mus;
    press(K3, 150);
    check(!mute_on && n_mus == s0 + 1, "KEY3 short with no emergency: music event, not mute");

    $display("== 5 dry contact");
    xa_n = 0; wait_ms(1); xa_n = 1; wait_ms(20);
    check(!take, "1 ms glitch ignored");
    xa_n = 0; wait_ms(5);
    check(take && dut.sc_alm == 2'd1, "contact closed 5 ms: level 1");
    xa_n = 1; wait_ms(20);
    check(take, "contact opened: still level 1 (latched)");
    press(K4, 1300); wait_ms(2);
    check(!take, "Key4 long: cleared");
    xa_n = 0; wait_ms(10);
    check(take, "closed again: level 1 again");
    press(K3, 150); wait_ms(2);
    check(mute_on, "muted");
    press(K4, 1300); wait_ms(2);
    check(!take && !mute_on, "Key4 long while the contact is still closed: cleared (edge-triggered, stays clear)");
    wait_ms(50);
    check(!take, "still clear while closed");
    xa_n = 1; wait_ms(20);

    $display("== 6 menu open: keys only adjust parameters");
    sw = 4'b0010; wait_ms(10);
    s0 = dut.vol_pct;
    press(K4, 1300);
    press(K3, 1300);
    press(K4, 150);
    wait_ms(2);
    check(!take && auto && osd, "menu: no emergency, no switch change");
    sw = 4'b0000; wait_ms(10);
    wait_ps;

    $display("== 7 KEY3 + Key2 together: waveform switch");
    check(dut.wave_st && osd, "waveform on by default");
    a2 = n_k2; a3 = n_k3;
    combo(K3, 100, 300);
    check(!dut.wave_st && osd && auto && n_k2 == a2 && n_k3 == a3, "combo (KEY3 first): waveform off, no other key event");
    wait_ps;
    check(ps_status == 4'h5, "saved to flash");
    boot;
    check(!dut.wave_st && osd && auto, "after reset: waveform still off, subtitle on");
    a2 = n_k2; a3 = n_k3;
    combo(0, 300, 1500);
    check(dut.wave_st && osd && !dut.thumb_mode && n_k2 == a2 && n_k3 == a3, "combo (Key2 first, held 1.5 s): waveform on, no long-press action");
    wait_ps;
    press(K3, 1300);
    check(!osd && dut.wave_st, "KEY3 long: subtitle off, waveform stays on");
    wait_ps;
    boot;
    check(!osd && dut.wave_st, "after reset: subtitle off, waveform on");
    press(K3, 1300);
    check(osd, "KEY3 long: subtitle on again");
    a3 = n_k3;
    press(K3, 150);
    check(n_k3 == a3 + 1, "KEY3 alone still works after combos");
    sw = 4'b0010; wait_ms(10);
    combo(K3, 100, 300);
    check(dut.wave_st, "menu open: combo does nothing to the waveform");
    sw = 4'b0000; wait_ms(10);
    wait_ps;

    $display("RESULT fails=%0d %s", fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
initial begin #600_000_000; $display("TIMEOUT"); $finish; end
endmodule
