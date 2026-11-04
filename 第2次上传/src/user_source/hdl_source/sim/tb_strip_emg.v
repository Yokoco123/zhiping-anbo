`timescale 1ns/1ps
// 【应急改版】subtitle_strip：
//   1 serial_cmd 现在保证“应急接管且没有应急文字时 notice = 0”，在这个前提下（tb 里 notice 接 notice && !alert），
//     新版和改之前（bak_emg/subtitle_strip.v，改名 subtitle_strip_prev）逐像素相同：槽、enable、应急、通知、自定义字幕全部组合
//   2 应急接管 + notice（= 串口应急文字）：字从 RAM 来，一级红底白字、二级橙底白字；文字变了（notice_new）从右端重新进入
//   用法：sed 's/^module subtitle_strip #(/module subtitle_strip_prev #(/' bak_emg/subtitle_strip.v > strip_prev_tmp.v
//         iverilog -g2005 -o se.out -s tb_strip_emg tb_strip_emg.v ../subtitle_strip.v strip_prev_tmp.v ../subtitle_rom.v && vvp -n se.out
module tb_strip_emg;
reg clk = 0, rst_n = 0; always #20 clk = ~clk;
reg [9:0] h = 0, v = 0;
always @(posedge clk) begin h <= (h == 799) ? 0 : h + 1; if (h == 799) v <= (v == 524) ? 0 : v + 1; end
wire de = (h < 640) && (v < 480);
wire vs = !((v >= 490) && (v < 492));
wire [9:0] px = de ? h : 10'd0;
wire [23:0] rgb_in = {h[7:0], v[7:0], 8'h40};
reg enable = 1, alert = 0, l2 = 0, notice = 0, nnew = 0, cs = 0, gate = 1; reg [2:0] slot = 0; reg [10:0] nlen = 11'd300;
wire [9:0] ncol, ncol_p; reg [15:0] nbits, nbits_p;
always @(posedge clk) begin nbits <= {6'd0, ncol} ^ 16'h0F0F; nbits_p <= {6'd0, ncol_p} ^ 16'h0F0F; end
wire [23:0] o_new, o_prev;
wire n_dut = gate ? (notice && !alert) : notice;
subtitle_strip dut (.clk(clk), .rst_n(rst_n), .vs(vs), .de(de), .pixel_x(px), .rgb_in(rgb_in), .enable(enable), .slot(slot),
    .alert(alert), .alert_l2(l2), .notice(n_dut), .notice_len(nlen), .notice_new(nnew), .notice_col(ncol), .notice_bits(nbits),
    .custom(cs), .rgb_out(o_new));
subtitle_strip_prev ref0 (.clk(clk), .rst_n(rst_n), .vs(vs), .de(de), .pixel_x(px), .rgb_in(rgb_in), .enable(enable), .slot(slot),
    .alert(alert), .notice(notice), .notice_len(nlen), .notice_new(nnew), .notice_col(ncol_p), .notice_bits(nbits_p),
    .custom(cs), .rgb_out(o_prev));
integer fails = 0, diff = 0, cmp_on = 1;
always @(posedge clk) if (de && cmp_on && (o_new !== o_prev)) diff = diff + 1;
task frames; input integer n; integer k; begin for (k = 0; k < n; k = k + 1) begin wait (v == 481); wait (v == 482); end end endtask
task expect; input c; input [8*72-1:0] msg; begin
    if (c) $display("  ok   %0s", msg); else begin $display("  FAIL %0s", msg); fails = fails + 1; end
end endtask
task pulse_new; begin @(negedge clk) nnew = 1; @(negedge clk) nnew = 0; end endtask
integer n_red, n_org, n_white, n_ink, n_yel;
always @(posedge clk) begin
    if (v == 480 && h == 0) begin n_red = 0; n_org = 0; n_white = 0; n_ink = 0; n_yel = 0; end
    if (de && v >= 448 && v < 468 && h >= 8 && h < 632) begin
        if (o_new == 24'hc00000) n_red = n_red + 1;
        if (o_new == 24'hd86000) n_org = n_org + 1;
        if (o_new == 24'hffffff) n_white = n_white + 1;
        if (o_new == 24'h000000) n_ink = n_ink + 1;
        if (o_new == 24'hffd23c) n_yel = n_yel + 1;
    end
end
task count_frame; begin wait (v == 0); wait (v == 479); wait (v == 480); end endtask
integer i, seed = 3, r;
initial begin
    repeat (5) @(posedge clk); rst_n = 1;
    $display("== 1 same as before when notice is gated off during alerts (random 300 steps)");
    for (i = 0; i < 300; i = i + 1) begin
        r = $unsigned($random(seed)) % 9;
        case (r)
            0: enable = ~enable;  1: alert = ~alert;  2: notice = ~notice;  3: cs = ~cs;
            4: slot = $unsigned($random(seed)) % 6;  5: pulse_new;  6: nlen = $unsigned($random(seed)) % 1100;
            default: ;
        endcase
        frames(1 + $unsigned($random(seed)) % 6);
    end
    expect(diff == 0, "pixel-identical to the previous strip");
    $display("       (%0d differing pixels)", diff);
    cmp_on = 0;

    $display("== 2 alert + emergency text");
    gate = 0; enable = 1; cs = 0; slot = 0; nlen = 11'd300; alert = 1; l2 = 0; notice = 1; pulse_new; frames(400); count_frame;
    expect(dut.ntc_q && n_red > 0 && n_white > 0 && n_yel == 0, "level 1: red band, white text from the RAM");
    l2 = 1; frames(2); count_frame;
    expect(n_org > 0 && n_red == 0 && n_white > 0, "level 2: orange band");
    pulse_new; frames(2);
    expect(dut.pos <= 2, "new emergency text: restarts from the right");
    notice = 0; slot = 3'd4; frames(2);          // osd_layer 在应急时把槽设成 4
    expect(!dut.ntc_q && dut.cur_slot == 3'd4 && dut.pos <= 2, "no text: fixed emergency slot 4, restarts");
    alert = 0; l2 = 0; notice = 1; frames(400); count_frame;
    expect(n_yel > 0 && n_ink > 0 && n_red == 0, "level 3 / normal notice: yellow band, black text");
    $display("RESULT fails=%0d %s", fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
endmodule
