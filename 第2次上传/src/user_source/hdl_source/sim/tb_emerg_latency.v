`timescale 1ns/1ps
// 【应急时延实测】video_transition + emergency_overlay：在一帧里不同位置拨 SW1，检查
//   1) 红框：下一个有效像素就出现，最长不超过一个场消隐（≤ 1.5ms）
//   2) 应急画面（EMERG.BMP）：tb 模拟读侧 —— 帧头锁存 show_emerg，这一帧送应急图的颜色；
//      从拨开关到第一个应急图像素 ≤ 18.4ms，而且读侧锁存的地址不会在帧头附近变（不撕裂）
//   3) 模块自己测的 emg_lat（0.1ms 一档）和 tb 量出来的一致（±0.1ms）
//   4) 没有 EMERG.BMP：内置警示页下一个有效像素就出现（≤ 1.5ms）
module tb_lat;
reg clk = 0, rst_n = 0; always #20 clk = ~clk;          // 25MHz
reg [9:0] h = 0, v = 0;
always @(posedge clk) begin
    h <= (h == 799) ? 0 : h + 1;
    if (h == 799) v <= (v == 524) ? 0 : v + 1;
end
wire de = (h < 640) && (v < 480);
wire vs = !((v >= 490) && (v < 492));

reg sw = 0, emok = 1;
// 读侧模型：帧头（vs 下降沿）后几拍锁存 show_emerg（真实读侧经过三级同步）
wire show_emerg, need_builtin, busy; wire [1:0] show_idx; wire show_thumb; wire [3:0] shown_num;
reg vs_q = 1; reg [3:0] lat_cnt = 0; reg rd_emerg = 0, rd_emerg_pend = 0;
integer chg_near_head = 0;
always @(posedge clk) begin
    vs_q <= vs;
    if (vs_q && !vs) lat_cnt <= 1;
    else if (lat_cnt != 0) lat_cnt <= lat_cnt + 1;
    if (lat_cnt == 8) rd_emerg <= show_emerg;
end
// show_emerg 在帧头前后 8 行内变化 = 可能撞上读侧锁存
reg se_d = 0;
always @(posedge clk) begin
    se_d <= show_emerg;
    if (!se_d && show_emerg && (v >= 482 && v < 498)) chg_near_head = chg_near_head + 1;   // 进入应急换地址（退出时在黑屏期换，不看）
end
wire [23:0] img = rd_emerg ? 24'h123456 : {h[7:0], v[7:0], 8'h80};
wire [23:0] t_rgb, e_rgb; wire [7:0] emg_lat; wire emg_lat_ok; wire blink;
video_transition #(.FADE_FRAMES(8), .HOLD_FRAMES(1)) vt (
    .clk(clk), .rst_n(rst_n), .vs(vs), .de(de), .rgb_in(img), .rgb_out(t_rgb),
    .display_valid(1'b1), .want_idx(2'd0), .want_auto(1'b0), .want_thumb(1'b0), .loaded(4'b1111), .want_page(1'b0), .want_pbuf(1'b0),
    .bri_pct(8'd100), .con_pct(8'd100), .want_emerg(sw), .emerg_ok(emok),
    .show_idx(show_idx), .show_thumb(show_thumb), .show_emerg(show_emerg), .need_builtin(need_builtin),
    .shown_num(shown_num), .busy(busy), .emg_lat(emg_lat), .emg_lat_ok(emg_lat_ok));
// 顶层里 emergency_overlay 的 emerg_on 是 ctrl_to_video 同步过来的，这里同样打两拍
reg sw1 = 0, sw2 = 0; always @(posedge clk) begin sw1 <= sw; sw2 <= sw1; end
emergency_overlay eo (.clk(clk), .rst_n(rst_n), .vs(vs), .de(de), .rgb_in(t_rgb), .emerg_on(sw2), .builtin_on(need_builtin),
    .level(sw2 ? 2'd1 : 2'd0), .a_len(10'd0), .a_col(), .a_bits(16'd0), .s_col(10'd0), .page_on(1'b0), .rgb_out(e_rgb), .blink(blink));

integer fails = 0;
task check; input c; input [8*70-1:0] msg; begin
    if (!c) begin $display("  FAIL %0s  (t=%0t)", msg, $time); fails = fails + 1; end
end endtask
real t0, t_border, t_pic, worst_b = 0, worst_p = 0, best_p = 1e9;
integer got_b, got_p;
// 一次：等到第 line 行第 col 列拨开关，量红框 / 画面时延
task trial; input integer line; input integer col; input integer want_pic; real tl; begin
    wait (v == line && h == col); #1;
    sw = 1; t0 = $realtime; got_b = 0; got_p = 0;
    while (!(got_b && got_p)) begin
        @(posedge clk); #1;
        if (!got_b && de && eo.border) begin got_b = 1; t_border = $realtime; end
        if (!got_p && de && (want_pic ? (vt.rgb_src == 24'h123456 && t_rgb == 24'h123456) : need_builtin)) begin got_p = 1; t_pic = $realtime; end
        if ($realtime - t0 > 40e6) begin got_b = 1; got_p = 1; t_pic = 1e12; end
    end
    wait (emg_lat_ok); #1;
    tl = (t_pic - t0) / 1e6;
    if ((t_border - t0) / 1e6 > worst_b) worst_b = (t_border - t0) / 1e6;
    if (tl > worst_p) worst_p = tl;
    if (tl < best_p) best_p = tl;
    $display("  line %3d: border %6.3f ms, picture %6.3f ms, measured by FPGA %0d.%0d ms",
             line, (t_border - t0) / 1e6, tl, emg_lat / 10, emg_lat % 10); $fflush;
    check((t_border - t0) / 1e6 <= 1.5, "border within 1.5 ms");
    check(tl <= (want_pic ? 18.4 : 1.5), "picture within bound");   // 内置页：下一个有效像素（最坏等一个场消隐）
    check((emg_lat / 10.0 - tl) <= 0.1 && (tl - emg_lat / 10.0) <= 0.1, "FPGA measurement matches");
    // 关掉，等回到普通画面（淡出 + 黑 + 淡入）
    repeat (3) @(posedge clk); sw = 0;
    wait (!show_emerg); repeat (10) begin wait (v == 500); wait (v == 501); end
end endtask

integer k;
initial begin
    repeat (10) @(posedge clk); rst_n = 1;
    repeat (12) begin wait (v == 500); wait (v == 501); end       // 第一张图淡入完
    $display("== with EMERG.BMP (picture = emergency bank)");
    trial(479, 700, 1);                                           // 刚错过最后一个可换行：最坏
    trial(478, 700, 1);                                           // 刚好赶上：最快
    trial(485, 10, 1);                                            // 消隐区
    trial(495, 10, 1);
    trial(0, 300, 1);                                             // 帧头后第 0 行（y_cnt = 0，要等一行）
    for (k = 0; k < 4; k = k + 1) trial(30 + k * 113, (k * 197) % 800, 1);
    $display("   worst border %0.3f ms, picture best %0.3f / worst %0.3f ms", worst_b, best_p, worst_p);
    check(chg_near_head == 0, "show_emerg never changes near the frame head");
    $display("== without EMERG.BMP (built-in page)");
    emok = 0;
    trial(100, 50, 0);
    trial(483, 0, 0);
    $display("RESULT fails=%0d %s", fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
endmodule
