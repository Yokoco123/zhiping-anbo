`timescale 1ns/1ps
// 【省资源】fat32_volume_scanner 等价性：改之前（_old）和改之后同时扫同一张随机生成的卡，
// 比对全部输出和每次请求的扇区号。用法：sim/run_scan_equiv.sh
//   每张卡随机：有没有分区表（MBR 0x0B/0x0C）、分区起点、每簇扇区 1~128、保留扇区、FAT 个数 1/2、FAT 大小、总扇区、
//   根目录簇、根目录里 PIC1~4 / MUSIC / EMERG 哪些有、位置、起始簇、大小、修改时间，夹杂删除项和别的文件
//   其中一部分故意做坏：没有 55AA、每簇扇区不是 2 的幂、每扇区不是 512、FAT 个数 3、根目录簇 < 2
module tb_scan;
reg clk = 0, rst_n = 0; always #5 clk = ~clk;

// ---------------- 卡内容 ----------------
reg [7:0]  mbr [0:511];
reg [7:0]  bs  [0:511];
reg [7:0]  dir [0:511];
reg [31:0] lba_bs, lba_dir;
reg        has_mbr;

function [7:0] card_byte; input [31:0] lba; input [8:0] i; begin
    if (lba == 0 && has_mbr)          card_byte = mbr[i];
    else if (lba == lba_bs)           card_byte = bs[i];
    else if (lba == lba_dir)          card_byte = dir[i];
    else                              card_byte = lba[7:0] ^ i[7:0];   // 别的扇区：垃圾
end endfunction

// ---------------- 两个扫描器 + 各自的扇区服务 ----------------
reg start = 0;
wire o_busy, o_done, o_req, o_s_busy, o_s_valid, o_s_done, o_mv, o_ev;
wire [7:0] o_err, o_spc, o_s_byte; wire [8:0] o_s_idx; wire [3:0] o_rv;
wire [31:0] o_plba, o_fat, o_data, o_maxc, o_c0, o_c1, o_c2, o_c3, o_z0, o_z1, o_z2, o_z3, o_mc, o_mz, o_ec, o_ez, o_sig, o_lba;
wire n_busy, n_done, n_req, n_s_busy, n_s_valid, n_s_done, n_mv, n_ev;
wire [7:0] n_err, n_spc, n_s_byte; wire [8:0] n_s_idx; wire [3:0] n_rv;
wire [31:0] n_plba, n_fat, n_data, n_maxc, n_c0, n_c1, n_c2, n_c3, n_z0, n_z1, n_z2, n_z3, n_mc, n_mz, n_ec, n_ez, n_sig, n_lba;

fat32_volume_scanner_old u_old (.clk(clk), .rst_n(rst_n), .scan_start(start), .scan_busy(o_busy), .scan_done(o_done),
    .fs_error(o_err), .partition_lba(o_plba), .sectors_per_cluster(o_spc), .fat_start_lba(o_fat), .data_start_lba(o_data),
    .max_cluster(o_maxc), .resource_valid(o_rv), .resource0_cluster(o_c0), .resource1_cluster(o_c1), .resource2_cluster(o_c2),
    .resource3_cluster(o_c3), .resource0_size(o_z0), .resource1_size(o_z1), .resource2_size(o_z2), .resource3_size(o_z3),
    .music_valid(o_mv), .music_cluster(o_mc), .music_size(o_mz), .emerg_valid(o_ev), .emerg_cluster(o_ec), .emerg_size(o_ez),
    .dir_signature(o_sig), .sector_req(o_req), .sector_lba(o_lba), .sector_busy(o_s_busy), .sector_valid(o_s_valid),
    .sector_byte(o_s_byte), .sector_byte_index(o_s_idx), .sector_done(o_s_done), .sector_error(8'd0));
fat32_volume_scanner u_new (.clk(clk), .rst_n(rst_n), .scan_start(start), .scan_busy(n_busy), .scan_done(n_done),
    .fs_error(n_err), .partition_lba(n_plba), .sectors_per_cluster(n_spc), .fat_start_lba(n_fat), .data_start_lba(n_data),
    .max_cluster(n_maxc), .resource_valid(n_rv), .resource0_cluster(n_c0), .resource1_cluster(n_c1), .resource2_cluster(n_c2),
    .resource3_cluster(n_c3), .resource0_size(n_z0), .resource1_size(n_z1), .resource2_size(n_z2), .resource3_size(n_z3),
    .music_valid(n_mv), .music_cluster(n_mc), .music_size(n_mz), .emerg_valid(n_ev), .emerg_cluster(n_ec), .emerg_size(n_ez),
    .dir_signature(n_sig), .sector_req(n_req), .sector_lba(n_lba), .sector_busy(n_s_busy), .sector_valid(n_s_valid),
    .sector_byte(n_s_byte), .sector_byte_index(n_s_idx), .sector_done(n_s_done), .sector_error(8'd0));

sec_server s_old (.clk(clk), .req(o_req), .lba(o_lba), .busy(o_s_busy), .valid(o_s_valid), .data(o_s_byte), .idx(o_s_idx), .done(o_s_done));
sec_server s_new (.clk(clk), .req(n_req), .lba(n_lba), .busy(n_s_busy), .valid(n_s_valid), .data(n_s_byte), .idx(n_s_idx), .done(n_s_done));

// 请求的扇区号序列：各记一份
reg [31:0] o_seq [0:7], n_seq [0:7];
integer o_n = 0, n_n = 0;
always @(posedge clk) begin
    if (o_req) begin o_seq[o_n & 7] = o_lba; o_n = o_n + 1; end
    if (n_req) begin n_seq[n_n & 7] = n_lba; n_n = n_n + 1; end
end

// ---------------- 随机生成一张卡 ----------------
task put32; input integer which; input integer a; input [31:0] v; begin
    case (which)
        0: begin mbr[a] = v[7:0]; mbr[a+1] = v[15:8]; mbr[a+2] = v[23:16]; mbr[a+3] = v[31:24]; end
        1: begin bs[a]  = v[7:0]; bs[a+1]  = v[15:8]; bs[a+2]  = v[23:16]; bs[a+3]  = v[31:24]; end
        default: begin dir[a] = v[7:0]; dir[a+1] = v[15:8]; dir[a+2] = v[23:16]; dir[a+3] = v[31:24]; end
    endcase
end endtask
task put16; input integer which; input integer a; input [15:0] v; begin
    case (which)
        0: begin mbr[a] = v[7:0]; mbr[a+1] = v[15:8]; end
        1: begin bs[a]  = v[7:0]; bs[a+1]  = v[15:8]; end
        default: begin dir[a] = v[7:0]; dir[a+1] = v[15:8]; end
    endcase
end endtask
task name11; input integer slot; input [87:0] nm; integer i; begin
    for (i = 0; i < 11; i = i + 1) dir[slot * 32 + i] = nm[87 - i * 8 -: 8];
    dir[slot * 32 + 11] = 8'h20;
end endtask

integer seed = 7, i, k, slot, bad;
reg [7:0]  spc;
reg [2:0]  shift;
reg [15:0] rsv;
reg [7:0]  nfat;
reg [31:0] fsz, tot, rootc, plba, v;
task make_card; input integer test; begin
    for (i = 0; i < 512; i = i + 1) begin mbr[i] = $random(seed); bs[i] = $random(seed); dir[i] = 8'h00; end
    has_mbr = $random(seed) & 1;
    plba    = has_mbr ? (($random(seed) & 32'h000F_FFFF) | 32'h0000_0800) : 32'd0;
    shift   = $random(seed) & 7;
    spc     = 8'd1 << shift;
    rsv     = 16'd1 + ($random(seed) & 16'h03FF);
    nfat    = ($random(seed) & 1) ? 8'd2 : 8'd1;
    fsz     = 32'd1 + ($random(seed) & 32'h0000_7FFF);
    tot     = $random(seed);
    rootc   = 32'd2 + ($random(seed) & 32'h0000_0FFF);
    if (test % 5 == 4) tot = $random(seed) & 32'h0000_FFFF;   // 偶尔让 总扇区 < 保留 + FAT（减法回绕，看两边是否一样）
    bad = (test % 7 == 3) ? (1 + ($random(seed) & 15)) : 0;    // 1~7：各种坏法，0 = 好卡（有时 8 = 好卡）
    // 引导扇区
    bs[0] = 8'hEB; bs[1] = 8'h58; bs[2] = 8'h90;
    put16(1, 11, 512); bs[13] = spc; put16(1, 14, rsv); bs[16] = nfat; put16(1, 17, 0); put16(1, 22, 0);
    put32(1, 32, tot == 0 ? 32'd1 : tot); put32(1, 36, fsz); put32(1, 44, rootc);
    bs[510] = 8'h55; bs[511] = 8'hAA;
    case (bad)
        1: bs[511] = 8'h00;                      // 没有签名
        2: bs[13]  = 8'd3;                       // 每簇扇区不是 2 的幂
        3: put16(1, 11, 4096);
        4: bs[16]  = 8'd3;
        5: put32(1, 44, 1);                      // 根目录簇 < 2
        6: bs[0]   = 8'h00;                      // 无 MBR 时：既不是引导扇区也不是分区表
        8: bs[17] = 8'h01;
        9: bs[23] = 8'h01;
        10: put16(1, 14, 0);
        11: put32(1, 32, 0);
        12: put32(1, 36, 0);
        13: bs[12] = 8'h01;
        14: bs[510] = 8'h54;
        15: bs[16] = 8'h00;
        16: bs[0] = 8'hE9;                     // 好卡的另一种跳转指令
        default: ;
    endcase
    // MBR
    if (has_mbr) begin
        mbr[0] = 8'h33; mbr[450] = ($random(seed) & 1) ? 8'h0B : 8'h0C; put32(0, 454, plba);
        mbr[510] = 8'h55; mbr[511] = 8'hAA;
        if (bad == 7) mbr[450] = 8'h07;          // NTFS：不支持
    end
    lba_bs  = plba;
    // 根目录在哪（和设计无关的独立算法）
    lba_dir = plba + rsv + nfat * fsz + ((rootc - 2) << shift);
    // 先在一半的槽里放“只差一个字节”的名字（不能被认成目标文件），带随机簇号、大小、时间；真文件后放，可能覆盖它们
    for (k = 0; k < 16; k = k + 1) if ($random(seed) & 1) begin
        case ($random(seed) & 15)
            0: name11(k, "PIC1X   BMP"); 1: name11(k, "MUSICA  WAV"); 2: name11(k, "EMERG1  BMP"); 3: name11(k, "PIC0    BMP");
            4: name11(k, "PIC1    BMQ"); 5: name11(k, "PIC5    BMP"); 6: name11(k, "MUSIC   WAX"); 7: name11(k, "EMERG   BMQ");
            8: name11(k, "QIC3    BMP"); 9: name11(k, "PJC2    BMP"); 10: name11(k, "PIC4   XBMP"); 11: name11(k, "NUSIC   WAV");
            12: name11(k, "EMEXG   BMP"); 13: name11(k, "PIC2    BMP"); 14: name11(k, "MUSIC   WAV"); default: name11(k, "EMERG   BMP");
        endcase
        if (k[0] && (($random(seed) & 3) == 0)) dir[k * 32 + 11] = 8'h10;   // 属性不是 0x20（目录 / 别的）
        if ($random(seed) & 1) dir[k * 32] = 8'hE5;                        // 删除项
        put32(2, k * 32 + 20, $random(seed)); put32(2, k * 32 + 26, $random(seed)); put32(2, k * 32 + 22, $random(seed));
        put32(2, k * 32 + 28, $random(seed));
    end
    // 目录项：每种文件 70% 概率有，放在随机槽里；中间夹删除项（E5）和别的名字
    for (k = 0; k < 6; k = k + 1) begin
        slot = $random(seed) & 15;
        if (($random(seed) & 15) != 0) begin
            case (k)
                0: name11(slot, "PIC1    BMP"); 1: name11(slot, "PIC2    BMP"); 2: name11(slot, "PIC3    BMP");
                3: name11(slot, "PIC4    BMP"); 4: name11(slot, "MUSIC   WAV"); default: name11(slot, "EMERG   BMP");
            endcase
            v = $random(seed); put16(2, slot * 32 + 20, v[31:16]); put16(2, slot * 32 + 26, v[15:0]);
            put32(2, slot * 32 + 28, $random(seed)); put32(2, slot * 32 + 22, $random(seed));
        end
    end
end endtask

// ---------------- 比对 ----------------
integer fails = 0, tests = 0, errs = 0, oks = 0, t;
task cmp; input [31:0] a; input [31:0] b; input [8*12-1:0] nm; begin
    if (a !== b) begin
        if (fails < 20) $display("  MISMATCH test %0d %0s old=%h new=%h", t, nm, a, b);
        fails = fails + 1;
    end
end endtask

initial begin
    repeat (5) @(posedge clk); rst_n = 1;
    for (t = 0; t < 1000; t = t + 1) begin
        make_card(t);
        o_n = 0; n_n = 0;
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        wait (!o_busy && !n_busy);
        repeat (3) @(posedge clk);
        tests = tests + 1;
        if (o_err != 0) errs = errs + 1; else oks = oks + 1;
        cmp(o_err, n_err, "fs_error"); cmp(o_plba, n_plba, "part_lba"); cmp(o_spc, n_spc, "spc");
        cmp(o_fat, n_fat, "fat_start"); cmp(o_data, n_data, "data_start"); cmp(o_maxc, n_maxc, "max_clu");
        cmp(o_rv, n_rv, "res_valid"); cmp(o_c0, n_c0, "c0"); cmp(o_c1, n_c1, "c1"); cmp(o_c2, n_c2, "c2"); cmp(o_c3, n_c3, "c3");
        cmp(o_z0, n_z0, "z0"); cmp(o_z1, n_z1, "z1"); cmp(o_z2, n_z2, "z2"); cmp(o_z3, n_z3, "z3");
        cmp(o_mv, n_mv, "music_v"); cmp(o_mc, n_mc, "music_c"); cmp(o_mz, n_mz, "music_z");
        cmp(o_ev, n_ev, "emerg_v"); cmp(o_ec, n_ec, "emerg_c"); cmp(o_ez, n_ez, "emerg_z");
        cmp(o_sig, n_sig, "dir_sig"); cmp(o_n, n_n, "n_reads");
        for (k = 0; k < o_n && k < 8; k = k + 1) cmp(o_seq[k], n_seq[k], "read_lba");
        if (o_err == 0) cmp(o_seq[o_n - 1], lba_dir, "dir_lba");   // 好卡：最后读的就是独立算出来的根目录扇区
    end
    $display("%0d cards (%0d scanned OK, %0d rejected), %0d mismatches", tests, oks, errs, fails);
    $display("RESULT %s", (fails == 0 && oks > 200 && errs > 100) ? "PASS" : "FAIL");
    $finish;
end
endmodule

// 扇区服务：收到 req 后 busy，等 20 拍，每 2 拍一个字节，512 个后 done 一拍
module sec_server (input clk, input req, input [31:0] lba, output reg busy = 0, output reg valid = 0,
                   output reg [7:0] data = 0, output reg [8:0] idx = 0, output reg done = 0);
reg [31:0] a; integer c = 0, n = 0;
always @(posedge clk) begin
    valid <= 1'b0; done <= 1'b0;
    if (!busy) begin
        if (req) begin busy <= 1'b1; a <= lba; c <= 0; n <= 0; end
    end else begin
        c <= c + 1;
        if (c >= 20 && c[0]) begin
            if (n < 512) begin
                valid <= 1'b1; idx <= n; data <= tb_scan.card_byte(a, n); n <= n + 1;
            end else begin
                done <= 1'b1; busy <= 1'b0;
            end
        end
    end
end
endmodule
