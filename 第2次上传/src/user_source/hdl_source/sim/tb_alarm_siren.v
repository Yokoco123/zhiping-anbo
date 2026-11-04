`timescale 1ns/1ps
// 【三级应急】alarm_siren：一级和原来的警笛逐样本一样；二级 2 秒一组“嘀、嘀——”；三级进入时“叮—咚”0.9 秒后停
module tb_siren;
reg clk = 0, rst_n = 0; always #20 clk = ~clk;
reg tick = 0; integer tc = 0;
always @(posedge clk) begin tc = (tc == 520) ? 0 : tc + 1; tick <= (tc == 0); end   // 25MHz / 521 ≈ 48kHz
reg [1:0] level = 0;
wire signed [15:0] o_new, o_old; wire act, bz_n, bz_o;
alarm_siren     n (.clk(clk), .rst_n(rst_n), .sample_tick(tick), .level(level), .volume(8'd200), .out(o_new), .active(act), .buzzer_n(bz_n));
alarm_siren_old o (.clk(clk), .rst_n(rst_n), .sample_tick(tick), .enable(level == 2'd1), .volume(8'd200), .out(o_old), .buzzer_n(bz_o));
integer fails = 0, s, diff, on, act_n, edges, k;
reg prev_on;
task check; input c; input [8*60-1:0] msg; begin
    if (c) $display("  ok   %0s", msg); else begin $display("  FAIL %0s", msg); fails = fails + 1; end
end endtask
initial begin
    repeat (5) @(posedge clk); rst_n = 1;
    // 一级：3 秒逐样本比
    level = 1; diff = 0;
    for (s = 0; s < 144000; s = s + 1) begin @(posedge tick); @(posedge clk); #1; if (o_new !== o_old || bz_n !== bz_o) diff = diff + 1; end
    check(diff == 0 && act, "level 1 = old siren, sample by sample (3 s)");
    // 二级：4 秒，统计发声的样本数和“响”的段数
    level = 2; on = 0; edges = 0; act_n = 0; prev_on = 0;
    for (s = 0; s < 192000; s = s + 1) begin
        @(posedge tick); @(posedge clk); #1;
        if (o_new != 0 || !bz_n) begin on = on + 1; if (!prev_on) edges = edges + 1; prev_on = 1; end
        else if (s % 480 == 0) prev_on = 0;                       // 静音 10ms 以上才算一段结束
        if (act) act_n = act_n + 1;
    end
    $display("       level 2: %0d samples with sound, %0d beeps in 4 s", on, edges);
    check(edges == 4 && on > 44000 && on <= 48100 && act_n == 192000, "level 2: two beeps every 2 s, music stays muted");
    // 三级：进入时响 0.9 秒，然后 active = 0
    level = 3; on = 0; act_n = 0;
    for (s = 0; s < 96000; s = s + 1) begin
        @(posedge tick); @(posedge clk); #1;
        if (o_new != 0) on = on + 1;
        if (act) act_n = act_n + 1;
    end
    $display("       level 3: %0d samples with sound, active for %0d samples", on, act_n);
    check(act_n >= 43190 && act_n <= 43210 && on <= 43210 && on > 40000 && !act, "level 3: one chime of 0.9 s, then music back");
    level = 0;
    repeat (2) @(posedge tick); @(posedge clk); #1;
    check(!act && o_new == 0 && bz_n, "level 0: silent, buzzer off");
    $display("RESULT fails=%0d %s", fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
endmodule
