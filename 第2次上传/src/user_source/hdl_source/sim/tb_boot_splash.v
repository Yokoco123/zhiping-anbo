`timescale 1ns/1ps
// boot_splash（开机自检页）仿真：640×480@60 时序，时间参数缩短（帧数），各种启动情况各抓一帧存成 BMP（sim/splash_out/）
// 另外检查：标题逐像素等于 ROM、前一项没结果不出下一项、结束时机、插卡后“没插卡”提示自动消失、
//           致命问题持续后切到内置安全页、拔卡提示框（应急时不显示）、换卡后自检从头来
module tb_splash;
reg clk = 0, rst_n = 0; always #20 clk = ~clk;          // 25MHz
reg [9:0] h = 0, v = 0;
always @(posedge clk) begin
    h <= (h == 799) ? 0 : h + 1;
    if (h == 799) v <= (v == 524) ? 0 : v + 1;
end
wire de = (h < 640) && (v < 480);
wire vs = !((v >= 490) && (v < 492));
wire [23:0] rgb_in = {h[7:0], v[7:0], 8'h80};          // 自检完成后应该原样透过

// boot_info = {miss, init, scan, n[3], ld[3], pr[3], mus, ef, eok, efail, ps[4]}
reg valid = 0, miss = 0, alert = 0, init = 0, scan = 0, mus = 0, ef = 0, eok = 0, efail = 0;
reg [2:0] n = 0, ld = 0, pr = 0; reg [3:0] ps = 0, err = 0;
reg [1:0] fnt = 0;                                      // 【串口指令】字库：0 检查中 1 已安装 2 未安装
reg rej = 0;                                            // 【串口通知】拒绝了一条指令（单拍）
wire [23:0] rgb_out; wire splash_on, boot_done;
boot_splash #(.FIRST_FRAMES(2), .STEP_FRAMES(2), .HOLD_FRAMES(3), .MAX_FRAMES(40), .NOCARD_FRAMES(4), .SAFE_FRAMES(20), .BACK_FRAMES(4), .REJ_FRAMES(4)) dut (
    .clk(clk), .rst_n(rst_n), .vs(vs), .de(de), .rgb_in(rgb_in),
    .display_valid(valid), .boot_info({fnt, miss, init, scan, n, ld, pr, mus, ef, eok, efail, ps}), .err_code(err), .alert(alert), .reject(rej),
    .rgb_out(rgb_out), .splash_on(splash_on), .boot_done(boot_done));

`ifdef EQUIV
// 【省资源】改之前的版本（boot_splash_old）同时跑，逐像素比对
wire [23:0] old_rgb; wire old_on, old_done;
boot_splash_old #(.FIRST_FRAMES(2), .STEP_FRAMES(2), .HOLD_FRAMES(3), .MAX_FRAMES(40), .NOCARD_FRAMES(4), .SAFE_FRAMES(20), .BACK_FRAMES(4)) u_old (
    .clk(clk), .rst_n(rst_n), .vs(vs), .de(de), .rgb_in(rgb_in),
    .display_valid(valid), .boot_info({fnt, miss, init, scan, n, ld, pr, mus, ef, eok, efail, ps}), .err_code(err), .alert(alert),
    .rgb_out(old_rgb), .splash_on(old_on), .boot_done(old_done));
integer px_cmp = 0, px_bad = 0;
always @(posedge clk) begin
    if (de) begin
        px_cmp = px_cmp + 1;
        if (rgb_out !== old_rgb) begin
            if (px_bad < 10) $display("  PIXEL DIFF t=%0t x=%0d y=%0d page=%0d new=%h old=%h", $time, h, v, dut.page, rgb_out, old_rgb);
            px_bad = px_bad + 1;
        end
    end
    if ((splash_on !== old_on) || (boot_done !== old_done)) begin
        if (px_bad < 10) $display("  FLAG DIFF t=%0t", $time);
        px_bad = px_bad + 1;
    end
end
`endif

// 查表用的另一份 ROM（同一个文件）
reg [6:0] ref_sid = 0; wire [13:0] ref_start; wire [9:0] ref_len, ref_x0;
splash_rom ref_rom (.clk(clk), .raddr(14'd0), .rdata(), .sid(ref_sid), .s_start(ref_start), .s_len(ref_len), .s_x0(ref_x0), .w_lost(), .w_back(), .w_rej());

// 一帧图像缓存，按 de 顺序收
reg [23:0] fb [0:640*480-1];
integer idx = 0;
always @(posedge clk) begin
    if (v == 480 && h == 0) idx = 0;
    if (de) begin fb[idx] = rgb_out; idx = idx + 1; end
end
integer fails = 0;
task wait_frames; input integer nf; integer kk; begin
    for (kk = 0; kk < nf; kk = kk + 1) begin @(posedge clk); wait (v == 481); wait (v == 482); end
end endtask
task dump; input [8*40-1:0] name; integer f, x, y; reg [23:0] p; begin
    wait (v == 0 && h == 1); wait (v == 481);           // 收满整帧
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
    $display("dumped %0s  reveal=%0d st=%h msg=%0d splash_on=%b boot_done=%b", name, dut.reveal, dut.st_q, dut.msg_q,
             splash_on, boot_done);
end endtask
task expect; input c; input [8*60-1:0] msg; begin
    if (c) $display("  ok   %0s", msg); else begin $display("  FAIL %0s", msg); fails = fails + 1; end
end endtask
// 逐像素核对：标题 48 行（含左右各 2 列），每个点是不是正好等于 ROM 里那一位（查地址错列）
task check_title; integer b, r, c, bad, cnt, L, S, X; reg ex; reg [23:0] p; begin
    bad = 0; cnt = 0;
    for (b = 0; b < 3; b = b + 1) begin
        ref_sid = b; #1; L = ref_len; S = ref_start; X = ref_x0;
        for (r = 0; r < 16; r = r + 1)
            for (c = -2; c < L + 2; c = c + 1) begin
                ex = (c >= 0 && c < L) ? ref_rom.mem[S + c][r] : 1'b0;
                p = fb[(56 + b * 16 + r) * 640 + X + c];
                if ((p == 24'hFFFFFF) !== ex) bad = bad + 1;
                cnt = cnt + 1;
            end
    end
    expect(bad == 0, "title pixel-exact vs ROM");
    $display("       (%0d pixels, %0d wrong)", cnt, bad);
end endtask
task reset_dut; begin
    rst_n = 0; repeat (5) @(posedge clk); rst_n = 1;
end endtask

initial begin
    repeat (10) @(posedge clk); rst_n = 1;

    $display("== 1 normal boot");
    wait_frames(1);                                           dump("splash_out/a_title.bmp");
    check_title;
    expect(dut.reveal == 0, "nothing revealed before FIRST_FRAMES");
    // 卡初始化好、扫描完、4 张图、有音乐和应急页；参数存储还在读（ps=0）
    init = 1; scan = 1; n = 4; mus = 1; ef = 1;
    wait_frames(8);
    expect(dut.reveal == 2, "stops after 'settings' while it is still pending");
    ps = 1;                                                    // 参数读到了
    ld = 1; pr = 1; valid = 1;                                 // 第一张图载好
    wait_frames(8);                                            dump("splash_out/b_loading.bmp");
    expect(dut.reveal == 5 && !boot_done, "EMERG row waits until pictures have a result");
    expect(splash_on, "splash still on while pictures load");
    ld = 4; pr = 4; eok = 1;
    wait_frames(8);
    expect(dut.reveal == 7 && !boot_done && dut.msg_q == 33, "font row waits while the font is being checked");
    fnt = 1;
    wait_frames(2);                                            dump("splash_out/c_done.bmp");
    expect(dut.msg_q == 35, "bottom says self-check complete");
    wait_frames(4);
    expect(boot_done && !splash_on, "boot_done after HOLD_FRAMES");
    dump("splash_out/d_passthrough.bmp");
    expect(fb[100 * 640 + 300] == {8'd44, 8'd100, 8'h80}, "image passes through after boot_done");

    $display("== 2 no card, then insert");
    init = 0; scan = 0; n = 0; ld = 0; pr = 0; mus = 0; ef = 0; eok = 0; valid = 0; ps = 0;
    reset_dut; ps = 2;
    wait_frames(10);                                           dump("splash_out/e_nocard.bmp");
    expect(dut.msg_q == 37 && dut.msg_kind == 2, "bottom: no TF card, inserts automatically");
    expect(dut.reveal == 3, "card row shown and waiting (spinner)");
    init = 1;                                                  // 插卡：初始化完成
    wait_frames(2);
    expect(dut.msg_q == 33, "no-card message cleared by itself after insert");
    scan = 1; n = 2; mus = 0; ef = 0;                          // 2 张图，没有音乐和应急页
    wait_frames(3);
    ld = 1; pr = 2; valid = 1;                                 // 一张载好，一张失败
    fnt = 2;                                                   // 字库没装：黄色，不挡开机
    wait (dut.reveal == 7); wait_frames(1);                    dump("splash_out/f_partial.bmp");
    expect(dut.reveal == 7, "warnings do not block the list (font missing = warning)");
    fnt = 1;
    wait_frames(4);
    expect(boot_done, "boot continues with warnings");

    $display("== 3 no pictures on the card");
    init = 0; scan = 0; n = 0; ld = 0; pr = 0; valid = 0; ps = 0;
    reset_dut; ps = 1; init = 1; scan = 1; n = 0; err = 4; mus = 1;
    wait_frames(10);                                           dump("splash_out/g_err_fs.bmp");
    expect(dut.msg_q == 39 && dut.reveal == 3, "card row red, stops, bottom explains FS error");
    expect(!boot_done, "stays on the splash");

    $display("== 4 pictures found but none loads (bad format)");
    reset_dut; ps = 1; init = 1; scan = 1; n = 3; ld = 0; pr = 3; err = 1; mus = 1; ef = 1; efail = 1;
    wait_frames(12);                                           dump("splash_out/h_err_fmt.bmp");
    expect(dut.msg_q == 41 && dut.reveal == 5, "picture row red, bottom says unsupported format");

    $display("== 5 EMERG.BMP still loading at MAX_FRAMES");
    reset_dut; ps = 1; init = 1; scan = 1; n = 4; ld = 4; pr = 4; err = 0; mus = 1; ef = 1; efail = 0; eok = 0; valid = 1;
    wait_frames(25);
    expect(!boot_done, "waits for EMERG while under MAX_FRAMES");
    wait_frames(20);
    expect(boot_done, "MAX_FRAMES lets the picture through anyway");

    $display("== 6 no card for a long time -> built-in safety page, insert card -> back to self-check");
    valid = 0; init = 0; scan = 0; n = 0; ld = 0; pr = 0; eok = 0; ef = 0; mus = 0;
    reset_dut; ps = 1;
    wait (dut.page == 2); wait_frames(1);                    dump("splash_out/i_safe.bmp");
    expect(splash_on && !boot_done, "safety page is part of the splash");
    expect(dut.msg_q == 37, "safety page bottom still says no TF card");
    init = 1;
    wait_frames(2);
    expect(dut.page == 1, "card inserted: back to the self-check page");
    expect(dut.fcnt <= 12, "12 s cap restarts when the card goes in");
    scan = 1; n = 4; ld = 4; pr = 4; mus = 1; ef = 1; eok = 1; valid = 1;
    wait (boot_done);
    expect(dut.reveal == 7, "self-check completed after late insert");

    $display("== 7 card pulled while playing -> badge, emergency hides it, re-insert -> green, then gone");
    wait_frames(2);
    miss = 1;
    wait_frames(2);                                            dump("splash_out/j_badge_lost.bmp");
    expect(dut.page == 3 && dut.b_lost && boot_done, "yellow badge while the card is out, picture still on");
    expect(fb[300 * 640 + 100] == {8'd100, 8'd44, 8'h80}, "outside the badge the picture passes through");
    expect(fb[60 * 640 + 300] == {8'd44, 8'd60, 8'h80}, "left of the badge passes through");
    alert = 1;
    wait_frames(2);
    expect(dut.page == 0, "emergency mode: no badge");
    alert = 0; miss = 0;
    wait_frames(2);                                            dump("splash_out/k_badge_back.bmp");
    expect(dut.page == 3 && !dut.b_lost, "green badge after re-insert");
    wait_frames(6);
    expect(dut.page == 0, "green badge disappears");

    $display("== 8 a different card: programme cleared -> self-check starts again");
    valid = 0; ld = 0; pr = 0; eok = 0;
    wait_frames(2);
    expect(!boot_done && dut.page == 1 && dut.reveal <= 1, "self-check restarted");
    ld = 4; pr = 4; eok = 1; valid = 1;
    wait (boot_done);
    expect(dut.reveal == 7, "self-check ran through again");

`ifndef EQUIV
    $display("== 9 UART notice rejected -> red badge 3 s (over the card badge), hidden in emergency");
    wait_frames(2);
    @(negedge clk) rej = 1; @(negedge clk) rej = 0;
    wait_frames(2);                                            dump("splash_out/l_badge_reject.bmp");
    expect(dut.page == 3 && dut.b_rej && boot_done, "red reject badge shown");
    expect(fb[300 * 640 + 100] == {8'd100, 8'd44, 8'h80}, "picture passes through outside the badge");
    miss = 1;
    wait_frames(2);
    expect(dut.b_rej, "reject badge has priority over card-removed");
    wait_frames(4);
    expect(dut.page == 3 && dut.b_lost, "after 3 s: back to the card-removed badge");
    miss = 0; wait_frames(8);
    expect(dut.page == 0, "all badges gone");
    alert = 1;
    @(negedge clk) rej = 1; @(negedge clk) rej = 0;
    wait_frames(2);
    expect(dut.page == 0, "emergency mode: no reject badge");
    alert = 0;
`endif
`ifdef EQUIV
    $display("EQUIV %0d pixels compared, %0d different", px_cmp, px_bad);
    if (px_bad != 0) fails = fails + 1;
`endif
    $display("RESULT fails=%0d %s", fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
endmodule
