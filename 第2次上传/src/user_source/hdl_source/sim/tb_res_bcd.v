`timescale 1ns/1ps
// 【分辨率显示】sd_card_bmp4：载图成功时记下宽高 → video_clk 域 → 十进制，v_res 跟着正在显示的图变
//   载图过程用 force 模拟（loaded 某位变 1 时 src_dims 是这张图的宽高），两个时钟不同频不同相
//   随机 200 组宽高（1~4096），每组 4 张图都核对；还核对：波形 / 分辨率位、启事页、未出图
//   用法见 README（文件列表同 tb_keyfunc）
module tb_res_bcd;
reg clk = 0, vclk = 0, rst = 1;
always #6.667 clk = ~clk;          // 75 MHz
always #20.1  vclk = ~vclk;        // 约 25 MHz，和 clk 不同步
wire [33:0] v_res;
reg  [3:0]  shown = 4'd0;
reg         pv = 1'b0;
sd_card_bmp4 #(.CLK_FREQ_HZ(1_000_000)) dut (
    .clk(clk), .rst(rst), .key_next(1'b1), .key_auto(1'b1), .key_prev(1'b1), .key_plus(1'b1), .sw(4'd0),
    .sw_on(), .ext_alarm_n(1'b1), .mute_on(),
    .bri_pct(), .con_pct(), .vol_pct(), .music_pause(), .period_idx(), .menu_sel(), .tone_allow(),
    .write_emerg(), .emerg_ok(), .bmp_width(16'd640), .bmp_height(16'd480), .display_valid(),
    .state_code(), .img_num(), .err_code(), .auto_on(), .thumb_mode(), .loaded_mask(), .switch_auto(),
    .trans_busy(1'b0), .music_byte_valid(), .music_byte(), .music_off(), .music_hold(1'b0),
    .write_finish_toggle(1'b0), .write_buf_idx(), .disp_buf_idx(), .write_req(),
    .write_req_ack(1'b0), .write_en(), .write_data(),
    .SD_nCS(), .SD_DCLK(), .SD_MOSI(), .SD_MISO(1'b1),
    .FLASH_CS_N(), .FLASH_SCLK(), .FLASH_MOSI(), .FLASH_WP_N(), .FLASH_HOLD_N(), .FLASH_MISO(1'b1),
    .param_store_status(), .boot_info(),
    .uart_rx(1'b1), .uart_tx(), .vclk(vclk), .vrst_n(!rst), .ntc_col(10'd0), .ntc_bits(), .ntc_on(), .ntc_len(), .ntc_new(),
    .ntc_reject(), .ntc_sub_off(), .v_shown(shown), .ntc_cs(), .v_res(v_res),
    .alm_col(10'd0), .alm_lvl(), .alm_len(), .alm_mute(),
    .want_page(), .want_pbuf(), .page_info(), .pv_sel(pv), .pv_buf(1'b0), .pv_col(11'd0), .pv_meta());

integer fails = 0, nchk = 0;
task check; input c; input [8*80-1:0] msg; begin
    nchk = nchk + 1;
    if (!c) begin $display("  FAIL %0s  (t=%0t)", msg, $time); fails = fails + 1; end
end endtask
function [15:0] bcd; input integer v; reg [3:0] a, b, c, d; begin
    a = v / 1000 % 10; b = v / 100 % 10; c = v / 10 % 10; d = v % 10; bcd = {a, b, c, d};
end endfunction

reg [3:0]  ld = 4'd0;
reg [25:0] sd = 26'd0;
integer W [0:3], H [0:3];
integer i, k, seed = 7;
// 模拟一张图载好：先把宽高放到 src_dims，下一拍 loaded 那一位变 1，再过几拍宽高变成别的（像接着读下一个文件）
task load; input integer b; input integer w; input integer h; begin
    @(negedge clk); sd = {h[12:0], w[12:0]};
    @(negedge clk); ld[b] = 1'b1;
    repeat (3) @(negedge clk); sd = 26'h3FFFFFF;
end endtask
task look; input integer b; input [8*30-1:0] msg; begin
    shown = b + 1;
    repeat (80) @(posedge vclk);                     // 同步 + 一轮十进制转换
    check(v_res[31:16] == bcd(W[b]) && v_res[15:0] == bcd(H[b]), msg);
    if (v_res[31:16] != bcd(W[b]) || v_res[15:0] != bcd(H[b]))
        $display("    bank %0d: got %h x %h, exp %0d x %0d", b, v_res[31:16], v_res[15:0], W[b], H[b]);
end endtask

initial begin
    force dut.src_dims = sd;
    force dut.loaded = ld;
    repeat (5) @(negedge clk); rst = 0;
    repeat (20) @(negedge clk);
    // 固定的几组
    W[0] = 1078; H[0] = 1262; W[1] = 1080; H[1] = 615; W[2] = 1; H[2] = 1; W[3] = 4096; H[3] = 4096;
    for (k = 0; k < 4; k = k + 1) load(k, W[k], H[k]);
    for (k = 0; k < 4; k = k + 1) look(k, "fixed sizes");
    // 换卡：全部清掉再随机重载 200 轮
    for (i = 0; i < 200; i = i + 1) begin
        ld = 4'd0; repeat (5) @(negedge clk);
        for (k = 0; k < 4; k = k + 1) begin
            W[k] = 1 + ($unsigned($random(seed)) % 4096); H[k] = 1 + ($unsigned($random(seed)) % 4096);
            load(k, W[k], H[k]);
        end
        look($unsigned($random(seed)) % 4, "random sizes");
    end
    for (k = 0; k < 4; k = k + 1) look(k, "last round, every bank");
    // 开关位
    force dut.res_on = 1'b1; force dut.wave_st = 1'b1; shown = 4'd2; repeat (10) @(posedge vclk);
    check(v_res[33] && v_res[32], "wave on, res on, picture shown");
    pv = 1; repeat (2) @(posedge vclk);
    check(!v_res[33] && !v_res[32], "notice page: both off");
    pv = 0; shown = 4'd0; repeat (2) @(posedge vclk);
    check(v_res[33] && !v_res[32], "no picture yet: res off, wave flag still on");
    shown = 4'd1; force dut.res_on = 1'b0; force dut.wave_st = 1'b0; repeat (10) @(posedge vclk);
    check(!v_res[33] && !v_res[32], "both switches off");
    $display("RESULT checks=%0d fails=%0d %s", nchk, fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
endmodule
