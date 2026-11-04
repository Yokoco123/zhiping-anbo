`timescale 1ns/1ps
// 【串口指令】serial_cmd + param_store（Flash 仲裁）+ W25Q64 模型：
//   tb 像串口助手一样发 UTF-8 文字（不加换行，靠停顿结束），收回复按 UTF-8 文字比对；
//   字库用 gen_font.ps1 -Hex 生成的真实 FONT.BIN（font_sim.hex），通过串口完整装一遍，再发通知，
//   读通知 RAM 和 tb 自己按 FONT.BIN 查出来的点阵逐列比。
// 时间缩短：CLK 10MHz、波特率 1Mbps（每位 10 拍）、ms_tick 每 10 拍（1ms = 1us），超时参数同比缩短。
//   -DFULL：用 115200 真实波特率 + 100MHz（很慢，只在需要时跑）
module tb_cmd;
`ifdef FULL
localparam integer FHZ = 100_000_000, BAUD = 115_200, MSDIV = 100_000;
`elsif F75
localparam integer FHZ = 75_000_000,  BAUD = 921_600, MSDIV = 75_000;    // 【时序】sd_card_clk 75MHz（BIT_CYC 81，实际 925926 bps）
`elsif F83
localparam integer FHZ = 83_333_333,  BAUD = 921_600, MSDIV = 83_333;    // 【时序】板上真实时钟和波特率
`else
localparam integer FHZ = 10_000_000,  BAUD = 625_000, MSDIV = 100;   // 每位 16 拍；1ms = 10us（20ms 停顿 = 12 个字节时间）
`endif
localparam integer BITNS = 1_000_000_000 / BAUD;
localparam integer CLKNS = 1_000_000_000 / FHZ;
localparam real CLKHALF = 500_000_000.0 / FHZ;              // 半周期（实数：75MHz = 6.667ns，整数会变成 6ns）
reg clk = 0, rst = 1; always #(CLKHALF) clk = ~clk;
reg vclk = 0; always #20 vclk = ~vclk;
reg ms_tick = 0; integer msd = 0;
always @(posedge clk) begin msd = (msd == MSDIV - 1) ? 0 : msd + 1; ms_tick <= (msd == 0); end

reg rx = 1; wire tx;
reg emerg = 0;
// 【三级应急】SW1、串口设的等级；接管 = SW1 或一级 / 二级（和 sd_card_bmp4 一样）
reg sw1 = 0; wire [1:0] alm_sd, v_alm; wire [9:0] v_alen; reg [9:0] a_col = 0;
wire emerg_eff = emerg || sw1 || (alm_sd == 2'd1) || (alm_sd == 2'd2);
wire req, grant, off, e_cs, e_sclk, e_mosi, cs_n, sclk, mosi, miso;
wire mplay, mstop, inext, iprev; wire [1:0] fst;
reg  [9:0] rd_col = 0; wire [15:0] rd_bits; wire v_on, v_new, v_rej, v_sub; wire [10:0] v_len;
// 【启事】
wire [3:0] q_mask; wire q_new; wire [1:0] q_new_slot; reg pg_req = 0; reg [1:0] pg_slot = 0; reg pg_buf = 0; wire pg_done;
reg pv_sel = 0, pv_buf = 0; reg [10:0] pv_col = 0; wire [20:0] pv_meta;
// 【串口照片】SDRAM 写口那一边（sd_card_bmp4 + frame_fifo_write）的行为模型
wire ph_need, ph_wreq, ph_we, ph_pbuf; wire [23:0] ph_px; reg ph_grant = 0, ph_wack = 0, ph_wfin = 0;
// 【按键改造】
reg k_alarm = 0, x_alarm = 0, k_mute = 0; wire osd_set, osd_clr, auto_set, auto_clr, muted, v_mute;
wire wv_set, wv_clr, rs_set, rs_clr;          // 【波形开关】【分辨率显示】
// 【自定义字幕】正在显示第几张图（video_transition 的 shown_num）
reg [3:0] v_shown = 0; wire v_cs;

// 仿真里 Flash 擦除 / 编程时间按比例缩短（模型默认 300us / 20us / 500us 已经很短）
`ifdef SMALL
`ifdef PHREAL
localparam integer PPAGES = 3600, PROWS = 320;         // 【串口照片】真实 PHOTO.BIN（gen_photo.ps1 -Hex），画满 320 行
`else
localparam integer PPAGES = 4, PROWS = 8;              // 【串口照片】小照片文件（4 页），画照片只画 8 行
`endif
localparam integer FPAGES = 8, FGLYPHS = 64;          // 小字库：前 64 个字（ASCII 0x20~0x5F），装一遍很快
`else
localparam integer FPAGES = 2700, FGLYPHS = 21599;
localparam integer PPAGES = 3600, PROWS = 320;
`endif
serial_cmd #(.CLK_FREQ_HZ(FHZ), .BAUD(BAUD), .FONT_PAGES(FPAGES), .FONT_GLYPHS(FGLYPHS),
             .IDLE_MS(20), .FIRST_MS(300), .BYTE_MS(100), .BUSY_MS(3000), .PH_PAGES(PPAGES), .PH_ROWS(PROWS)) dut (
    .clk(clk), .rst(rst), .ms_tick(ms_tick), .uart_rx(rx), .uart_tx(tx), .emerg_mode(emerg_eff), .sw1(sw1), .k_alarm(k_alarm), .x_alarm(x_alarm), .k_mute(k_mute), .alarm_lvl(alm_sd),
    .fl_req(req), .fl_grant(grant), .fl_off(off), .fl_cs_n(e_cs), .fl_sclk(e_sclk), .fl_mosi(e_mosi), .fl_miso(miso),
    .music_play(mplay), .music_stop(mstop), .img_next(inext), .img_prev(iprev), .osd_set(osd_set), .osd_clr(osd_clr), .auto_set(auto_set), .auto_clr(auto_clr),
    .wave_set(wv_set), .wave_clr(wv_clr), .res_set(rs_set), .res_clr(rs_clr),
    .muted(muted), .font_status(fst),
    .vclk(vclk), .vrst_n(!rst), .rd_col(rd_col), .rd_bits(rd_bits), .v_on(v_on), .v_len(v_len), .v_new(v_new),
    .v_reject(v_rej), .v_sub_off(v_sub), .v_shown(v_shown), .v_cs(v_cs), .a_col(a_col), .v_alm(v_alm), .v_alen(v_alen), .v_mute(v_mute),
    .q_mask(q_mask), .q_new(q_new), .q_new_slot(q_new_slot), .pg_req(pg_req), .pg_slot(pg_slot), .pg_buf(pg_buf), .pg_done(pg_done),
    .pv_sel(pv_sel), .pv_buf(pv_buf), .pv_col(pv_col), .pv_meta(pv_meta),
    .ph_need(ph_need), .ph_grant(ph_grant), .ph_wreq(ph_wreq), .ph_wack(ph_wack), .ph_wfin(ph_wfin), .ph_we(ph_we), .ph_px(ph_px), .ph_pbuf(ph_pbuf));
// 写口模型：ph_need 后过一会儿给许可（ph_hold = 1 时不给，模拟正在载图）；写请求后几拍应答，请求撤掉就收回应答；
//   收够 PROWS × 640 个像素后过一会儿发 ph_wfin；收到的像素存进 phbuf
event ph_done_ev;
reg ph_hold = 0; integer ph_n = 0, ph_req_seen = 0; reg [23:0] phbuf [0:204799];
always @(posedge clk) begin
    ph_grant <= ph_need && !ph_hold && (ph_grant || !ph_hold);
    if (!ph_need) ph_grant <= 1'b0;
    if (ph_wreq) begin ph_req_seen = ph_req_seen + 1; if (ph_req_seen > 4) ph_wack <= 1'b1; end
    else begin ph_req_seen = 0; ph_wack <= 1'b0; if (ph_wack) ph_n = 0; end
    if (ph_we) begin if (ph_n < 204800) phbuf[ph_n] = ph_px; ph_n = ph_n + 1; if (ph_n == PROWS * 640) -> ph_done_ev; end
end
always @(ph_done_ev) begin repeat (50) @(posedge clk); ph_wfin <= 1'b1; @(posedge clk); ph_wfin <= 1'b0; end
reg menu = 0;
param_store #(.CLK_FREQ_HZ(100_000_000), .ENABLE_WRITE(1), .RETRY_MS(1)) ps (
    .clk(clk), .rst(rst), .ms_tick(ms_tick), .menu_on(menu), .bri_pct(8'd100), .con_pct(8'd100), .vol_pct(8'd80), .period_idx(3'd1), .flags(3'b000), .ld_flags(),
    .load_valid(), .ld_bri(), .ld_con(), .ld_vol(), .ld_period(), .status(),
    .flash_cs_n(cs_n), .flash_sclk(sclk), .flash_mosi(mosi), .flash_wp_n(), .flash_hold_n(), .flash_miso(miso),
    .ext_req(req), .ext_grant(grant), .ext_cs_n(e_cs), .ext_sclk(e_sclk), .ext_mosi(e_mosi), .chip_off(off));
w25q64_model flash (.cs_n(cs_n), .sclk(sclk), .mosi(mosi), .miso(miso));

integer n_wset = 0, n_wclr = 0, n_rset = 0, n_rclr = 0;
always @(posedge clk) begin if (wv_set) n_wset = n_wset + 1; if (wv_clr) n_wclr = n_wclr + 1;
                            if (rs_set) n_rset = n_rset + 1; if (rs_clr) n_rclr = n_rclr + 1; end
integer n_oset = 0, n_oclr = 0, n_aset = 0, n_aclr = 0;
always @(posedge clk) begin if (osd_set) n_oset = n_oset + 1; if (osd_clr) n_oclr = n_oclr + 1;
                            if (auto_set) n_aset = n_aset + 1; if (auto_clr) n_aclr = n_aclr + 1; end
task pulse; input integer which; begin
    @(negedge clk); case (which) 0: k_alarm = 1; 1: x_alarm = 1; default: k_mute = 1; endcase
    @(negedge clk); k_alarm = 0; x_alarm = 0; k_mute = 0; #(1000);
end endtask
integer n_qnew = 0; reg [1:0] last_qslot = 0;
always @(posedge clk) if (q_new) begin n_qnew = n_qnew + 1; last_qslot = q_new_slot; end
integer fails = 0, n_play = 0, n_stop = 0, n_next = 0, n_prev = 0, n_rej = 0, n_new = 0;
always @(posedge clk) begin if (mplay) n_play = n_play + 1; if (mstop) n_stop = n_stop + 1;
                            if (inext) n_next = n_next + 1; if (iprev) n_prev = n_prev + 1; end
always @(posedge vclk) begin if (v_rej) n_rej = n_rej + 1; if (v_new) n_new = n_new + 1; end
task check; input c; input [8*72-1:0] msg; begin
    if (c) $display("  ok   %0s", msg); else begin $display("  FAIL %0s  (t=%0t)", msg, $time); fails = fails + 1; end
end endtask

// ---------------- 测试用的 UTF-8 字符串（gen_cmd_strings.ps1 生成 cmd_strings.hex；iverilog 的字符串字面量会弄坏中文字节） ----------------
reg [7:0] strs [0:160*512-1];
function integer slen; input integer k; integer i; begin slen = 0; for (i = 0; i < 512; i = i + 1) if (strs[k * 512 + i] != 0 && slen == i) slen = i + 1; end endfunction
// 收到的一行和第 k 条比
reg [7:0] rbuf [0:511]; integer rlen = 0, got_len = 0; reg [7:0] gbuf [0:511];
function same; input integer k; integer i; begin
    same = (got_len == slen(k));
    for (i = 0; i < 512; i = i + 1) if (i < got_len && gbuf[i] != strs[k * 512 + i]) same = 0;
end endfunction
task show_got; integer i; begin for (i = 0; i < got_len; i = i + 1) $write("%c", gbuf[i]); end endtask

// ---------------- 发送 ----------------
task send_byte; input [7:0] b; integer i; begin
    rx = 0; #(BITNS); for (i = 0; i < 8; i = i + 1) begin rx = b[i]; #(BITNS); end rx = 1; #(BITNS);
end endtask
// 发第 k 条字符串
task send_str; input integer k; integer i, n; begin
    n = slen(k);
    for (i = 0; i < n; i = i + 1) send_byte(strs[k * 512 + i]);
    #(BITNS * 2);                              // 两个字节之间的 send_byte 已经留了停止位
end endtask

// ---------------- 收回复：一行（到 \n），存成字符串 ----------------
integer lines = 0;
reg [7:0] lg [0:16*512-1]; integer lglen [0:15];        // 【启事】最近 16 行回复
function same_ln; input integer ln; input integer k; integer i; begin
    same_ln = (lglen[ln % 16] == slen(k));
    for (i = 0; i < 512; i = i + 1) if (i < lglen[ln % 16] && lg[(ln % 16) * 512 + i] != strs[k * 512 + i]) same_ln = 0;
end endfunction
task show_ln; input integer ln; integer i; begin for (i = 0; i < lglen[ln % 16]; i = i + 1) $write("%c", lg[(ln % 16) * 512 + i]); end endtask
initial forever begin : rxl
    reg [7:0] b; integer i;
    @(negedge tx); #(BITNS / 2);
    for (i = 0; i < 8; i = i + 1) begin #(BITNS); b[i] = tx; end
    #(BITNS);
    if (b == 8'h0A) begin for (i = 0; i < 512; i = i + 1) begin gbuf[i] = rbuf[i]; lg[(lines % 16) * 512 + i] = rbuf[i]; end
                          lglen[lines % 16] = rlen; got_len = rlen; rlen = 0; lines = lines + 1; end
    else if (b != 8'h0D) begin rbuf[rlen] = b; rlen = rlen + 1; end
end
task cmd; input integer s; input integer want; input [8*60-1:0] msg; integer l0; begin
    l0 = lines;
    send_str(s);
    fork : w
        begin wait (lines != l0); disable w; end
        begin #(BITNS * 3000 + 50_000_000); disable w; end
    join
    if (lines == l0) begin $display("  FAIL %0s: no reply", msg); fails = fails + 1; end
    else if (!same(want)) begin $write("  FAIL %0s: reply \"", msg); show_got; $display("\""); fails = fails + 1; end
    else begin $write("  ok   %0s  -> ", msg); show_got; $display(""); end
    #(BITNS * 30);
end endtask

// ---------------- 字库（真实 FONT.BIN） ----------------
reg [7:0] font [0:691455];
localparam integer FONT_LEN = 691456;
// 要装的文件：完整版就是 FONT.BIN；小字库版 = FONT.BIN 前 FPAGES 页 + tb 自己算 CRC 的标记页
reg [7:0] file [0:691455];
localparam integer FILE_LEN = FPAGES * 256 + 256;
function [31:0] crc32_upto; input integer n; integer i, j; reg [31:0] c; begin
    c = 32'hFFFFFFFF;
    for (i = 0; i < n; i = i + 1) begin
        c = c ^ {file[i], 24'd0};
        for (j = 0; j < 8; j = j + 1) c = c[31] ? ({c[30:0], 1'b0} ^ 32'h04C11DB7) : {c[30:0], 1'b0};
    end
    crc32_upto = c;
end endfunction
task make_file; integer i; reg [31:0] c; begin
    for (i = 0; i < FILE_LEN; i = i + 1) file[i] = font[i];
`ifdef SMALL
    for (i = 0; i < 256; i = i + 1) file[FPAGES * 256 + i] = 8'hFF;
    file[FPAGES*256+0] = "Z"; file[FPAGES*256+1] = "P"; file[FPAGES*256+2] = "F"; file[FPAGES*256+3] = "O";
    file[FPAGES*256+4] = "N"; file[FPAGES*256+5] = "T"; file[FPAGES*256+6] = "0"; file[FPAGES*256+7] = "1";
    {file[FPAGES*256+8], file[FPAGES*256+9], file[FPAGES*256+10], file[FPAGES*256+11]} = FGLYPHS;
    {file[FPAGES*256+12], file[FPAGES*256+13], file[FPAGES*256+14], file[FPAGES*256+15]} = FPAGES * 256;
    c = crc32_upto(FPAGES * 256);
    {file[FPAGES*256+16], file[FPAGES*256+17], file[FPAGES*256+18], file[FPAGES*256+19]} = c;
`endif
end endtask
task send_font; input integer upto; integer i; begin
    for (i = 0; i < upto; i = i + 1) send_byte(file[i]);
end endtask
// tb 自己查字形：Unicode → 第几个字（和 gen_font.ps1 一样）
function integer gidx; input integer c; begin
    if      (c >= 32'h20   && c <= 32'h7E)   gidx = c - 32'h20;
    else if (c >= 32'hA0   && c <= 32'hFF)   gidx = c - 32'hA0 + 95;
    else if (c >= 32'h2000 && c <= 32'h206F) gidx = c - 32'h2000 + 191;
    else if (c >= 32'h3000 && c <= 32'h303F) gidx = c - 32'h3000 + 303;
    else if (c >= 32'h4E00 && c <= 32'h9FFF) gidx = c - 32'h4E00 + 367;
    else if (c >= 32'hFF00 && c <= 32'hFFEF) gidx = c - 32'hFF00 + 21359;
    else gidx = 31;
end endfunction
// 期望的点阵：按 UTF-8 解码 s，逐字查 font[]，放进 exp[]
reg [15:0] exp [0:1023];
integer exp_n;
task expect_cols; input integer sk; integer i, n, c, w, g, k; reg [7:0] b0, b1, b2; begin
    n = slen(sk);
    exp_n = 0; i = 0;
    while (i < n) begin
        b0 = strs[sk * 512 + i]; b1 = strs[sk * 512 + i + 1]; b2 = strs[sk * 512 + i + 2];
        if (b0 < 8'h80) begin c = b0; i = i + 1; end
        else if (b0[7:5] == 3'b110) begin c = {b0[4:0], b1[5:0]}; i = i + 2; end
        else begin c = {b0[3:0], b1[5:0], b2[5:0]}; i = i + 3; end
        g = gidx(c);
        w = (c <= 32'h7E) ? 8 : 16;
        for (k = 0; k < w; k = k + 1) if (exp_n < 1024) begin
            exp[exp_n] = {font[g * 32 + 2 * k], font[g * 32 + 2 * k + 1]}; exp_n = exp_n + 1;
        end
    end
end endtask
// 【三级应急】应急文字：每行 288 列，一个字放不下就补空列到下一行，最多 3 行（和 serial_cmd 一样）
task expect_alm; input integer sk; integer i, n, c, w, g, k, lc, stop; reg [7:0] b0, b1, b2; begin
    n = slen(sk);
    exp_n = 0; i = 0; lc = 0; stop = 0;
    while (i < n && !stop) begin
        b0 = strs[sk * 512 + i]; b1 = strs[sk * 512 + i + 1]; b2 = strs[sk * 512 + i + 2];
        if (b0 < 8'h80) begin c = b0; i = i + 1; end
        else if (b0[7:5] == 3'b110) begin c = {b0[4:0], b1[5:0]}; i = i + 2; end
        else begin c = {b0[3:0], b1[5:0], b2[5:0]}; i = i + 3; end
        g = gidx(c);
        w = (c <= 32'h7E) ? 8 : 16;
        if (exp_n + w > 864) stop = 1;
        else begin
            if (lc + w > 288) begin
                while (lc < 288) begin exp[exp_n] = 16'd0; exp_n = exp_n + 1; lc = lc + 1; end
                lc = 0;
            end
            if (exp_n + w > 864) stop = 1;
            else for (k = 0; k < w; k = k + 1) begin
                exp[exp_n] = {font[g * 32 + 2 * k], font[g * 32 + 2 * k + 1]}; exp_n = exp_n + 1;
                lc = (lc == 287) ? 0 : lc + 1;
            end
        end
    end
end endtask
task check_alm; input [8*60-1:0] msg; integer i, bad; begin
    bad = 0;
    repeat (20) @(posedge vclk);
    for (i = 0; i < exp_n; i = i + 1) begin
        @(negedge vclk) a_col = i; @(posedge vclk); @(posedge vclk); #1;
        if (rd_bits !== exp[i]) begin if (bad < 3) $display("       col %0d got %h want %h", i, rd_bits, exp[i]); bad = bad + 1; end
    end
    check(v_alen == exp_n && bad == 0, msg);
    $display("       (%0d columns)", exp_n);
end endtask
task check_ram; input [8*60-1:0] msg; integer i, bad; begin
    bad = 0;
    repeat (20) @(posedge vclk);
    for (i = 0; i < exp_n; i = i + 1) begin
        @(negedge vclk) rd_col = i; @(posedge vclk); @(posedge vclk); #1;
        if (rd_bits !== exp[i]) begin if (bad < 3) $display("       col %0d got %h want %h", i, rd_bits, exp[i]); bad = bad + 1; end
    end
    check(v_on && v_len == exp_n && bad == 0, msg);
    $display("       (%0d columns)", exp_n);
end endtask
// 【自定义字幕】等 v_cs，然后从显示侧把通知 RAM 读出来和 exp[] 比（没有通知、长度对、v_cs = 1）
task check_cs; input [8*60-1:0] msg; integer i, bad; begin
    repeat (5) @(posedge vclk);                // 刚换图时 v_cs 还是上一张图的，过一拍才落下：先等它更新
    fork : wc
        begin wait (v_cs); disable wc; end
        begin #(20_000_000); disable wc; end
    join
    bad = 0;
    repeat (20) @(posedge vclk);
    for (i = 0; i < exp_n; i = i + 1) begin
        @(negedge vclk) rd_col = i; @(posedge vclk); @(posedge vclk); #1;
        if (rd_bits !== exp[i]) begin if (bad < 3) $display("       col %0d got %h want %h", i, rd_bits, exp[i]); bad = bad + 1; end
    end
    check(v_cs && !v_on && v_len == exp_n && bad == 0, msg);
    $display("       (%0d columns)", exp_n);
end endtask
integer n_newcs = 0;

reg [15:0] pexp [0:2047];
integer wrapw = 288, wrapmax = 1152, wph = 0, wsm = 0, wtr = 0;       // 【串口照片】带照片：每行 176 列、最多 1056 列，meta 最高位 1
// 【启事】启事页：每行 288 列自动换行，最多 4 行（1152 列），和应急文字一样的画法
task expect_wrap; input integer sk; input integer maxc; integer i, n, c, w, g, k, lc, stop; reg [7:0] b0, b1, b2; begin
    n = slen(sk);
    exp_n = 0; i = 0; lc = 0; stop = 0;
    while (i < n && !stop) begin
        b0 = strs[sk * 512 + i]; b1 = strs[sk * 512 + i + 1]; b2 = strs[sk * 512 + i + 2];
        if (b0 < 8'h80) begin c = b0; i = i + 1; end
        else if (b0[7:5] == 3'b110) begin c = {b0[4:0], b1[5:0]}; i = i + 2; end
        else begin c = {b0[3:0], b1[5:0], b2[5:0]}; i = i + 3; end
        g = gidx(c);
        w = (c <= 32'h7E) ? 8 : 16;
        if (exp_n + w > maxc) stop = 1;
        else begin
            if (lc + w > wrapw) begin
                while (lc < wrapw) begin pexp[exp_n] = 16'd0; exp_n = exp_n + 1; lc = lc + 1; end
                lc = 0;
            end
            if (exp_n + w > maxc) stop = 1;
            else for (k = 0; k < w; k = k + 1) begin
                pexp[exp_n] = {font[g * 32 + 2 * k], font[g * 32 + 2 * k + 1]}; exp_n = exp_n + 1;
                lc = (lc == wrapw - 1) ? 0 : lc + 1;
            end
        end
    end
    wtr = stop;
end endtask
// 【自动字号】和 serial_cmd 一样：先按大字排（每行 288 / 带照片 112 列，最多 1152 / 672 列），放不下按小字（576 / 224 列，最多 2040 列）
task expect_page; input integer sk; begin
    wsm = 0; wrapw = wph ? 112 : 288; expect_wrap(sk, wph ? 672 : 1152);
    if (wtr) begin wsm = 1; wrapw = wph ? 224 : 576; expect_wrap(sk, 2040); end
end endtask
// 请求画第 slot 条到缓冲 b，等 pg_done，再从显示侧把那块缓冲逐列读出来比；meta = {类别, 列数, 第几条, 共几条}
task render_check; input integer slot; input integer b; input integer sk; input integer ty; input integer idx; input integer tot;
                   input [8*60-1:0] msg; integer i, bad; begin
    @(negedge clk) begin pg_slot = slot; pg_buf = b; pg_req = 1; end
    @(negedge clk) pg_req = 0;
    fork : wpg
        begin @(posedge pg_done); disable wpg; end
        begin #(2_000_000_000); disable wpg; end
    join
    expect_page(sk);
    repeat (20) @(posedge vclk);
    bad = 0;
    @(negedge vclk) begin pv_sel = 1; pv_buf = b; end
    for (i = 0; i < exp_n; i = i + 1) begin
        @(negedge vclk) pv_col = i; @(posedge vclk); @(posedge vclk); #1;
        if (rd_bits !== pexp[i]) begin if (bad < 3) $display("       col %0d got %h want %h", i, rd_bits, pexp[i]); bad = bad + 1; end
    end
    check(bad == 0 && pv_meta == {wsm[0], wph[0], ty[1:0], exp_n[10:0], idx[2:0], tot[2:0]}, msg);
    $display("       (%0d columns, meta small %0d photo %0d type %0d idx %0d/%0d)", pv_meta[16:6], pv_meta[20], pv_meta[19], pv_meta[18:17], pv_meta[5:3], pv_meta[2:0]);
    @(negedge vclk) pv_sel = 0;
end endtask
// 发一条，等 n 行回复，逐行和 first..first+n-1（或者 ks 数组）比
integer kexp [0:7];
task cmd_lines; input integer s; input integer n; input [8*60-1:0] msg; integer l0, j, ok; begin
    l0 = lines;
    send_str(s);
    fork : wl
        begin wait (lines >= l0 + n); disable wl; end
        begin #(BITNS * 6000 + 50_000_000); disable wl; end
    join
    ok = (lines == l0 + n);
    for (j = 0; j < n; j = j + 1) if (!same_ln(l0 + j, kexp[j])) ok = 0;
    if (ok) $display("  ok   %0s", msg); else begin $display("  FAIL %0s (%0d lines)", msg, lines - l0); fails = fails + 1; end
    for (j = 0; j < lines - l0 && j < 8; j = j + 1) begin $write("       | "); show_ln(l0 + j); $display(""); end
    #(BITNS * 30);
end endtask

// 【串口照片】照片文件：PPAGES 页数据 + 标记页（"ZPPHOT01" 宽 480 高 640 字节数 CRC）；crc_xor = 故意弄错 CRC
localparam integer PFILE = PPAGES * 256 + 256;
reg [7:0] pfile [0:921855];
task make_photo; input [31:0] crc_xor; integer j, b; reg [31:0] c; begin
    for (j = 0; j < PPAGES * 256; j = j + 1) pfile[j] = (j * 13 + 7) ^ (j >> 8);
    for (j = 0; j < 256; j = j + 1) pfile[PPAGES * 256 + j] = 8'hFF;
    pfile[PPAGES*256+0] = "Z"; pfile[PPAGES*256+1] = "P"; pfile[PPAGES*256+2] = "P"; pfile[PPAGES*256+3] = "H";
    pfile[PPAGES*256+4] = "O"; pfile[PPAGES*256+5] = "T"; pfile[PPAGES*256+6] = "0"; pfile[PPAGES*256+7] = "2";
    {pfile[PPAGES*256+8], pfile[PPAGES*256+9], pfile[PPAGES*256+10], pfile[PPAGES*256+11]} = 32'h02D0_0280;
    {pfile[PPAGES*256+12], pfile[PPAGES*256+13], pfile[PPAGES*256+14], pfile[PPAGES*256+15]} = PPAGES * 256;
    c = 32'hFFFFFFFF;
    for (j = 0; j < PPAGES * 256; j = j + 1) begin
        c = c ^ {pfile[j], 24'd0};
        for (b = 0; b < 8; b = b + 1) c = c[31] ? ({c[30:0], 1'b0} ^ 32'h04C11DB7) : {c[30:0], 1'b0};
    end
    c = c ^ crc_xor;
    {pfile[PPAGES*256+16], pfile[PPAGES*256+17], pfile[PPAGES*256+18], pfile[PPAGES*256+19]} = c;
end endtask
task install_photo; input integer s; input integer want; input [8*60-1:0] msg; integer l0, j; begin
    cmd(s, 112, "photo: erase, then READY");
    l0 = lines; for (j = 0; j < PFILE; j = j + 1) send_byte(pfile[j]); wait (lines != l0);
    check(same(want), msg);
    $write("       reply: "); show_got; $display("");
    #(BITNS * 300);
end endtask
// 照片像素：第 r 行（0 = 最下面）x 在 16~375 = Flash 里第 r 行第 (x-16) 个 8 字节（4 个 RGB565）扩成 888 后的平均，别的地方黑
task check_photo; input [8*60-1:0] msg; integer r, x, j, bad, a; reg [9:0] sb, sg, sr; reg [7:0] ar, ag, ab; reg [23:0] e; reg [15:0] v; begin
    bad = 0;
    for (r = 0; r < PROWS; r = r + 1) for (x = 0; x < 640; x = x + 1) begin
        if (x < 16 || x >= 376) e = 24'd0;
        else begin
            a = r * 2880 + (x - 16) * 8; sb = 0; sg = 0; sr = 0;
            for (j = 0; j < 4; j = j + 1) begin
                v = {flash.phm[a + j * 2], flash.phm[a + j * 2 + 1]};
                sr = sr + {v[15:11], v[15:13]}; sg = sg + {v[10:5], v[10:9]}; sb = sb + {v[4:0], v[4:2]};
            end
            ar = (sr + 10'd2) >> 2; ag = (sg + 10'd2) >> 2; ab = (sb + 10'd2) >> 2;
            e = {ar, ag, ab};
        end
        if (phbuf[r * 640 + x] !== e) begin if (bad < 3) $display("       row %0d x %0d got %h want %h", r, x, phbuf[r * 640 + x], e); bad = bad + 1; end
    end
    check(bad == 0 && ph_n == PROWS * 640, msg);
    $display("       (%0d pixels written)", ph_n);
end endtask
function pv_meta_buf; input b; pv_meta_buf = b ? dut.pm1[19] : dut.pm0[19]; endfunction
reg pg_done_seen = 0; always @(posedge clk) begin if (pg_req) pg_done_seen = 0; if (pg_done) pg_done_seen = 1; end
integer k0, i;
task power_cycle; begin rst = 1; #(1000); rst = 0; wait (dut.st == 7'd1); #(BITNS * 5); end endtask
task install_ok; input [8*60-1:0] msg; integer l0; begin
    cmd(27, 28, "install: erase, then READY");
    l0 = lines; send_font(FILE_LEN); wait (lines != l0);
    check(same(29) && fst == 2'd1, msg);
    $write("       reply: "); show_got; $display("");
end endtask
initial begin
    $readmemh("font_sim.hex", font);
    $readmemh("cmd_strings.hex", strs);
    make_file;
`ifdef QUICK
    // ======================= 真实时钟 + 真实波特率（-DF75 / -DF83）：空 Flash 上电，发几条不需要字库的指令 =======================
    repeat (20) @(posedge clk); rst = 0;
    wait (dut.st == 7'd1); #(BITNS * 5);
    check(fst == 2'd2, "boot on empty flash: font not installed");
    cmd(0, 1, "help: 234-byte reply at the real baud rate");
    cmd(4, 5, "music on");   check(n_play == 1, "music_play pulse");
    cmd(17, 18, "wrong PIN");
    cmd(16, 7, "full-width space + CR LF");
    cmd(126, 127, "subtitle 2 back to default (sector erase + 4 pages at the real SPI speed)");
    check(flash.s_erase == 1 && flash.s_prog == 4, "subtitle sector saved");
`elsif PHREAL
    // ======================= 【串口照片】真实照片：小字库和 PHOTO.BIN 预先放进 Flash，第 1 条启事带照片 =======================
    for (i = 0; i < FILE_LEN; i = i + 1) flash.lo[i] = file[i];
    $readmemh("photo_sim.hex", flash.phm);
    flash.qm[0] = 8'h11; flash.qm[1] = 8'd10;
    for (i = 0; i < 10; i = i + 1) flash.qm[2 + i] = strs[120 * 512 + i];   // "TEL 110 AB"
    flash.qm[2044] = "Q"; flash.qm[2045] = "S"; flash.qm[2046] = "0"; flash.qm[2047] = "2";
    repeat (20) @(posedge clk); rst = 0;
    wait (dut.st == 7'd1); #(BITNS * 5);
    check(fst == 2'd1 && dut.q_mask == 4'b0001 && dut.q_ph == 4'b0001, "boot: font ok, notice 1 with photo");
    ph_n = 0;
    @(negedge clk) begin pg_slot = 0; pg_buf = 0; pg_req = 1; end
    @(negedge clk) pg_req = 0;
    @(posedge pg_done); #(1000);
    check_photo("real photo: 320 rows, 2x2 average");
    check(pv_meta_buf(0) == 1'b1, "meta photo bit");
    begin : dump integer f, r, x; f = $fopen("page_out/photo_sdram.hex", "w");
        for (r = 0; r < 320; r = r + 1) for (x = 16; x < 376; x = x + 1) $fdisplay(f, "%h", phbuf[(319 - r) * 640 + x]);   // 屏上从上到下
        $fclose(f); end
`elsif SMALL
    // ======================= A：装字库（小字库） =======================
    repeat (20) @(posedge clk); rst = 0;
    $display("== A1 empty flash: font not installed");
    wait (dut.st == 6'd1); #(BITNS * 5);
    check(fst == 2'd2, "font_status = 2 (not installed)");
    cmd(2, 3, "notice without font");
    cmd(24, 25, "empty notice is reported before the font check");
    cmd(56, 70, "emergency without font: level set, no text");
    #(1000); check(v_alm == 2'd2 && v_alen == 10'd0 && alm_sd == 2'd2, "level 2, no text");
    cmd(62, 63, "clear");
    #(1000); check(v_alm == 2'd0, "level 0");

    $display("== A2 install over the serial port");
    install_ok("install reply OK, font_status = 1");
    check(flash.blk_cnt == 1 && flash.page_cnt == FPAGES + 1, "1 block erased, data pages + trailer programmed");
    k0 = 0; for (i = 0; i < FILE_LEN; i = i + 1) if (flash.lo[i] !== file[i]) k0 = k0 + 1;
    check(k0 == 0, "flash content == file byte for byte");
    cmd(46, 31, "notice with the small font");
    expect_cols(47); check_ram("notice RAM == glyphs");

    $display("== A3 power cycle: still installed (read back + CRC at boot)");
    power_cycle;
    check(fst == 2'd1, "font_status = 1 after reset");

    $display("== A4 one corrupted byte in flash is caught at boot");
    flash.lo[1000] = flash.lo[1000] ^ 8'h40;
    power_cycle;
    check(fst == 2'd2, "CRC mismatch -> not installed");
    cmd(46, 3, "notice refused");

    $display("== A5 transfer stops half way");
    cmd(52, 28, "install again, no space after PIN");
    k0 = lines; send_font(700); wait (lines != k0);
    check(same(42), "timeout -> broken");
    $write("       reply: "); show_got; $display("");
    cmd(4, 5, "commands work again afterwards");

    $display("== A6 file with a wrong byte");
    file[500] = file[500] ^ 8'h01;
    cmd(27, 28, "install again");
    k0 = lines; send_font(FILE_LEN); wait (lines != k0);
    check(same(43) && fst == 2'd2, "CRC mismatch while receiving -> not installed");
    $write("       reply: "); show_got; $display("");
    file[500] = file[500] ^ 8'h01;
    install_ok("good file installs fine");
    cmd(46, 31, "notice works");

    $display("== A8 【串口照片】install a photo over the serial port");
    cmd(111, 95, "photo for a notice that does not exist");
    cmd(116, 95, "photo 5");
    cmd(117, 95, "photo without a number");
    cmd(119, 74, "publish notice 1 (ASCII: the small font)");
    make_photo(32'h00000000);
    k0 = n_qnew;
    install_photo(111, 113, "photo 1: READY, file, OK");
    check(dut.q_ph == 4'b0001 && n_qnew == k0 + 1 && last_qslot == 2'd0, "slot 1 has a photo, q_new (insert again)");
    check(flash.ph_blk == 1 && flash.ph_prog == PPAGES + 1, "1 block erased, data pages + trailer programmed");
    k0 = 0; for (i = 0; i < PFILE; i = i + 1) if (flash.phm[i] !== pfile[i]) k0 = k0 + 1;
    check(k0 == 0, "flash 0x200000.. == file byte for byte");
    check(flash.qm[0] == 8'h11, "notice sector: type byte has the photo bit");
    check(fst == 2'd1, "font still installed");
    power_cycle;
    check(dut.q_ph == 4'b0001, "power cycle: photo kept (marker ok)");
    flash.phm[PPAGES * 256 + 3] = 8'h00;
    power_cycle;
    check(dut.q_ph == 4'b0000 && dut.q_mask == 4'b0001, "marker broken -> photo dropped, notice kept");
    flash.phm[PPAGES * 256 + 3] = "H";
    power_cycle;
    check(dut.q_ph == 4'b0001, "marker back -> photo again");

    $display("== A9 【串口照片】bad file / broken transfer / slot reused");
    cmd(121, 77, "publish notice 2");
    make_photo(32'h00000001);        // CRC wrong
    install_photo(118, 114, "photo 2 with a wrong CRC -> bad");
    check(dut.q_ph == 4'b0001 && fst == 2'd1, "no photo on slot 2, font fine");
    make_photo(32'h00000000);
    cmd(118, 112, "photo 2 again, READY");
    k0 = lines; for (i = 0; i < 300; i = i + 1) send_byte(pfile[i]); wait (lines != k0);
    check(same(115) && dut.q_ph == 4'b0001 && fst == 2'd1, "transfer stops -> broken, font fine");
    $write("       reply: "); show_got; $display("");
    install_photo(118, 113, "photo 2 ok");
    check(dut.q_ph == 4'b0011, "slots 1 and 2 have photos");
    cmd(93, 94, "undo 2");
    check(dut.q_ph == 4'b0001 && flash.qm[512] == 8'h00, "undo clears the photo");
    cmd(121, 77, "publish into slot 2 again");
    check(dut.q_ph == 4'b0001 && flash.qm[512] == 8'h02, "new notice in slot 2 has no photo");

    $display("== A10 【串口照片】render: text 176 columns per line + photo 2x2 average into SDRAM");
    for (i = 0; i < PROWS * 2880; i = i + 1) flash.phm[i] = (i * 37 + (i >> 7)) & 255;
    wrapw = 112; wrapmax = 672; wph = 1;
    ph_n = 0;
    render_check(0, 1, 120, 1, 1, 2, "page buffer 1 == notice 1 wrapped at 112, meta photo bit");
    check_photo("photo pixels == 2x2 average, black around");
    check(ph_pbuf == 1'b1, "photo goes to buffer 1");
    wrapw = 288; wrapmax = 1152; wph = 0;
    render_check(1, 0, 122, 2, 2, 2, "notice 2 has no photo: unchanged layout");
    $display("== A11 【串口照片】a command while the photo is drawn: rest black, page without photo");
    ph_n = 0;
    @(negedge clk) begin pg_slot = 0; pg_buf = 0; pg_req = 1; end
    @(negedge clk) pg_req = 0;
    wait (dut.st == 7'd75); #(BITNS * 200);
    cmd(0, 1, "help during the photo: answered right after");
    wait (!ph_need); #(1000);
    check(ph_n == PROWS * 640 && pv_meta_buf(0) == 1'b0, "all pixels still written, meta photo bit 0");
    $display("== A12 【串口照片】SDRAM busy (image loading): wait for the grant");
    ph_hold = 1; ph_n = 0;
    @(negedge clk) begin pg_slot = 0; pg_buf = 1; pg_req = 1; end
    @(negedge clk) pg_req = 0;
    wait (ph_need); #(5_000_000);
    check(ph_need && !ph_wreq && ph_n == 0 && !pg_done_seen, "waits while the write port is busy");
    ph_hold = 0;
    wait (!ph_need); #(1000);
    check(ph_n == PROWS * 640 && pv_meta_buf(1) == 1'b1, "then draws the photo");

    $display("== A14 【自动字号】photo + long text: small type, 224 columns per line, photo still drawn");
    cmd(144, 80, "publish notice 3: 152 ASCII characters");
    make_photo(32'h00000000);
    install_photo(145, 113, "photo 3");
    for (i = 0; i < PROWS * 2880; i = i + 1) flash.phm[2 * 1048576 + i] = flash.phm[i];   // 照片 3 的像素和 1 一样，check_photo 照常比
    for (i = 0; i < PROWS * 2880; i = i + 1) flash.phm[i] = flash.phm[2 * 1048576 + i];
    wph = 1; ph_n = 0;
    render_check(2, 0, 146, 1, 3, 3, "page = notice 3 (寻人) in small type with a photo");
    check(pv_meta_buf(0) == 1'b1 && dut.pm0[20], "meta: photo + small");
    wph = 0;
    $display("== A13 【自定义字幕】字幕n: saved to flash, drawn into the notice RAM for the picture on screen");
    check(dut.s_mask == 4'd0 && !v_cs, "blank sector -> no custom subtitles");
    k0 = dut.q_mask;
    cmd(128, 129, "subtitle 5 -> asks for 1~4");
    cmd(130, 129, "subtitle without a number");
    cmd(14, 15, "字幕开 still means the on/off switch");
    cmd(46, 31, "a notice on the strip first");
    v_shown = 4'd1;
    cmd(136, 124, "subtitle 1 = HI 42 (a notice is on: not drawn yet)");
    check(dut.s_mask == 4'b0001 && flash.s_erase == 1 && flash.s_prog == 4, "saved: 1 sector erase + 4 pages");
    check(flash.sm[0] == 8'd1 && flash.sm[1] == 8'd5 && flash.sm[2] == "H" && flash.sm[6] == "2", "flash: flag, length, text");
    check(flash.sm[1020] == "S" && flash.sm[1021] == "B" && flash.sm[1022] == "0" && flash.sm[1023] == "1", "flash: marker SB01");
    check(dut.q_mask == k0 && flash.qm[2044] == "Q", "notices untouched");
    #(2_000_000); check(v_on && !v_cs, "notice keeps the strip");
    cmd(37, 38, "clear the notice");
    expect_cols(137); check_cs("custom subtitle drawn: RAM == glyphs of HI 42, v_cs = 1");
    v_shown = 4'd2; #(2_000_000);
    check(!v_cs, "picture 2 (no custom subtitle): default text");
    k0 = n_new; v_shown = 4'd1;
    check_cs("back to picture 1: the RAM still holds it, shown at once");
    #(2_000_000); check(n_new == k0, "nothing redrawn");
    cmd(46, 31, "a notice while the custom subtitle is shown");
    #(1000); check(v_on && !v_cs, "notice takes the strip");
    expect_cols(47); check_ram("notice RAM == notice glyphs");
    cmd(37, 38, "clear the notice");
    expect_cols(137); check_cs("custom subtitle comes back");
    cmd(59, 60, "level 3");
    #(2_000_000); check(!v_cs, "level 3: default subtitle (read port may be the alarm text)");
    cmd(62, 63, "clear");
    check_cs("custom subtitle again after the emergency");
    power_cycle;
    check(dut.s_mask == 4'b0001, "power cycle: subtitle 1 kept");
    check_cs("drawn from the text read back from flash");
    flash.sm[1021] = "X";
    power_cycle;
    #(2_000_000); check(dut.s_mask == 4'd0 && !v_cs, "broken marker -> default subtitles");
    flash.sm[1021] = "B";
    power_cycle;
    check(dut.s_mask == 4'b0001, "marker back -> custom subtitle again");
    v_shown = 4'd2;
    cmd(134, 124, "subtitle 2 (picture 2 on screen)");
    #(2_000_000); check(dut.s_mask == 4'b0011 && v_cs && dut.cs_slot == 2'd1, "drawn right away");
    cmd(126, 127, "subtitle 2 with no text -> back to the default");
    #(2_000_000); check(dut.s_mask == 4'b0001 && !v_cs && flash.sm[256] == 8'd0 && flash.sm[0] == 8'd1, "slot 2 cleared in flash, slot 1 kept");
    power_cycle;
    check(dut.s_mask == 4'b0001, "after power cycle: only subtitle 1");
    cmd(131, 132, "subtitle 4 with 70 characters -> warned");
    check(dut.s_mask == 4'b1001, "subtitle 4 stored");

    $display("== A7 the PC tool's file and the parameter area are never touched");
    check(flash.bad_access == 0, "no access outside font area / parameter slots");
`else
    // ======================= B：全部指令（完整字库预先放进 Flash） =======================
    #1; for (i = 0; i < 691456; i = i + 1) flash.lo[i] = font[i];
    repeat (20) @(posedge clk); rst = 0;
    $display("== B1 boot: the full font is read back and verified");
    wait (dut.st == 6'd1); #(BITNS * 5);
    check(fst == 2'd1, "font_status = 1");
    cmd(0, 1, "help");

    $display("== B2 simple commands (no line ending, end = 20 ms pause)");
    cmd(4, 5, "music on");   check(n_play == 1, "music_play pulse");
    cmd(6, 7, "music off");  check(n_stop == 1, "music_stop pulse");
    cmd(8, 9, "next");       check(n_next == 1, "img_next pulse");
    cmd(10, 11, "prev");     check(n_prev == 1, "img_prev pulse");
    cmd(12, 13, "subtitles off"); #(1000); check(n_oclr == 1 && !v_sub, "osd_clr pulse (switch is in sd_card_bmp4 now)");
    cmd(14, 15, "extra spaces around"); #(1000); check(n_oset == 1 && !v_sub, "osd_set pulse");
    cmd(16, 7, "full-width space + CR LF");
    cmd(48, 5, "no space after PIN");  check(n_play == 2, "music_play pulse");
    // 【波形开关】【分辨率显示】
    cmd(148, 149, "波形关"); #(1000); check(n_wclr == 1 && n_wset == 0, "wave_clr pulse");
    cmd(150, 151, "波形开"); #(1000); check(n_wset == 1 && n_wclr == 1, "wave_set pulse");
    cmd(152, 153, "分辨率开"); #(1000); check(n_rset == 1 && n_rclr == 0, "res_set pulse");
    cmd(154, 155, "分辨率关 with spaces"); #(1000); check(n_rclr == 1 && n_rset == 1, "res_clr pulse");
    cmd(156, 22, "波形 alone = unknown");
    cmd(157, 22, "分辨率开了 = unknown (only spaces may follow)");
    check(n_wset == 1 && n_wclr == 1 && n_rset == 1 && n_rclr == 1 && n_oset == 1 && n_oclr == 1, "no extra switch pulses");

    $display("== B3 wrong PIN / unknown command / emergency");
    k0 = n_rej;
    cmd(17, 18, "wrong PIN");
    #(1000); check(n_rej == k0 + 1 && n_play == 2, "reject pulse, music not touched");
    cmd(19, 18, "no PIN");
    cmd(20, 18, "PIN with an extra digit");
    cmd(51, 18, "PIN with a letter right after");
    cmd(21, 22, "unknown command");
    cmd(23, 22, "keyword with junk after");
    cmd(24, 25, "empty notice");
    emerg = 1;
    cmd(8, 26, "next in emergency");
    cmd(12, 13, "subtitle switch still works in emergency");
    emerg = 0;

    $display("== B4 notices");
    k0 = n_new;
    cmd(30, 31, "Chinese + English notice");
    expect_cols(32); check_ram("notice RAM == glyphs from FONT.BIN");
    check(n_new == k0 + 1, "v_new pulse");
    cmd(33, 31, "colon right after the keyword");
    expect_cols(34); check_ram("second notice");
    cmd(49, 31, "no spaces at all");
    expect_cols(50); check_ram("RAM ok");
    cmd(35, 36, "70 characters -> truncated");
    check(v_len == 11'd1024, "length 1024");
    cmd(44, 31, "emoji drawn as ?, full-width A");
    expect_cols(45); check_ram("RAM ok");
    cmd(37, 38, "clear");
    #(1000); check(!v_on, "notice off");

    $display("== B5 three-level emergency");
    cmd(30, 31, "a normal notice first");
    expect_cols(32);
    cmd(53, 54, "level 1 + fire (type template)");
    #(1000); check(alm_sd == 2'd1 && v_alm == 2'd1, "level 1");
    expect_alm(55); check_alm("alarm RAM == fire template");
    check(v_on && v_len == {1'b0, v_alen} && v_alen != 0, "【应急改版】level 1 with text: strip scrolls the emergency text");
    cmd(4, 26, "music refused during serial level 1");
    cmd(56, 57, "level 2 (level template)");
    #(1000); check(v_alm == 2'd2, "level 2");
    expect_alm(58); check_alm("alarm RAM == level-2 template");
    cmd(59, 60, "level 3 + custom text");
    #(1000); check(v_alm == 2'd3 && v_on && v_len == {1'b0, v_alen}, "level 3: strip scrolls the emergency text, normal notice paused");
    expect_alm(61); check_alm("alarm RAM == custom text");
    @(negedge vclk) pv_sel = 1; #(1000);
    check(!v_on && !dut.v_alm_rd, "【应急改版】level 3 on a notice page: no strip, read port goes to the page");
    @(negedge vclk) pv_sel = 0; #(1000);
    check(v_on && dut.v_alm_rd, "back on a picture: strip + emergency text again");
    cmd(4, 5, "music allowed in level 3");
    cmd(71, 60, "level 3 + fault (type template)");
    expect_alm(72); check_alm("alarm RAM == fault template");
    cmd(62, 63, "clear");
    #(1000); check(v_alm == 2'd0 && v_on && alm_sd == 2'd0, "cleared, notice is back");
    expect_cols(32); check_ram("notice untouched by the emergency text");
    pulse(0); #(1000);
    check(v_alm == 2'd1 && v_alen == 0 && !v_on, "【应急改版】key level 1 (no text): strip shows the fixed emergency subtitle, not the notice");
    pulse(0); #(1000);
    expect_cols(32);
    check(v_alm == 2'd0 && v_on && v_len == exp_n, "key clear: notice is back (its own length)");
    sw1 = 1; #(1000);
    check(v_alm == 2'd1 && alm_sd == 2'd0, "SW1 alone = level 1");
    cmd(59, 60, "level 3 while SW1 is on");
    #(1000); check(v_alm == 2'd1, "SW1 overrides serial level 3");
    cmd(62, 64, "serial clear while SW1 is on -> told to switch SW1 off");
    #(1000); check(v_alm == 2'd1 && alm_sd == 2'd0, "still level 1 (hardware)");
    sw1 = 0; #(1000);
    check(v_alm == 2'd0, "SW1 off -> level 0");
    cmd(65, 54, "colon after keyword");
    expect_alm(66); check_alm("alarm RAM == quake template");
    cmd(68, 54, "long text: wraps per line, 3 lines max");
    expect_alm(69); check_alm("alarm RAM == wrapped text");
    check(v_alen == 10'd864, "3 full lines");
    cmd(67, 22, "unknown level -> unknown command");
    cmd(62, 63, "clear");
    check(flash.bad_access == 0, "no access outside font area / parameter slots");

    $display("== B6 notice board (启事)");
    check(q_mask == 4'd0, "blank flash sector -> no notices at boot");
    k0 = n_qnew;
    cmd(73, 74, "publish 寻人");
    check(q_mask == 4'b0001 && n_qnew == k0 + 1 && last_qslot == 2'd0, "slot 1 used, q_new pulse");
    check(flash.q_erase == 1 && flash.q_prog == 8, "saved: 1 sector erase + 8 pages");
    k0 = 0; for (i = 0; i < slen(75); i = i + 1) if (flash.qm[2 + i] !== strs[75 * 512 + i]) k0 = k0 + 1;
    check(flash.qm[0] == 8'd1 && flash.qm[1] == slen(75) && k0 == 0, "flash: type, length, UTF-8 text");
    check(flash.qm[2044] == "Q" && flash.qm[2045] == "S" && flash.qm[2046] == "0" && flash.qm[2047] == "2", "flash: marker QS02");
    render_check(0, 0, 75, 1, 1, 1, "page buffer 0 == wrapped glyphs of notice 1");
    cmd(76, 77, "publish 寻物启事：... (the word 启事 and the colon are skipped)");
    render_check(1, 1, 78, 2, 2, 2, "page buffer 1 == notice 2");
    render_check(0, 0, 75, 1, 1, 2, "buffer 0 again (count now 2)");
    cmd(79, 80, "publish 失物招领");
    cmd(82, 83, "publish 招领：");
    check(q_mask == 4'b1111, "4 notices");
    cmd(85, 86, "5th notice -> full");
    kexp[0] = 88; kexp[1] = 89; kexp[2] = 90; kexp[3] = 91; kexp[4] = 92;
    cmd_lines(87, 5, "list: header + 4 lines with the original text");

    $display("== B7 undo, power cycle");
    cmd(93, 94, "undo 2");
    check(q_mask == 4'b1101, "slot 2 free");
    cmd(93, 95, "undo 2 again -> no such notice");
    cmd(96, 95, "undo 9 -> no such notice");
    kexp[0] = 88; kexp[1] = 89; kexp[2] = 97; kexp[3] = 91; kexp[4] = 92;
    cmd_lines(87, 5, "list shows slot 2 empty");
    power_cycle;
    check(q_mask == 4'b1101, "after power cycle: the same 3 notices");
    render_check(3, 1, 84, 3, 3, 3, "notice 4 drawn from the text read back from flash");
    cmd(73, 77, "publish again -> goes into the free slot 2");
    check(q_mask == 4'b1111 && last_qslot == 2'd1, "first free slot (2) reused");
    flash.qm[2045] = "X";
    power_cycle;
    check(q_mask == 4'd0, "broken marker -> all notices dropped (no garbage on screen)");
    cmd(98, 99, "undo all (rewrites a clean sector)");
    power_cycle;
    check(q_mask == 4'd0, "still empty after power cycle");

    $display("== B8 long text, empty text, commands arriving while saving");
    cmd(100, 74, "80 characters -> published (fits in small type, no warning)");
    render_check(0, 0, 102, 1, 1, 1, "【自动字号】big type would cut it: drawn in small type, 36 per line");
    check(pv_meta[20] && pv_meta[16:6] == 11'd1280, "small type, 1280 columns (80 characters)");
    cmd(138, 101, "140 characters -> published, warned it may not fit");
    render_check(1, 1, 139, 1, 2, 2, "small type, cut at 127 characters");
    check(pv_meta[20] && pv_meta[16:6] == 11'd2032, "2032 columns");
    kexp[0] = 88; kexp[1] = 140; kexp[2] = 141; kexp[3] = 142; kexp[4] = 143;
    cmd_lines(87, 5, "list sends the whole 420-byte text back");
    power_cycle;
    check(q_mask == 4'b0011, "power cycle: both long notices kept (length > 255 read back)");
    render_check(1, 0, 139, 1, 2, 2, "long notice drawn from flash");
    cmd(93, 94, "undo 2 (the rest of B8 publishes into slot 2)");
    cmd(103, 25, "寻人 with no text");
    // 发布以后不等回复，马上发下一条（保存 Flash 的时候收）：两条都要回复
    k0 = lines;
    send_str(76);
    #(BITNS * 200);                                 // > 20ms 停顿：第一条已经结束
    send_str(4);
    fork : w2
        begin wait (lines >= k0 + 2); disable w2; end
        begin #(50_000_000); disable w2; end
    join
    check(lines == k0 + 2 && same_ln(k0, 77) && same_ln(k0 + 1, 5), "second command received while the first was saving");
    $write("       | "); show_ln(k0); $display(""); $write("       | "); show_ln(k0 + 1); $display("");
    // 画启事页的时候发指令：照收
    @(negedge clk) begin pg_slot = 0; pg_buf = 1; pg_req = 1; end
    @(negedge clk) pg_req = 0;
    cmd(6, 7, "command sent while a page is being drawn");
    check(flash.bad_access == 0, "no flash access outside font / notice sector / parameter slots");

    $display("== B9 keys / dry contact / mute (按键改造)");
    k0 = n_aset;
    cmd(104, 105, "auto on");  check(n_aset == k0 + 1, "auto_set pulse");
    k0 = n_aclr;
    cmd(106, 107, "auto off"); check(n_aclr == k0 + 1, "auto_clr pulse");
    cmd(108, 110, "mute with no emergency -> error");
    pulse(0); #(1000);
    check(alm_sd == 2'd1 && v_alm == 2'd1 && v_alen == 10'd0, "key: level 1, no text");
    cmd(4, 26, "music refused during key level 1");
    cmd(108, 109, "mute");
    #(1000); check(muted && v_mute && v_alm == 2'd1, "muted, still level 1 on screen");
    cmd(56, 57, "level 2 by serial");
    #(1000); check(v_alm == 2'd2 && !muted && !v_mute, "level changed -> sound back");
    pulse(2);
    check(muted, "key mute in level 2");
    pulse(0);
    check(alm_sd == 2'd0 && !muted, "key again: cleared (was level 2), mute reset");
    pulse(2);
    check(!muted, "key mute with no emergency: ignored");
    pulse(1);
    check(alm_sd == 2'd1, "dry contact: level 1");
    cmd(53, 54, "serial level 1 + fire while dry-contact level 1");
    expect_alm(55); check_alm("text drawn");
    pulse(1);
    check(alm_sd == 2'd1 && v_alen == exp_n, "dry contact again while level 1: text kept");
    cmd(62, 63, "serial clear");
    #(1000); check(alm_sd == 2'd0 && v_alm == 2'd0, "cleared by serial (same state as the key)");
    cmd(0, 1, "help lists the new commands");

    $display("== B10 【自定义字幕】Chinese text, 64-character limit, notice first");
    cmd(37, 38, "clear the notice first");
    v_shown = 4'd2;
    cmd(123, 124, "字幕2 欢迎回家 Welcome");
    expect_cols(125); check_cs("custom subtitle RAM == glyphs from FONT.BIN");
    cmd(131, 132, "字幕4：70 characters (colon skipped) -> warned");
    v_shown = 4'd4;
    expect_cols(133); check_cs("first 64 characters");
    check(v_len == 11'd1024, "1024 columns");
    cmd(30, 31, "a notice");
    #(1000); check(v_on && !v_cs, "notice takes the strip");
    cmd(37, 38, "clear the notice");
    check_cs("subtitle 4 back");
    cmd(134, 124, "change subtitle 2 while picture 4 is shown");
    v_shown = 4'd2;
    expect_cols(135); check_cs("picture 2 shows the new text");
    cmd(126, 127, "subtitle 2 back to the default");
    #(2_000_000); check(!v_cs && dut.s_mask == 4'b1000, "default text on picture 2");
    check(flash.bad_access == 0, "no flash access outside the allowed areas");
`endif
    $display("RESULT fails=%0d %s", fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
endmodule
