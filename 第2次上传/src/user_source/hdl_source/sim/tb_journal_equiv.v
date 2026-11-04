`timescale 1ns/1ps
// 新旧 config_journal 对比：随机两槽内容（含 CRC 正确/错误、版本回绕、空槽），按 config_flash_journal 的节拍发 load / save
module tb_eq;
reg clk = 0, rst_n = 0; always #5 clk = ~clk;
reg p0, p1; reg [95:0] d0, d1; reg ld, sv; reg [31:0] sp; reg [7:0] svol, smode;
wire [31:0] av_o, ap_o, rv_o, rp_o, av_n, ap_n, rv_n, rp_n;
wire [7:0] avo_o, am_o, rvo_o, rm_o, avo_n, am_n, rvo_n, rm_n;
wire [15:0] rc_o, rc_n; wire ld_o, cv_o, rr_o, ts_o, ld_n, cv_n, rr_n, ts_n;
`define PORTS(sfx) .clk(clk), .rst_n(rst_n), .load_start(ld), \
  .slot0_present(p0), .slot0_version(d0[95:64]), .slot0_period(d0[63:32]), .slot0_volume(d0[31:24]), .slot0_mode(d0[23:16]), .slot0_crc(d0[15:0]), \
  .slot1_present(p1), .slot1_version(d1[95:64]), .slot1_period(d1[63:32]), .slot1_volume(d1[31:24]), .slot1_mode(d1[23:16]), .slot1_crc(d1[15:0]), \
  .load_done(ld_``sfx), .config_valid(cv_``sfx), .active_version(av_``sfx), .active_period(ap_``sfx), .active_volume(avo_``sfx), .active_mode(am_``sfx), \
  .save_start(sv), .save_period(sp), .save_volume(svol), .save_mode(smode), .record_ready(rr_``sfx), .target_slot(ts_``sfx), \
  .record_version(rv_``sfx), .record_period(rp_``sfx), .record_volume(rvo_``sfx), .record_mode(rm_``sfx), .record_crc(rc_``sfx)
config_journal_orig u_o (`PORTS(o));
config_journal      u_n (`PORTS(n));

function [15:0] crc; input [79:0] p; integer i; reg [15:0] c; begin
  c = 16'hffff; for (i = 79; i >= 0; i = i - 1) c = (c[15] ^ p[i]) ? {c[14:0],1'b0} ^ 16'h1021 : {c[14:0],1'b0}; crc = c; end endfunction
function [95:0] rec; input good; input [31:0] ver; reg [79:0] p; begin
  p = {ver, $random, 8'($random), 8'($random)}; rec = {p, good ? crc(p) : crc(p) ^ 16'h0001}; end endfunction

integer n, fails = 0, saves = 0, loads = 0; reg [31:0] v0;
// 新版 load_done / record_ready 晚几十拍到：分别锁存，比较内容
reg [102:0] got_o, got_n;
always @(posedge clk) begin
  if (rr_o) got_o <= {ts_o, rv_o, rp_o, rvo_o, rm_o, rc_o};
  if (rr_n) got_n <= {ts_n, rv_n, rp_n, rvo_n, rm_n, rc_n};
end
initial begin
  ld = 0; sv = 0; p0 = 0; p1 = 0; d0 = 0; d1 = 0; sp = 0; svol = 0; smode = 0;
  repeat (3) @(negedge clk); rst_n = 1;
  for (n = 0; n < 20000; n = n + 1) begin
    // 和 config_flash_journal 一样：写槽数据 → 下一拍 ST_LOAD_PULSE 置 load_start → 再下一拍模块看到
    v0 = (n % 7 == 0) ? 32'hFFFF_FFF0 + n[3:0] : $random;
    @(negedge clk);
    d0 = rec($random % 4 != 0, v0); p0 = ($random % 5 != 0);
    d1 = rec($random % 4 != 0, (n % 3 == 0) ? v0 + 1 : ((n % 3 == 1) ? v0 : $random)); p1 = ($random % 5 != 0);
    if (n % 11 == 0) begin d0 = {96{1'b1}}; p0 = 0; end
    @(negedge clk); ld = 1; @(negedge clk); ld = 0;
    @(posedge ld_n); @(negedge clk);
    loads = loads + 1;
    if ({cv_o, av_o, ap_o, avo_o, am_o} !== {cv_n, av_n, ap_n, avo_n, am_n}) begin
      fails = fails + 1; if (fails < 5) $display("LOAD MISMATCH n=%0d", n); end
    if (n % 2 == 0) begin
      sp = $random; svol = $random; smode = $random;
      sv = 1; @(negedge clk); sv = 0; @(posedge rr_n); @(posedge clk); @(negedge clk);
      saves = saves + 1;
      if (got_o !== got_n) begin fails = fails + 1; if (fails < 5) $display("SAVE MISMATCH n=%0d %h %h", n, got_o, got_n); end
    end
  end
  $display("RESULT loads=%0d saves=%0d fails=%0d %s", loads, saves, fails, fails == 0 ? "PASS" : "FAIL");
  $finish;
end
initial begin #2_000_000_000; $display("TIMEOUT"); $finish; end
endmodule
