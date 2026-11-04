`timescale 1ns/1ps
// 【应急改版】emergency_overlay + osd_layer 整体画面：各等级 / 按键进入（没有文字）/ 串口进入（有文字）/
//   有没有 EMERG.BMP / 三级在节目和启事页上，各导出一帧到 emg_prev/*.bmp，并做几项自动检查
//   读口按 serial_cmd 的规则：有应急文字时给应急文字 RAM（列号 = emergency_overlay 的 a_col），三级在启事页上给启事页；
//   字幕条的通知输入按 serial_cmd 的 v_on / v_len 规则；背景用桌面上的 EMERG.BMP、PIC3 和启事页仿真图（emg_prev/bg_*.hex）
//   用法：iverilog -g2005 -o ep.out -s tb_emerg_prev tb_emerg_prev.v ../emergency_overlay.v ../osd_layer.v ../subtitle_strip.v
//          ../subtitle_rom.v ../promax_audio_waveform.v ../param_bar_overlay.v && vvp -n ep.out
module tb_emerg_prev;
reg clk = 0, rst_n = 0; always #20 clk = ~clk;
reg [9:0] h = 0, v = 0;
always @(posedge clk) begin
    h <= (h == 799) ? 0 : h + 1;
    if (h == 799) v <= (v == 524) ? 0 : v + 1;
end
wire de = (h < 640) && (v < 480);
wire vs = !((v >= 490) && (v < 492));

reg [23:0] bg_e [0:307199];
reg [23:0] bg_p [0:307199];
reg [23:0] bg_n [0:307199];
reg [1:0]  bgsel = 0;                                  // 0 EMERG.BMP 1 PIC3 2 启事页
wire [23:0] bgpix = (bgsel == 0) ? bg_e[v * 640 + h] : (bgsel == 1) ? bg_p[v * 640 + h] : bg_n[v * 640 + h];
wire [23:0] rgb_in = de ? bgpix : 24'd0;

reg emerg_on = 0, builtin_on = 0, pv_sel = 0; reg [1:0] level = 0; reg [9:0] a_len = 0;
wire [9:0] a_col, s_col; reg [15:0] rd_bits = 0; wire [23:0] e_rgb, o_rgb; wire blink;
reg [15:0] amem [0:1023];
wire alm_rd = (level != 0) && (a_len != 0) && !(pv_sel && level == 3);
always @(posedge clk) rd_bits <= alm_rd ? amem[a_col] : 16'h0000;

emergency_overlay u_e (.clk(clk), .rst_n(rst_n), .vs(vs), .de(de), .rgb_in(rgb_in), .emerg_on(emerg_on), .builtin_on(builtin_on),
    .level(level), .a_len(a_len), .a_col(a_col), .a_bits(rd_bits), .s_col(s_col), .page_on(pv_sel), .rgb_out(e_rgb), .blink(blink));

wire atk   = (level != 0) && (a_len != 0);
wire n_on  = atk && !pv_sel;
reg  n_new = 0;
osd_layer u_o (
    .clk(clk), .rst_n(rst_n), .vs(vs), .de(de), .rgb_in(e_rgb),
    .img_num(4'd3), .auto_on(1'b1), .err_code(4'd0),
    .subtitle_on(1'b1), .subtitle_text(96'd0), .subtitle_len(6'd0),
    .wave_on(1'b1), .pcm_valid(1'b0), .pcm_left(16'sd0),
    .osd_on(!pv_sel), .menu_on(1'b0), .menu_sel(2'd0), .bri_pct(8'd100), .con_pct(8'd100), .vol_pct(8'd80), .period_idx(3'd1),
    .alert(emerg_on), .thumb_on(1'b0),
    .notice_on(n_on), .notice_len({1'b0, a_len}), .notice_new(n_new), .notice_col(s_col), .notice_bits(rd_bits), .notice_cs(1'b0),
    .res_info({!pv_sel, !pv_sel, 16'h1078, 16'h1262}), .alm_level(level), .rgb_out(o_rgb));

// ---------------- 应急文字 RAM：按 FONT.BIN 排版（每行 288 列，和 serial_cmd 一样） ----------------
reg [7:0] font [0:691455];
reg [7:0] strs [0:5*512-1];
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
task load_text; input integer sk; integer i, n, c, w, g, k, lc, stop, cn; reg [7:0] b0, b1, b2; begin
    n = slen(sk); cn = 0; i = 0; lc = 0; stop = 0;
    while (i < n && !stop) begin
        b0 = strs[sk * 512 + i]; b1 = strs[sk * 512 + i + 1]; b2 = strs[sk * 512 + i + 2];
        if (b0 < 8'h80) begin c = b0; i = i + 1; end
        else if (b0[7:5] == 3'b110) begin c = {b0[4:0], b1[5:0]}; i = i + 2; end
        else begin c = {b0[3:0], b1[5:0], b2[5:0]}; i = i + 3; end
        g = gidx(c); w = (c <= 32'h7E) ? 8 : 16;
        if (cn + w > 864) stop = 1;
        else begin
            if (lc + w > 288) begin while (lc < 288) begin amem[cn] = 0; cn = cn + 1; lc = lc + 1; end lc = 0; end
            if (cn + w > 864) stop = 1;
            else for (k = 0; k < w; k = k + 1) begin
                amem[cn] = {font[g * 32 + 2 * k], font[g * 32 + 2 * k + 1]}; cn = cn + 1; lc = (lc == 287) ? 0 : lc + 1;
            end
        end
    end
    a_len = cn;
end endtask

// ---------------- 抓帧 ----------------
reg [23:0] fb [0:640*480-1];
reg [23:0] fi [0:640*480-1];
always @(posedge clk) if (de) begin fb[v * 640 + h] <= o_rgb; fi[v * 640 + h] <= rgb_in; end
task frames; input integer n; integer k; begin for (k = 0; k < n; k = k + 1) begin wait (v == 481); wait (v == 482); end end endtask
task dump; input [8*48-1:0] name; integer f, x, y; reg [23:0] p; begin
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
    $display("dumped %0s", name);
end endtask
// 设置一个场景：sk < 0 = 没有文字（按键进入）；字幕条滚到 scroll 像素处
task scene; input e; input b; input [1:0] l; input integer sk; input [1:0] bgs; input p; begin
    wait (v == 500);
    emerg_on = e; builtin_on = b; level = l; bgsel = bgs; pv_sel = p;
    if (sk < 0) a_len = 0; else load_text(sk);
    @(negedge clk) n_new = 1; @(negedge clk) n_new = 0;
    frames(2);
    wait (v == 500); u_o.u_subtitle.pos = 12'd560;      // 直接把滚动位置拨到文字已经进来一大段的地方
    frames(1);
end endtask

integer fails = 0;
task check; input c; input [8*72-1:0] msg; begin
    if (c) $display("  ok   %0s", msg); else begin $display("  FAIL %0s", msg); fails = fails + 1; end
end endtask
// 区域内输出是否等于输入
function same; input integer x0; input integer y0; input integer x1; input integer y1; integer x, y; begin
    same = 1;
    for (y = y0; y < y1; y = y + 1) for (x = x0; x < x1; x = x + 1) if (fb[y * 640 + x] !== fi[y * 640 + x]) same = 0;
end endfunction

initial begin
    $readmemh("font_sim.hex", font);
    $readmemh("emg_prev/strs.hex", strs);
    $readmemh("emg_prev/bg_emerg.hex", bg_e);
    $readmemh("emg_prev/bg_pic3.hex", bg_p);
    $readmemh("emg_prev/bg_page.hex", bg_n);
    repeat (10) @(posedge clk); rst_n = 1;
    frames(1);
    // 有 EMERG.BMP：一级按键 / 一级串口 / 二级串口（闪烁边框在“亮”的时候抓）
    scene(1, 0, 1, -1, 0, 0); wait (blink); dump("emg_prev/1_l1_key_image.bmp");
    check(same(10, 10, 630, 440), "L1 key on EMERG.BMP: picture untouched except border + bottom strip");
    scene(1, 0, 1, 0, 0, 0);  wait (blink); dump("emg_prev/2_l1_serial_image.bmp");
    check(same(10, 10, 630, 440), "L1 serial on EMERG.BMP: same as key (no panel over the map)");
    check(fb[458 * 640 + 300][23:16] > 8'hA0 || fb[458 * 640 + 300] == 24'hFFFFFF, "L1: bottom strip red with serial text");
    scene(1, 1, 2, 1, 0, 0);  wait (blink); dump("emg_prev/3_l2_serial.bmp");   // 二级始终用内置页（emerg_ok 只在一级为 1）
    check(fb[100 * 640 + 300] !== fi[100 * 640 + 300], "L2: built-in shelter page, not the evacuation map");
    // 没有 EMERG.BMP：内置警示页
    scene(1, 1, 1, -1, 0, 0); wait (blink); dump("emg_prev/4_l1_key_builtin.bmp");
    scene(1, 1, 1, 0, 0, 0);  wait (blink); dump("emg_prev/5_l1_serial_builtin.bmp");
    scene(1, 1, 2, -1, 0, 0); wait (blink); dump("emg_prev/6_l2_key_builtin.bmp");
    scene(1, 1, 2, 1, 0, 0);  wait (blink); dump("emg_prev/7_l2_serial_builtin.bmp");
    // 三级：节目上 / 启事页上 / 长文字 / 没有文字
    scene(0, 0, 3, 2, 1, 0);  dump("emg_prev/8_l3_program.bmp");
    check(same(20, 70, 620, 370), "L3 on program: middle of the picture untouched");
    check(same(6, 6, 420, 60), "L3: resolution label hidden, tag not at top-left/center");
    check(fb[36 * 640 + 433] == 24'hFFB020 && fb[36 * 640 + 434] == 24'h1C1C1C, "L3: tag at top-right on program");
    scene(0, 0, 3, 2, 2, 1);  dump("emg_prev/9_l3_notice_page.bmp");
    check(same(20, 100, 620, 470), "L3 on notice page: page body + footer untouched (no strip, no waveform)");
    scene(0, 0, 3, 4, 1, 0);  dump("emg_prev/a_l3_long.bmp");
    scene(0, 0, 3, -1, 1, 0); dump("emg_prev/b_l3_notext.bmp");
    scene(0, 0, 0, -1, 1, 0); dump("emg_prev/c_none.bmp");
    $display("RESULT fails=%0d %s", fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
endmodule
