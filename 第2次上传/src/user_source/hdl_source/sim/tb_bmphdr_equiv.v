`timescale 1ns/1ps
// 【省资源 第4轮】fat32_bmp_read 改之前（_old）/ 改之后：BMP 文件头校验等价性。用法：sim/run_bmphdr_equiv.sh
//   两份 fat32_bmp_read 各接一个扇区模型，读同一张卡（FAT32 小镜像，根目录 PIC1~4.BMP，每个文件一簇）
//   每轮重新生成 4 个 BMP：一半是好图（宽高 1~12），一半随机改坏一处（BM、DIB 头长度、宽高、平面数、位深、
//   压缩方式、像素偏移、文件被截断……），扫描后依次载入 4 张，比对：错误码、load_error 次数、输出像素个数和内容
module tb_bmphdr;
reg clk = 0, rst = 1; always #5 clk = ~clk;
localparam integer OW = 16, OH = 12;
defparam u_old.u_scaler.OUT_W = OW; defparam u_old.u_scaler.OUT_H = OH;
defparam u_new.u_scaler.OUT_W = OW; defparam u_new.u_scaler.OUT_H = OH;

reg [7:0] img [0:16*512-1];
task put32; input integer a; input [31:0] v; begin img[a] = v[7:0]; img[a+1] = v[15:8]; img[a+2] = v[23:16]; img[a+3] = v[31:24]; end endtask
task put16; input integer a; input [15:0] v; begin img[a] = v[7:0]; img[a+1] = v[15:8]; end endtask

reg ms_tick = 0; integer msc = 0;
always @(posedge clk) begin msc = msc + 1; ms_tick <= (msc % 1000) == 0; end

reg scan_start = 0, load_start = 0; reg [31:0] load_sector = 0;
wire o_ready, n_ready, o_sd, n_sd, o_wr, n_wr, o_le, n_le, o_scd, n_scd, o_wv, n_wv;
wire [31:0] o_sa, n_sa; wire [7:0] o_d, n_d; wire o_v, n_v, o_e, n_e;
wire [23:0] o_px, n_px; wire [3:0] o_err, n_err;
reg o_ack = 0, n_ack = 0;
always @(posedge clk) begin o_ack <= o_wr; n_ack <= n_wr; end

fat32_bmp_read_old #(.CLK_FREQ_HZ(100_000)) u_old (.clk(clk), .rst(rst), .ms_tick(ms_tick), .ready(o_ready),
    .scan_start(scan_start), .scan_start_sector(32'd0), .scan_max_sector(32'd0), .scan_target_count(3'd0),
    .scan_done(o_scd), .scan_found_valid(), .scan_found_sector(), .scan_found_total(),
    .load_start(load_start), .load_abort(1'b0), .load_sector(load_sector), .sd_init_done(1'b1), .state_code(),
    .bmp_width(16'd0), .bmp_height(16'd0), .write_req(o_wr), .write_req_ack(o_ack),
    .sd_sec_read(o_sd), .sd_sec_read_addr(o_sa), .sd_sec_read_data(o_d), .sd_sec_read_data_valid(o_v), .sd_sec_read_end(o_e),
    .bmp_data_wr_en(o_wv), .bmp_data(o_px), .load_error(o_le), .bmp_error(o_err),
    .music_start(1'b0), .music_found(), .emerg_found(), .music_byte_valid(), .music_byte(), .music_off(), .music_hold(1'b0),
    .probe_start(1'b0), .card_lost(), .fs_sig());
fat32_bmp_read #(.CLK_FREQ_HZ(100_000)) u_new (.clk(clk), .rst(rst), .ms_tick(ms_tick), .ready(n_ready),
    .scan_start(scan_start), .scan_start_sector(32'd0), .scan_max_sector(32'd0), .scan_target_count(3'd0),
    .scan_done(n_scd), .scan_found_valid(), .scan_found_sector(), .scan_found_total(),
    .load_start(load_start), .load_abort(1'b0), .load_sector(load_sector), .sd_init_done(1'b1), .state_code(),
    .bmp_width(16'd0), .bmp_height(16'd0), .write_req(n_wr), .write_req_ack(n_ack),
    .sd_sec_read(n_sd), .sd_sec_read_addr(n_sa), .sd_sec_read_data(n_d), .sd_sec_read_data_valid(n_v), .sd_sec_read_end(n_e),
    .bmp_data_wr_en(n_wv), .bmp_data(n_px), .load_error(n_le), .bmp_error(n_err),
    .music_start(1'b0), .music_found(), .emerg_found(), .music_byte_valid(), .music_byte(), .music_off(), .music_hold(1'b0),
    .probe_start(1'b0), .card_lost(), .fs_sig());
bsec s_old (.clk(clk), .rd(o_sd), .addr(o_sa), .data(o_d), .valid(o_v), .fin(o_e));
bsec s_new (.clk(clk), .rd(n_sd), .addr(n_sa), .data(n_d), .valid(n_v), .fin(n_e));

// 输出像素：个数 + 内容滚动校验；load_error 次数
integer o_np = 0, n_np = 0, o_nl = 0, n_nl = 0;
reg [31:0] o_h = 0, n_h = 0;
always @(posedge clk) begin
    if (o_wv) begin o_np = o_np + 1; o_h = {o_h[30:0], o_h[31]} ^ o_px; end
    if (n_wv) begin n_np = n_np + 1; n_h = {n_h[30:0], n_h[31]} ^ n_px; end
    if (o_le) o_nl = o_nl + 1;
    if (n_le) n_nl = n_nl + 1;
end

`ifdef DBG
reg o_sd_d = 0; always @(posedge clk) begin o_sd_d <= o_sd; if (o_sd && !o_sd_d) $display("  rd lba %0d t=%0t", o_sa, $time); if (o_e) $display("  end t=%0t idx %0d", $time, u_old.sec_idx); end
`endif
// ---------------- 卡 ----------------
integer seed = 11, i, k, r, t, w, h, rowb, fsz, mode;
integer mode_of [0:3];
integer hist [0:15];
reg [31:0] v;
task mkbmp; input integer slot; integer a, d; begin
    a = (3 + slot + 1) * 512;               // 簇 3 + slot → LBA 4 + slot
    for (i = 0; i < 512; i = i + 1) img[a + i] = $random(seed);
    w = 1 + ($unsigned($random(seed)) % 12); h = 1 + ($unsigned($random(seed)) % 12);
    rowb = (w * 3 + 3) & ~3;
    fsz = 54 + rowb * h;
    img[a] = "B"; img[a+1] = "M"; put32(a + 2, fsz); put32(a + 6, 0); put32(a + 10, 54); put32(a + 14, 40);
    put32(a + 18, w); put32(a + 22, h); put16(a + 26, 1); put16(a + 28, 24); put32(a + 30, 0); put32(a + 34, rowb * h);
    mode = ($random(seed) & 1) ? ($unsigned($random(seed)) % 24) : 99;
    mode_of[slot] = mode;
    d = 1 + ($unsigned($random(seed)) % 3);  // 改哪个高位字节
    case (mode)
        0:  img[a]   = "b";
        1:  img[a+1] = "N";
        2:  put32(a + 14, $unsigned($random(seed)) % 64);                    // DIB 头长度 0~63（40 是边界）
        3:  put32(a + 14, 32'd1 << (8 * d));                                 // 低字节 0、高字节非 0（>= 40）
        4:  put32(a + 14, 39);
        5:  put32(a + 18, 0);
        6:  put32(a + 18, w | (32'h0001_0000 << (8 * (d & 1))));           // 宽度高字节非 0
        7:  put32(a + 18, 4097);
        8:  put32(a + 22, 0);
        9:  put32(a + 22, h | (32'h0001_0000 << (8 * (d & 1))));             // 高度第 2、3 字节非 0
        10: put32(a + 22, 4097);
        11: put16(a + 26, 0);
        12: put16(a + 26, 16'h0101);
        13: put16(a + 26, 2);
        14: put16(a + 28, 32);
        15: put16(a + 28, 16'h0118);
        16: put16(a + 28, 16'h1800);
        17: img[a + 30 + ($unsigned($random(seed)) % 4)] = 1 + ($unsigned($random(seed)) % 255);   // 压缩方式非 0
        18: put32(a + 10, $unsigned($random(seed)) % 600);                   // 像素偏移乱写
        19: put32(a + 10, 53);
        20: fsz = 20 + ($unsigned($random(seed)) % (fsz - 20));             // 目录项大小比实际小（截断）
        21: put32(a + 10, 32'h0001_0036);                                    // 偏移高位非 0
        22: begin put32(a + 18, 4096); put32(a + 22, 1); end                 // 合法但像素区装不下
        99: ;
        default: put32(a + 22, h | 32'h8000_0000);                           // 负高度（自上而下）
    endcase
    // 目录项
    d = 3 * 512 + slot * 32;
    img[d] = "P"; img[d+1] = "I"; img[d+2] = "C"; img[d+3] = "1" + slot; for (i = 4; i < 8; i = i + 1) img[d+i] = " ";
    img[d+8] = "B"; img[d+9] = "M"; img[d+10] = "P"; img[d+11] = 8'h20;
    put16(d + 20, 0); put16(d + 26, 3 + slot); put32(d + 28, fsz); put32(d + 22, slot);
end endtask
task build; begin
    for (i = 0; i < 16 * 512; i = i + 1) img[i] = 8'h00;
    img[0] = 8'hEB; img[1] = 8'h58; img[2] = 8'h90;
    put16(11, 512); img[13] = 1; put16(14, 2); img[16] = 1; put16(17, 0); put16(22, 0);
    put32(32, 16); put32(36, 1); put32(44, 2);
    img[510] = 8'h55; img[511] = 8'hAA;
    put32(2 * 512 + 0, 32'h0FFFFFF8); put32(2 * 512 + 4, 32'h0FFFFFFF);
    for (i = 2; i <= 7; i = i + 1) put32(2 * 512 + i * 4, 32'h0FFFFFFF);
    for (k = 0; k < 4; k = k + 1) mkbmp(k);
end endtask

integer fails = 0, goods = 0, bads = 0;
task cmp; input [8*20-1:0] nm; input [31:0] a; input [31:0] b; begin
    if (a !== b) begin
        if (fails < 20) $display("  MISMATCH round %0d pic %0d %0s old=%0d new=%0d", r, k, nm, a, b);
        fails = fails + 1;
    end
end endtask

initial begin
    for (i = 0; i < 16; i = i + 1) hist[i] = 0;
    repeat (5) @(posedge clk); rst = 0; repeat (5) @(posedge clk);
    for (r = 0; r < `ifdef ROUNDS `ROUNDS `else 300 `endif; r = r + 1) begin
        build;
        @(negedge clk) scan_start = 1; @(negedge clk) scan_start = 0;
        repeat (5) @(posedge clk); wait (o_scd && n_scd && o_ready && n_ready); repeat (5) @(posedge clk);
`ifdef DBG
        $display("scan r%0d err %h rv %b bmp_err %0d t=%0t", r, u_old.u_scanner.fs_error, u_old.u_scanner.resource_valid, o_err, $time);
`endif
        for (k = 0; k < 4; k = k + 1) begin
            o_np = 0; n_np = 0; o_h = 0; n_h = 0;
            wait (o_ready && n_ready);
            @(negedge clk) load_start = 1; load_sector = k; @(negedge clk) load_start = 0;
            repeat (5) @(posedge clk);
            t = 0; while (!(o_ready && n_ready) && t < 2000000) begin @(posedge clk); t = t + 1; end
            repeat (20) @(posedge clk);
            if (t >= 2000000) begin $display("  TIMEOUT round %0d pic %0d", r, k); fails = fails + 1; end
            cmp("bmp_error", o_err, n_err); cmp("load_errors", o_nl, n_nl); cmp("pixels", o_np, n_np); cmp("pix_hash", o_h, n_h);
            if (o_err == 0) goods = goods + 1; else bads = bads + 1;
`ifdef DBG
            $display("r%0d k%0d mode %0d err %0d | %h %h off %0d dib %0d w %0d h %0d pl %0d bc %0d cmp %0d size %0d np %0d", r, k, mode_of[k], o_err, u_old.header_0, u_old.header_1, u_old.pixel_offset, u_old.dib_size, u_old.width, u_old.height, u_old.planes, u_old.bit_count, u_old.compression, u_old.cur_size, o_np);
`endif
            if (mode_of[k] == 99) hist[o_err] = hist[o_err] + 1;
        end
    end
    for (i = 0; i < 16; i = i + 1) if (hist[i] != 0) $display("  good headers -> err %0d : %0d", i, hist[i]);
    $display("%0d loads (%0d ok, %0d rejected), %0d mismatches", goods + bads, goods, bads, fails);
    $display("RESULT %s", (fails == 0 && goods > 300 && bads > 300) ? "PASS" : "FAIL");
    $finish;
end
endmodule

// 扇区模型（官方 sd_card_top 读口的行为）：读请求后等 30 拍，每 2 拍一个字节，512 个后 fin 一拍（组合）
module bsec (input clk, input rd, input [31:0] addr, output reg [7:0] data = 0, output reg valid = 0, output fin);
reg [1:0] st = 0; integer cnt = 0, idx = 0; reg [31:0] lba = 0;
assign fin = (st == 2'd3);
always @(posedge clk) begin
    valid <= 1'b0;
    case (st)
        2'd0: if (rd) begin lba <= addr; cnt <= 0; idx <= 0; st <= 2'd1; end
        2'd1: if (cnt >= 30) begin cnt <= 0; st <= 2'd2; end else cnt <= cnt + 1;
        2'd2: begin
            cnt <= cnt + 1;
            if (cnt[0]) begin
                if (idx == 512) st <= 2'd3;   // 和官方控制器一样：最后一个字节之后下一拍才“读完”（不和数据有效同拍）
                else begin
                    data  <= (lba < 16) ? tb_bmphdr.img[lba * 512 + idx] : 8'h00;
                    valid <= 1'b1;
                    idx <= idx + 1;
                end
            end
        end
        default: st <= 2'd0;
    endcase
end
endmodule
