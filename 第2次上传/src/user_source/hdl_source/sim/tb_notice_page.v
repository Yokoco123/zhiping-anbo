`timescale 1ns/1ps
// 【启事】notice_page 画面仿真：三种类别、短 / 长文字各抓一帧存成 BMP（sim/page_out/），再检查 sel = 0 时原样输出
//   启事页缓冲用 tb 自己按 FONT.BIN 排好的点阵（每行 288 列、放不下补空列、最多 4 行，和 serial_cmd 一样；
//   serial_cmd 画出来的和这个一致已经在 tb_serial_cmd B6 里逐列比过）
module tb_npage;
reg clk = 0, rst_n = 0; always #20 clk = ~clk;
reg [9:0] h = 0, v = 0;
always @(posedge clk) begin
    h <= (h == 799) ? 0 : h + 1;
    if (h == 799) v <= (v == 524) ? 0 : v + 1;
end
wire de = (h < 640) && (v < 480);
wire vs = !((v >= 490) && (v < 492));
// 【串口照片】带照片的帧：照片框（16~376 × 112~432）里用 photo_sdram.hex（tb_serial_cmd -DPHREAL 画出来的照片，屏上从上到下）
reg [23:0] phot [0:115199];
reg        phmode = 0, smmode = 0;           // 【自动字号】smmode = 小字
wire       in_ph = (h >= 16) && (h < 376) && (v >= 112) && (v < 432);
wire [23:0] img = (phmode && in_ph) ? phot[(v - 112) * 360 + (h - 16)] : {h[7:0], v[7:0], 8'h80};   // 代替节目画面

reg sel = 0; reg [20:0] meta = 0;
wire [10:0] col; reg [15:0] bits = 0; wire [23:0] rgb_out;
reg [15:0] pmem [0:2047];
always @(posedge clk) bits <= pmem[col];
notice_page dut (.clk(clk), .rst_n(rst_n), .vs(vs), .de(de), .rgb_in(img), .sel(sel), .meta(meta),
                 .col(col), .bits(bits), .rgb_out(rgb_out));

reg [7:0] font [0:691455];
reg [7:0] strs [0:160*512-1];
function integer slen; input integer k; integer i; begin slen = 0; for (i = 0; i < 512; i = i + 1) if (strs[k * 512 + i] != 0 && slen == i) slen = i + 1; end endfunction
function integer gidx; input integer c; begin
    if      (c >= 32'h20   && c <= 32'h7E)   gidx = c - 32'h20;
    else if (c >= 32'hA0   && c <= 32'hFF)   gidx = c - 32'hA0 + 95;
    else if (c >= 32'h2000 && c <= 32'h206F) gidx = c - 32'h2000 + 191;
    else if (c >= 32'h3000 && c <= 32'h303F) gidx = c - 32'h3000 + 303;
    else if (c >= 32'h4E00 && c <= 32'h9FFF) gidx = c - 32'h4E00 + 367;
    else if (c >= 32'hFF00 && c <= 32'hFFEF) gidx = c - 32'hFF00 + 21359;
    else gidx = 31;
end endfunction
integer pn, lw = 288, maxc = 1152;
task load_text; input integer sk; integer i, n, c, w, g, k, lc, stop; reg [7:0] b0, b1, b2; begin
    for (i = 0; i < 2048; i = i + 1) pmem[i] = 16'hFFFF;          // 用不到的列故意填满：画出来就说明没截对
    n = slen(sk); pn = 0; i = 0; lc = 0; stop = 0;
    while (i < n && !stop) begin
        b0 = strs[sk * 512 + i]; b1 = strs[sk * 512 + i + 1]; b2 = strs[sk * 512 + i + 2];
        if (b0 < 8'h80) begin c = b0; i = i + 1; end
        else if (b0[7:5] == 3'b110) begin c = {b0[4:0], b1[5:0]}; i = i + 2; end
        else begin c = {b0[3:0], b1[5:0], b2[5:0]}; i = i + 3; end
        g = gidx(c); w = (c <= 32'h7E) ? 8 : 16;
        if (pn + w > maxc) stop = 1;
        else begin
            if (lc + w > lw) begin while (lc < lw) begin pmem[pn] = 0; pn = pn + 1; lc = lc + 1; end lc = 0; end
            if (pn + w > maxc) stop = 1;
            else for (k = 0; k < w; k = k + 1) begin
                pmem[pn] = {font[g * 32 + 2 * k], font[g * 32 + 2 * k + 1]}; pn = pn + 1; lc = (lc == lw - 1) ? 0 : lc + 1;
            end
        end
    end
end endtask

reg [23:0] fb [0:640*480-1];
integer fi = 0;
always @(posedge clk) begin
    if (v == 480 && h == 0) fi = 0;
    if (de) begin fb[fi] = rgb_out; fi = fi + 1; end
end
task dump; input [8*40-1:0] name; integer f, x, y; reg [23:0] p; begin
    wait (v == 0 && h == 1); wait (v == 481);
    f = $fopen(name, "wb");
    $fwrite(f, "BM%c%c%c%c%c%c%c%c%c%c%c%c", 8'h36, 8'h10, 8'h0E, 8'h00, 0,0,0,0, 54,0,0,0);
    $fwrite(f, "%c%c%c%c%c%c%c%c%c%c%c%c", 40,0,0,0, 8'h80,8'h02,0,0, 8'hE0,8'h01,0,0);
    $fwrite(f, "%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c", 1,0,24,0, 0,0,0,0, 0,8'h10,8'h0E,0,
            0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0);
    for (y = 479; y >= 0; y = y - 1)
        for (x = 0; x < 640; x = x + 1) begin
            p = fb[y * 640 + x];
            $fwrite(f, "%c%c%c", p[7:0], p[15:8], p[23:16]);
        end
    $fclose(f);
    $display("dumped %0s  small=%0d type=%0d cols=%0d  %0d/%0d", name, meta[20], meta[18:17], meta[16:6], meta[5:3], meta[2:0]);
end endtask
task show; input integer sk; input [1:0] ty; input [2:0] idx; input [2:0] tot; begin
    wait (v == 500); load_text(sk); sel = 1; meta = {smmode, phmode, ty, pn[10:0], idx, tot}; wait (v == 501);
end endtask

integer fails = 0, bad, x, y;
// 【自动字号】小字逐像素核对：nl 行，行距 28，第一行在 278 - 14·nl；第 k 行第 r 行（0~15）x 处 = 第 k·lw + (x - x0) 列的第 r 位
//   文字区 x0 ~ x0+lw 以外、文字行以外的卡片里不能有字
task check_small; input integer x0; input [8*60-1:0] msg; integer nl, y0, k, r, c, want, got, b2; begin
    nl = (pn + lw - 1) / lw; y0 = 278 - 14 * nl; b2 = 0;
    for (y = 104; y < 440; y = y + 1) for (x = 0; x < 640; x = x + 1) begin
        k = (y - y0) / 28; r = (y - y0) % 28; c = k * lw + (x - x0);
        want = (y >= y0) && (k < nl) && (r < 16) && (x >= x0) && (x < x0 + lw) && (c < pn) && pmem[c][r];
        got  = (fb[y * 640 + x] == 24'h1A1A1A);
        if (!(phmode && x >= 16 && x < 376 && y >= 112 && y < 432) && (want != got)) begin
            if (b2 < 3) $display("       x %0d y %0d got %0d want %0d", x, y, got, want); b2 = b2 + 1; end
    end
    if (b2 == 0) $display("  ok   %0s (%0d lines)", msg, nl); else begin $display("  FAIL %0s: %0d pixels", msg, b2); fails = fails + 1; end
end endtask
initial begin
    $readmemh("font_sim.hex", font);
    $readmemh("cmd_strings.hex", strs);
    $readmemh("page_out/photo_sdram.hex", phot);
    repeat (5) @(posedge clk); rst_n = 1;
    show(75, 2'd1, 3'd1, 3'd3);  dump("page_out/p1_person.bmp");
    show(78, 2'd2, 3'd2, 3'd3);  dump("page_out/p2_thing.bmp");
    show(81, 2'd3, 3'd3, 3'd3);  dump("page_out/p3_found.bmp");
    show(102, 2'd1, 3'd1, 3'd1); dump("page_out/p4_long.bmp");
    // 4 行满：最后一列之后不能有字；第 4 行下面（文字区之外）不能有字
    bad = 0;
    for (y = 360; y < 432; y = y + 1) for (x = 16; x < 624; x = x + 1) if (fb[y * 640 + x] == 24'h1A1A1A) bad = bad + 1;
    if (bad == 0) $display("  ok   long text: nothing drawn below line 4"); else begin $display("  FAIL long text: %0d text pixels below line 4", bad); fails = fails + 1; end
    // 短文字：一行里最后一个字后面（列数以外）是白的
    show(84, 2'd3, 3'd1, 3'd1);  dump("page_out/p5_short.bmp");
    bad = 0;
    for (y = 0; y < 480; y = y + 1) for (x = 32 + 2 * 64; x < 608; x = x + 1) if (y >= 112 && y < 432 && fb[y * 640 + x] == 24'h1A1A1A) bad = bad + 1;
    if (bad == 0) $display("  ok   short text: columns past the end are blank"); else begin $display("  FAIL short text: %0d pixels past the end", bad); fails = fails + 1; end
    // 【串口照片】带照片：照片框里是照片，文字只在 388~612，每行 7 个字最多 6 行
    phmode = 1; lw = 112; maxc = 672;
    show(75, 2'd1, 3'd1, 3'd2);  dump("page_out/p6_photo.bmp");
    bad = 0;
    for (y = 112; y < 432; y = y + 1) for (x = 16; x < 376; x = x + 1) if (fb[y * 640 + x] !== phot[(y - 112) * 360 + x - 16]) bad = bad + 1;
    if (bad == 0) $display("  ok   photo: the photo frame shows the SDRAM picture"); else begin $display("  FAIL photo frame: %0d pixels differ", bad); fails = fails + 1; end
    show(102, 2'd2, 3'd2, 3'd2); dump("page_out/p7_photo_long.bmp");
    bad = 0;
    for (y = 104; y < 440; y = y + 1) for (x = 0; x < 640; x = x + 1)
        if ((x < 388 || x >= 612 || y >= 408) && !(x >= 16 && x < 376 && y >= 112 && y < 432) && fb[y * 640 + x] == 24'h1A1A1A) bad = bad + 1;
    if (bad == 0) $display("  ok   photo + long text: text only right of the photo, 6 lines"); else begin $display("  FAIL photo + long text: %0d text pixels outside", bad); fails = fails + 1; end
    phmode = 0; lw = 288; maxc = 1152;
    // 【自动字号】小字：不带照片每行 576 列（36 字），带照片 224 列（14 字），最多 2040 列
    smmode = 1; lw = 576; maxc = 2040;
    show(147, 2'd1, 3'd1, 3'd2); dump("page_out/p8_small.bmp");
    check_small(32, "small type: pixel-exact, 36 per line");
    show(139, 2'd2, 3'd2, 3'd2); dump("page_out/p9_small_full.bmp");
    check_small(32, "small type, full buffer (127 characters, 4 lines)");
    phmode = 1; lw = 224;
    show(147, 2'd1, 3'd1, 3'd1); dump("page_out/pa_photo_small.bmp");
    check_small(388, "photo + small type: 14 per line");
    show(139, 2'd3, 3'd1, 3'd1); dump("page_out/pb_photo_small_full.bmp");
    check_small(388, "photo + small type, 10 lines");
    phmode = 0; smmode = 0; lw = 288; maxc = 1152;
    // sel = 0：原样输出
    wait (v == 500); sel = 0; wait (v == 501);
    dump("page_out/p0_off.bmp");
    bad = 0;
    for (y = 0; y < 480; y = y + 1) for (x = 0; x < 640; x = x + 1) if (fb[y * 640 + x] !== {x[7:0], y[7:0], 8'h80}) bad = bad + 1;
    if (bad == 0) $display("  ok   sel = 0: picture passes through unchanged"); else begin $display("  FAIL sel = 0: %0d pixels changed", bad); fails = fails + 1; end
    $display("RESULT fails=%0d %s", fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
endmodule
