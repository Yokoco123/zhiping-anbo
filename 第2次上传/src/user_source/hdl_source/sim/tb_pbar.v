`timescale 1ns/1ps
// 【中文参数条】param_bar_overlay：4 个选中项 / 几组数值各导出一帧上半部分（pbar_out/*.bmp），
//   并检查：不显示时画面不变；字只出现在条内；选中项有黄框
//   用法：mkdir -p pbar_out; iverilog -g2005 -o pb.out -s tb_pbar tb_pbar.v ../param_bar_overlay.v && vvp -n pb.out
module tb_pbar;
reg clk = 0, rst_n = 0; always #20 clk = ~clk;
reg [9:0] h = 0, v = 0;
always @(posedge clk) begin h <= (h == 799) ? 0 : h + 1; if (h == 799) v <= (v == 524) ? 0 : v + 1; end
wire de = (h < 640) && (v < 480);
wire vs = !((v >= 490) && (v < 492));
wire [9:0] px = de ? h : 10'd0;
reg [23:0] bg [0:307199];
wire [23:0] rgb_in = de ? bg[v * 640 + h] : 24'd0;
reg show = 0; reg [1:0] sel = 0; reg [7:0] bri = 100, con = 100, vol = 80; reg [2:0] per = 1;
wire [23:0] rgb_out;
param_bar_overlay #(.BAR_X(156), .BAR_Y(8)) dut (.clk(clk), .rst_n(rst_n), .vs(vs), .de(de), .pixel_x(px), .rgb_in(rgb_in),
    .show(show), .sel(sel), .bri_pct(bri), .con_pct(con), .vol_pct(vol), .period_idx(per), .rgb_out(rgb_out));
reg [23:0] fb [0:640*60-1];
always @(posedge clk) if (de && v < 60) fb[v * 640 + h] <= rgb_out;
integer nchg, nout, nyel;
always @(posedge clk) begin
    if (v == 480 && h == 0) begin nchg = 0; nout = 0; nyel = 0; end
    if (de && rgb_out !== rgb_in) begin
        nchg = nchg + 1;
        if (v < 4 || v >= 28 || h < 148 || h >= 156 + 328 + 8) nout = nout + 1;
    end
    if (de && rgb_out == 24'hFFD000) nyel = nyel + 1;
end
task frames; input integer n; integer k; begin for (k = 0; k < n; k = k + 1) begin wait (v == 481); wait (v == 482); end end endtask
task grab; begin frames(2); wait (v == 0 && h == 0); wait (v == 480); end endtask
task dump; input [8*40-1:0] name; integer f, x, y; reg [23:0] p; begin
    f = $fopen(name, "wb");
    $fwrite(f, "BM%c%c%c%c%c%c%c%c%c%c%c%c", 8'h36, 8'h70, 8'h01, 8'h00, 0,0,0,0, 54,0,0,0);
    $fwrite(f, "%c%c%c%c%c%c%c%c%c%c%c%c", 40,0,0,0, 8'h80,8'h02,0,0, 60,0,0,0);
    $fwrite(f, "%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c", 1,0,24,0, 0,0,0,0, 0,8'h70,8'h01,0,
            0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0);
    for (y = 59; y >= 0; y = y - 1) for (x = 0; x < 640; x = x + 1) begin p = fb[y * 640 + x]; $fwrite(f, "%c%c%c", p[7:0], p[15:8], p[23:16]); end
    $fclose(f);
end endtask
integer fails = 0;
task check; input c; input [8*60-1:0] msg; begin
    if (c) $display("  ok   %0s", msg); else begin $display("  FAIL %0s", msg); fails = fails + 1; end
end endtask
initial begin
    $readmemh("emg_prev/bg_pic3.hex", bg);
    repeat (5) @(posedge clk); rst_n = 1;
    grab; check(nchg == 0, "menu closed: picture untouched");
    show = 1;
    sel = 0; grab; dump("pbar_out/s0.bmp"); check(nchg > 0 && nout == 0 && nyel > 0, "sel 0: drawn inside the band, yellow box");
    sel = 1; bri = 20; con = 150; grab; dump("pbar_out/s1.bmp"); check(nout == 0 && nyel > 0, "sel 1");
    sel = 2; vol = 0; grab; dump("pbar_out/s2.bmp"); check(nout == 0 && nyel > 0, "sel 2");
    sel = 3; per = 5; grab; dump("pbar_out/s3.bmp"); check(nout == 0 && nyel > 0, "sel 3, 60 s");
    per = 0; grab; dump("pbar_out/s4.bmp");
    show = 0; grab; check(nchg == 0, "menu closed again: picture untouched");
    $display("RESULT fails=%0d %s", fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
endmodule
