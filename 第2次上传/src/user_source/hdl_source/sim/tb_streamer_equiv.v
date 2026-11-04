`timescale 1ns/1ps
// 【时序收敛 2026-10-27】fat32_file_streamer 改之前（_old）和改之后同时读同一个随机文件，
// 比对：请求的每个扇区号、输出的每个字节和偏移、结束时的错误码。用法：sim/run_streamer_equiv.sh
//   每个文件随机：每簇扇区 1~128、FAT 起点、数据区起点、起始簇、文件大小（0 ~ 几簇）、簇链（随机跳）
//   一部分故意做坏：链提前结束、链指向越界簇、链指向自己（死循环）、起始簇越界
module tb_strm;
reg clk = 0, rst_n = 0; always #5 clk = ~clk;

// FAT 表：簇号 → 下一簇（只放 0~4095）
reg [31:0] fat [0:4095];
reg [31:0] fat_lba, data_lba;
reg [7:0]  spc;
function [7:0] card_byte; input [31:0] lba; input [8:0] i; reg [31:0] e; begin
    if (lba >= fat_lba && lba < fat_lba + 32) begin           // FAT 扇区：每扇区 128 项
        e = fat[((lba - fat_lba) << 7) + i[8:2]];
        card_byte = e[i[1:0] * 8 +: 8];
    end else
        card_byte = lba[7:0] ^ lba[15:8] ^ i[7:0] ^ {i[8], 7'd0};
end endfunction

reg start = 0;
reg [31:0] first, fsize, maxc;
wire o_busy, o_done, o_valid, o_req, os_busy, os_valid, os_done;
wire n_busy, n_done, n_valid, n_req, ns_busy, ns_valid, ns_done;
wire [7:0] o_byte, o_err, os_byte, n_byte, n_err, ns_byte;
wire [31:0] o_off, o_lba, n_off, n_lba;
wire [8:0] os_idx, ns_idx;

fat32_file_streamer_old u_old (.clk(clk), .rst_n(rst_n), .file_start(start), .first_cluster(first), .file_size(fsize),
    .sectors_per_cluster(spc), .fat_start_lba(fat_lba), .data_start_lba(data_lba), .max_cluster(maxc),
    .file_busy(o_busy), .file_done(o_done), .file_valid(o_valid), .file_byte(o_byte), .file_byte_offset(o_off),
    .fs_error(o_err), .sector_req(o_req), .sector_lba(o_lba), .sector_busy(os_busy), .sector_valid(os_valid),
    .sector_byte(os_byte), .sector_byte_index(os_idx), .sector_done(os_done), .sector_error(8'd0));
fat32_file_streamer u_new (.clk(clk), .rst_n(rst_n), .file_start(start), .first_cluster(first), .file_size(fsize),
    .sectors_per_cluster(spc), .fat_start_lba(fat_lba), .data_start_lba(data_lba), .max_cluster(maxc),
    .file_busy(n_busy), .file_done(n_done), .file_valid(n_valid), .file_byte(n_byte), .file_byte_offset(n_off),
    .fs_error(n_err), .sector_req(n_req), .sector_lba(n_lba), .sector_busy(ns_busy), .sector_valid(ns_valid),
    .sector_byte(ns_byte), .sector_byte_index(ns_idx), .sector_done(ns_done), .sector_error(8'd0));
sec_srv s_old (.clk(clk), .req(o_req), .lba(o_lba), .busy(os_busy), .valid(os_valid), .data(os_byte), .idx(os_idx), .done(os_done));
sec_srv s_new (.clk(clk), .req(n_req), .lba(n_lba), .busy(ns_busy), .valid(ns_valid), .data(ns_byte), .idx(ns_idx), .done(ns_done));

// 两边的事件流各记一份，最后逐项比
reg [63:0] o_ev [0:65535], n_ev [0:65535];
integer o_n, n_n;
always @(posedge clk) begin
    if (o_req)   begin o_ev[o_n] = {8'hA0, 24'd0, o_lba}; o_n = o_n + 1; end
    if (o_valid) begin o_ev[o_n] = {8'hB0, o_byte, 16'd0, o_off}; o_n = o_n + 1; end
    if (n_req)   begin n_ev[n_n] = {8'hA0, 24'd0, n_lba}; n_n = n_n + 1; end
    if (n_valid) begin n_ev[n_n] = {8'hB0, n_byte, 16'd0, n_off}; n_n = n_n + 1; end
end

integer seed = 11, t, i, c, nclu, bad, fails = 0, errs = 0, oks = 0, multi = 0;
reg [31:0] cl, nx;
initial begin
    repeat (5) @(posedge clk); rst_n = 1;
    for (t = 0; t < 400; t = t + 1) begin
        for (i = 0; i < 4096; i = i + 1) fat[i] = $random(seed) & 32'h0FFF_FFFF;
        spc      = 8'd1 << ($random(seed) & 7);
        if (t % 3 == 0) spc = 8'd1 << (3 + ($random(seed) & 3));  // 多一些 8~64 的
        fat_lba  = 32'd32 + ($random(seed) & 32'hFFFF);
        data_lba = fat_lba + 32'd64 + ($random(seed) & 32'hFFFFF);
        maxc     = 32'd4000;
        nclu     = 1 + ($random(seed) & 3);
        fsize    = (nclu - 1) * spc * 512 + 1 + ($random(seed) % (spc * 512));
        if (t % 9 == 0) fsize = 0;
        bad      = (t % 5 == 4) ? (1 + ($random(seed) & 3)) : 0;
        // 随机簇链
        first = 2 + ($random(seed) & 32'h7FF);
        cl = first;
        for (c = 1; c < nclu; c = c + 1) begin
            nx = 2 + ($random(seed) & 32'hFFF) % 3990;
            while (nx == cl) nx = 2 + (($random(seed) & 32'hFFF) % 3990);
            fat[cl] = nx; cl = nx;
        end
        fat[cl] = 32'h0FFF_FFFF;
        case (bad)
            1: if (nclu > 1) fat[first] = 32'h0FFF_FFF8;     // 提前结束
            2: fat[cl] = 32'd4050;                           // 最后一簇指向越界
            3: fat[cl] = cl;                                 // 指向自己
            4: first = 32'd4090;                             // 起始簇越界
            default: ;
        endcase
        o_n = 0; n_n = 0;
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        wait (!o_busy && !n_busy);
        repeat (3) @(posedge clk);
        if (o_err != 0) errs = errs + 1; else oks = oks + 1;
        if (spc > 1 && fsize > 512) multi = multi + 1;
        if (o_err !== n_err) begin $display("  MISMATCH test %0d err old=%h new=%h", t, o_err, n_err); fails = fails + 1; end
        if (o_n !== n_n)     begin $display("  MISMATCH test %0d events old=%0d new=%0d (spc %0d size %0d)", t, o_n, n_n, spc, fsize); fails = fails + 1; end
        else for (i = 0; i < o_n; i = i + 1)
            if (o_ev[i] !== n_ev[i]) begin
                if (fails < 20) $display("  MISMATCH test %0d event %0d old=%h new=%h", t, i, o_ev[i], n_ev[i]);
                fails = fails + 1; i = o_n;
            end
    end
    $display("400 files (%0d ok, %0d with errors, %0d multi-sector clusters), %0d mismatches", oks, errs, multi, fails);
    $display("RESULT %s", (fails == 0 && oks > 200 && errs > 40 && multi > 150) ? "PASS" : "FAIL");
    $finish;
end
endmodule

// 扇区服务：收到 req 后 busy，等 6 拍，每拍一个字节（比真卡快，晚一拍的寄存器最容易出问题），512 个后 done
module sec_srv (input clk, input req, input [31:0] lba, output reg busy = 0, output reg valid = 0,
                output reg [7:0] data = 0, output reg [8:0] idx = 0, output reg done = 0);
reg [31:0] a; integer c = 0, n = 0;
always @(posedge clk) begin
    valid <= 1'b0; done <= 1'b0;
    if (!busy) begin
        if (req) begin busy <= 1'b1; a <= lba; c <= 0; n <= 0; end
    end else begin
        c <= c + 1;
        if (c >= 6) begin
            if (n < 512) begin
                valid <= 1'b1; idx <= n; data <= tb_strm.card_byte(a, n); n <= n + 1;
            end else begin
                done <= 1'b1; busy <= 1'b0;
            end
        end
    end
end
endmodule
