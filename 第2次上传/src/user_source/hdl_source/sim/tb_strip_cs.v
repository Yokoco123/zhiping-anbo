`timescale 1ns/1ps
// 【自定义字幕】subtitle_strip：custom = 0 时和改之前（bak_sub/subtitle_strip.v，改名 subtitle_strip_prev）逐像素相同
//   （包括通知开关、换通知、换槽、enable、应急）；custom = 1 时字从通知 RAM 来、浅底黑字、受 enable 控制、
//   通知和应急优先、切换时从右端重新进入。用法 run_strip_cs.sh
module tb_strip_cs;
reg clk = 0, rst_n = 0; always #20 clk = ~clk;
reg [9:0] h = 0, v = 0;
always @(posedge clk) begin h <= (h == 799) ? 0 : h + 1; if (h == 799) v <= (v == 524) ? 0 : v + 1; end
wire de = (h < 640) && (v < 480);
wire vs = !((v >= 490) && (v < 492));
wire [9:0] px = de ? h : 10'd0;
wire [23:0] rgb_in = {h[7:0], v[7:0], 8'h40};
reg enable = 1, alert = 0, notice = 0, nnew = 0, cs = 0; reg [2:0] slot = 0; reg [10:0] nlen = 11'd300;
wire [9:0] ncol, ncol_p; reg [15:0] nbits, nbits_p;
always @(posedge clk) begin nbits <= {6'd0, ncol} ^ 16'h0F0F; nbits_p <= {6'd0, ncol_p} ^ 16'h0F0F; end   // 假的通知 RAM：读出寄存 1 拍
wire [23:0] o_new, o_prev;
subtitle_strip dut (.clk(clk), .rst_n(rst_n), .vs(vs), .de(de), .pixel_x(px), .rgb_in(rgb_in), .enable(enable), .slot(slot),
    .alert(alert), .notice(notice), .notice_len(nlen), .notice_new(nnew), .notice_col(ncol), .notice_bits(nbits),
    .custom(cs), .rgb_out(o_new));
subtitle_strip_prev ref0 (.clk(clk), .rst_n(rst_n), .vs(vs), .de(de), .pixel_x(px), .rgb_in(rgb_in), .enable(enable), .slot(slot),
    .alert(alert), .notice(notice), .notice_len(nlen), .notice_new(nnew), .notice_col(ncol_p), .notice_bits(nbits_p), .rgb_out(o_prev));
integer fails = 0, diff = 0, cmp_on = 1;
always @(posedge clk) if (de && cmp_on && (o_new !== o_prev)) diff = diff + 1;
task frames; input integer n; integer k; begin for (k = 0; k < n; k = k + 1) begin wait (v == 481); wait (v == 482); end end endtask
task expect; input c; input [8*60-1:0] msg; begin
    if (c) $display("  ok   %0s", msg); else begin $display("  FAIL %0s", msg); fails = fails + 1; end
end endtask
task pulse_new; begin @(negedge clk) nnew = 1; @(negedge clk) nnew = 0; end endtask
// 一帧里字幕条的像素：数浅底、黄底、红底、黑字
integer n_light, n_yel, n_red, n_ink;
always @(posedge clk) begin
    if (v == 480 && h == 0) begin n_light = 0; n_yel = 0; n_red = 0; n_ink = 0; end
    if (de && v >= 448 && v < 468 && h >= 8 && h < 632) begin
        if (o_new == 24'he8eef2) n_light = n_light + 1;
        if (o_new == 24'hffd23c) n_yel = n_yel + 1;
        if (o_new == 24'hc00000) n_red = n_red + 1;
        if (o_new == 24'h000000) n_ink = n_ink + 1;
    end
end
task count_frame; begin wait (v == 0); wait (v == 479); wait (v == 480); end endtask
integer i;
initial begin
    repeat (5) @(posedge clk); rst_n = 1;
    $display("== custom = 0: identical to the previous strip (slots, enable, alert, notices)");
    frames(30); slot = 2; frames(20); enable = 0; frames(5); enable = 1; frames(10); alert = 1; frames(10); alert = 0; frames(10);
    notice = 1; frames(30); pulse_new; frames(20); nlen = 11'd40; pulse_new; frames(700); alert = 1; frames(5); alert = 0; frames(10);
    notice = 0; frames(10); enable = 0; notice = 1; frames(10); notice = 0; enable = 1; slot = 1; frames(30);
    expect(diff == 0, "pixel-identical with custom = 0");
    $display("       (%0d differing pixels)", diff);
    cmp_on = 0;

    $display("== custom = 1");
    nlen = 11'd300; slot = 1; frames(5);
    @(negedge clk) cs = 1;
    frames(2);
    expect(dut.cs_q && !dut.ntc_q && dut.pos <= 2 && dut.cur_len == 11'd300, "custom: switches source, restarts from the right, length from notice_len");
    frames(400); count_frame;
    expect(n_light > 0 && n_yel == 0 && n_ink > 0, "light band with black text (normal subtitle style, not yellow)");
    for (i = 0; i < 16; i = i + 1) ;
    enable = 0; frames(2); count_frame;
    expect(n_light == 0 && n_ink == 0, "subtitle switch off: hidden");
    enable = 1; frames(2);
    expect(dut.pos <= 2, "switch on: from the right again");
    notice = 1; frames(2);
    expect(dut.ntc_q && !dut.cs_q && dut.pos <= 2, "notice has priority, restarts");
    frames(50); count_frame;
    expect(n_yel > 0, "yellow notice band");
    notice = 0; frames(2);
    expect(dut.cs_q && dut.pos <= 2, "notice gone: custom subtitle back from the right");
    alert = 1; frames(2);
    expect(!dut.cs_q && dut.cur_slot == 3'd1, "alert: emergency subtitle (custom ignored)");
    alert = 0; frames(2);
    expect(dut.cs_q, "after alert: custom again");
    frames(30); pulse_new; frames(2);
    expect(dut.pos <= 2, "redrawn (notice_new): restarts");
    frames(30); @(negedge clk) cs = 0; frames(2);
    expect(!dut.cs_q && dut.pos <= 2 && dut.cur_len == dut.len1, "custom off: default text of the slot, restarts");
    $display("RESULT fails=%0d %s", fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
endmodule
