`timescale 1ns/1ps
// 【分辨率显示】【波形开关】osd_layer：左上角原图分辨率标签、波形单独开关、原来的 1E00 状态条已去掉
//   用 640×480 时序（800×525）跑 osd_layer，每种情况跑 2 帧，导出第 2 帧为 osd_out/*.bmp，并逐像素核对：
//   - 标签字符：按同样的 5×7 字模在 tb 里独立画一遍期望图，和输出比（只比标签区域，其余区域必须等于输入）
//   - 关掉 / 菜单 / 应急 / 缩略图时标签区域等于输入；左上角原状态条位置等于输入
//   - 波形 enable = wave_on && res_info[33] && !alert && !thumb_on && 已出图，和字幕开关无关
//   用法：mkdir -p osd_out; iverilog -g2005 -o osd_res.out -s tb_osd_res tb_osd_res.v ../osd_layer.v ../subtitle_strip.v
//          ../subtitle_rom.v ../promax_audio_waveform.v ../param_bar_overlay.v && vvp -n osd_res.out
module tb_osd_res;
reg clk = 0, rst_n = 0; always #20 clk = ~clk;
reg [9:0] hc = 0, vc = 0;
always @(posedge clk) begin
    if (hc == 799) begin hc <= 0; vc <= (vc == 524) ? 0 : vc + 1; end else hc <= hc + 1;
end
wire de = (hc < 640) && (vc < 480);
wire vs = !((vc >= 490) && (vc < 492));
// 输入画面：斜条纹，方便看压暗效果
wire [23:0] rgb_in = {hc[7:0] ^ vc[7:0], 8'h80 + vc[7:0], hc[8:1]};

reg        osd_on = 1, menu_on = 0, alert = 0, thumb_on = 0, wave_on = 1;
reg [3:0]  img = 4'd1;
reg [33:0] res = 34'd0;
wire [23:0] rgb_out;
osd_layer dut (
    .clk(clk), .rst_n(rst_n), .vs(vs), .de(de), .rgb_in(rgb_in),
    .img_num(img), .auto_on(1'b1), .err_code(4'd0),
    .subtitle_on(1'b1), .subtitle_text(96'd0), .subtitle_len(6'd0),
    .wave_on(wave_on), .pcm_valid(1'b0), .pcm_left(16'sd0),
    .osd_on(osd_on), .menu_on(menu_on), .menu_sel(2'd0), .bri_pct(8'd100), .con_pct(8'd100), .vol_pct(8'd80), .period_idx(3'd1),
    .alert(alert), .thumb_on(thumb_on),
    .notice_on(1'b0), .notice_len(11'd0), .notice_new(1'b0), .notice_col(), .notice_bits(16'd0), .notice_cs(1'b0),
    .res_info(res), .alm_level(2'd0), .rgb_out(rgb_out));

// ---------------- 抓一帧 ----------------
reg [23:0] fb_in  [0:640*480-1];
reg [23:0] fb_out [0:640*480-1];
integer fcnt = 0;
reg cap = 0;
always @(posedge clk) begin
    if (cap && de) begin fb_in[vc*640+hc] <= rgb_in; fb_out[vc*640+hc] <= rgb_out; end
end
task frames; input integer n; integer k; begin
    for (k = 0; k < n; k = k + 1) begin wait (vc == 481); wait (vc == 482); end
end endtask
task grab; begin frames(1); wait (vc == 0 && hc == 0); cap = 1; wait (vc == 480); cap = 0; end endtask

task save_bmp; input [8*40-1:0] name; integer fd, x, y, i; reg [23:0] p; begin
    fd = $fopen(name, "wb");
    $fwrite(fd, "BM"); $fwrite(fd, "%c%c%c%c", 8'h36, 8'h10, 8'h0E, 8'h00);   // 54 + 640*480*3 = 921654
    $fwrite(fd, "%c%c%c%c%c%c%c%c", 0,0,0,0, 54,0,0,0);
    $fwrite(fd, "%c%c%c%c%c%c%c%c%c%c%c%c", 40,0,0,0, 8'h80,8'h02,0,0, 8'hE0,8'h01,0,0);
    $fwrite(fd, "%c%c%c%c", 1,0,24,0);
    for (i = 0; i < 24; i = i + 1) $fwrite(fd, "%c", 0);
    for (y = 479; y >= 0; y = y - 1) for (x = 0; x < 640; x = x + 1) begin
        p = fb_out[y*640+x]; $fwrite(fd, "%c%c%c", p[7:0], p[15:8], p[23:16]);
    end
    $fclose(fd);
end endtask

// ---------------- 期望图：同样的字模，独立实现 ----------------
function [4:0] g; input [3:0] c; input [2:0] r; begin
    g = 0;
    case (c)
        0: case(r) 0:g=5'b01110;1:g=5'b10001;2:g=5'b10011;3:g=5'b10101;4:g=5'b11001;5:g=5'b10001;6:g=5'b01110;endcase
        1: case(r) 0:g=5'b00100;1:g=5'b01100;2:g=5'b00100;3:g=5'b00100;4:g=5'b00100;5:g=5'b00100;6:g=5'b01110;endcase
        2: case(r) 0:g=5'b01110;1:g=5'b10001;2:g=5'b00001;3:g=5'b00010;4:g=5'b00100;5:g=5'b01000;6:g=5'b11111;endcase
        3: case(r) 0:g=5'b11110;1:g=5'b00001;2:g=5'b00001;3:g=5'b01110;4:g=5'b00001;5:g=5'b00001;6:g=5'b11110;endcase
        4: case(r) 0:g=5'b00010;1:g=5'b00110;2:g=5'b01010;3:g=5'b10010;4:g=5'b11111;5:g=5'b00010;6:g=5'b00010;endcase
        5: case(r) 0:g=5'b11111;1:g=5'b10000;2:g=5'b10000;3:g=5'b11110;4:g=5'b00001;5:g=5'b00001;6:g=5'b11110;endcase
        6: case(r) 0:g=5'b01110;1:g=5'b10000;2:g=5'b10000;3:g=5'b11110;4:g=5'b10001;5:g=5'b10001;6:g=5'b01110;endcase
        7: case(r) 0:g=5'b11111;1:g=5'b00001;2:g=5'b00010;3:g=5'b00100;4:g=5'b01000;5:g=5'b01000;6:g=5'b01000;endcase
        8: case(r) 0:g=5'b01110;1:g=5'b10001;2:g=5'b10001;3:g=5'b01110;4:g=5'b10001;5:g=5'b10001;6:g=5'b01110;endcase
        9: case(r) 0:g=5'b01110;1:g=5'b10001;2:g=5'b10001;3:g=5'b01111;4:g=5'b00001;5:g=5'b00001;6:g=5'b01110;endcase
        10: case(r) 2:g=5'b10001;3:g=5'b01010;4:g=5'b00100;5:g=5'b01010;6:g=5'b10001;endcase   // x
        11: case(r) 3:g=5'b11111;endcase                                                     // -
        12: case(r) 0:g=5'b10000;1:g=5'b01000;2:g=5'b00100;3:g=5'b00010;4:g=5'b00100;5:g=5'b01000;6:g=5'b10000;endcase   // >
    endcase
end endfunction

// 期望字符串：十进制宽高（tb 自己从整数算）
reg [3:0] es [0:31];
integer en;
task build_str; input integer w; input integer h; integer d, k, started; begin
    en = 0; started = 0;
    for (k = 1000; k >= 1; k = k / 10) begin d = (w / k) % 10; if (d != 0 || started || k == 1) begin es[en] = d; en = en + 1; started = 1; end end
    es[en] = 10; en = en + 1;
    started = 0;
    for (k = 1000; k >= 1; k = k / 10) begin d = (h / k) % 10; if (d != 0 || started || k == 1) begin es[en] = d; en = en + 1; started = 1; end end
    es[en] = 15; es[en+1] = 11; es[en+2] = 12; es[en+3] = 15; es[en+4] = 6; es[en+5] = 4; es[en+6] = 0;
    es[en+7] = 10; es[en+8] = 4; es[en+9] = 8; es[en+10] = 0; en = en + 11;
end endtask

integer fails = 0;
task check; input c; input [8*80-1:0] msg; begin
    if (c) $display("  ok   %0s", msg); else begin $display("  FAIL %0s", msg); fails = fails + 1; end
end endtask

// show = 1：标签区按期望画；show = 0：整个左上区域等于输入
task verify; input show; input [8*60-1:0] msg; integer x, y, bad, xe, c, r, gc; reg [23:0] exp, pin; reg [4:0] row; begin
    bad = 0;
    xe = 16 + en * 12;
    for (y = 0; y < 40; y = y + 1) for (x = 0; x < 400; x = x + 1) begin
        pin = fb_in[y*640+x];
        exp = pin;
        if (show && x >= 10 && x < xe + 6 && y >= 6 && y < 30) begin
            exp = {2'b00, pin[23:18], 2'b00, pin[15:10], 2'b00, pin[7:2]};
            if (x >= 16 && x < xe && y >= 10 && y < 24) begin
                c = (x - 16) / 12; gc = ((x - 16) % 12) / 2; r = (y - 10) / 2;
                row = g(es[c], r);
                if (gc < 5 && row[4 - gc]) exp = 24'hF0F0F0;
            end
        end
        if (fb_out[y*640+x] !== exp) begin
            if (bad < 3) $display("    pixel (%0d,%0d) got %h exp %h", x, y, fb_out[y*640+x], exp);
            bad = bad + 1;
        end
    end
    check(bad == 0, msg);
end endtask

function [15:0] bcd; input integer v; reg [3:0] a, b, c, d; begin a = v/1000 % 10; b = v/100 % 10; c = v/10 % 10; d = v % 10; bcd = {a, b, c, d}; end endfunction
task set_res; input wv; input sh; input integer w; input integer h; begin
    res = {wv, sh, bcd(w), bcd(h)};
end endtask

initial begin
    repeat (5) @(posedge clk); rst_n = 1;

    $display("== 1 1078x1262");
    set_res(1, 1, 1078, 1262); build_str(1078, 1262); grab; save_bmp("osd_out/res_1078x1262.bmp");
    verify(1, "label 1078x1262 -> 640x480 pixel-exact");
    $display("== 2 other sizes");
    set_res(1, 1, 640, 480); build_str(640, 480); grab; save_bmp("osd_out/res_640x480.bmp");
    verify(1, "label 640x480 -> 640x480");
    set_res(1, 1, 1, 1); build_str(1, 1); grab; verify(1, "label 1x1");
    set_res(1, 1, 4096, 4096); build_str(4096, 4096); grab; save_bmp("osd_out/res_4096x4096.bmp");
    verify(1, "label 4096x4096");
    set_res(1, 1, 10, 2005); build_str(10, 2005); grab; verify(1, "label 10x2005 (zeros inside numbers kept)");
    $display("== 3 hidden");
    set_res(1, 0, 1078, 1262); grab; save_bmp("osd_out/res_off.bmp"); verify(0, "res off: top-left = input (old 1E00 bar gone)");
    set_res(1, 1, 1078, 1262); build_str(1078, 1262);
    menu_on = 1; grab; menu_on = 0;
    begin : chk_menu integer x, y, bad; bad = 0;
        for (y = 0; y < 40; y = y + 1) for (x = 0; x < 120; x = x + 1) if (fb_out[y*640+x] !== fb_in[y*640+x]) bad = bad + 1;
        check(bad == 0, "menu open: label hidden (param bar takes the top)");
    end
    alert = 1; grab; alert = 0; verify(0, "emergency: label hidden");
    thumb_on = 1; grab; thumb_on = 0; verify(0, "thumbnail: label hidden");
    img = 4'd0; grab; img = 4'd1; verify(0, "no picture yet: label hidden");
    osd_on = 0; grab; osd_on = 1; verify(1, "subtitle switch off: label still shown (independent)");

    $display("== 4 waveform enable");
    set_res(1, 1, 1078, 1262); frames(1);
    check(dut.u_waveform.enable === 1'b1, "wave on");
    set_res(0, 1, 1078, 1262); frames(1);
    check(dut.u_waveform.enable === 1'b0, "wave switch off: waveform hidden");
    set_res(1, 1, 1078, 1262); osd_on = 0; frames(1);
    check(dut.u_waveform.enable === 1'b1, "subtitle off, wave on: waveform still shown");
    check(dut.u_subtitle.enable === 1'b0, "subtitle off: subtitle hidden");
    osd_on = 1; set_res(0, 1, 1078, 1262); frames(1);
    check(dut.u_subtitle.enable === 1'b1 && dut.u_waveform.enable === 1'b0, "subtitle on, wave off: only subtitle");
    set_res(1, 1, 1078, 1262); alert = 1; frames(1);
    check(dut.u_waveform.enable === 1'b0, "emergency: waveform hidden");
    alert = 0; thumb_on = 1; frames(1);
    check(dut.u_waveform.enable === 1'b0, "thumbnail: waveform hidden");
    thumb_on = 0; wave_on = 0; frames(1);
    check(dut.u_waveform.enable === 1'b0, "top-level wave_on (thumbnail) low: hidden");

    $display("RESULT fails=%0d %s", fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
endmodule
