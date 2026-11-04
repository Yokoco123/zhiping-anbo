`timescale 1ns/1ps
// 【省资源 第4轮】serial_cmd 的 gidx 新写法 和 原写法 全部 65536 个编码逐个比
module tb_gidx;
function [15:0] gidx_old;
    input [15:0] cp;
    begin
        if      (cp >= 16'h0020 && cp <= 16'h007E) gidx_old = cp - 16'h0020;
        else if (cp >= 16'h00A0 && cp <= 16'h00FF) gidx_old = cp - 16'h00A0 + 16'd95;
        else if (cp >= 16'h2000 && cp <= 16'h206F) gidx_old = cp - 16'h2000 + 16'd191;
        else if (cp >= 16'h3000 && cp <= 16'h303F) gidx_old = cp - 16'h3000 + 16'd303;
        else if (cp >= 16'h4E00 && cp <= 16'h9FFF) gidx_old = cp - 16'h4E00 + 16'd367;
        else if (cp >= 16'hFF00 && cp <= 16'hFFEF) gidx_old = cp - 16'hFF00 + 16'd21359;
        else                                       gidx_old = 16'hFFFF;
    end
endfunction
`include "gidx_new.vh"
integer i, bad = 0;
initial begin
    for (i = 0; i < 65536; i = i + 1) if (gidx(i) !== gidx_old(i)) begin
        if (bad < 5) $display("  MISMATCH %h old %h new %h", i[15:0], gidx_old(i), gidx(i));
        bad = bad + 1;
    end
    $display("65536 codes, %0d mismatches  RESULT %s", bad, bad == 0 ? "PASS" : "FAIL");
end
endmodule
