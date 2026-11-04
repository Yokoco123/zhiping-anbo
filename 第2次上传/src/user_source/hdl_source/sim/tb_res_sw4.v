`timescale 1ns/1ps
// 【分辨率显示】SW4 控制 res_on：上电跟着开关位置；拨动立即跟随；串口指令也能改（以最后一次为准）；SW_INVERT 照常起作用
module tb_res_sw4;
reg clk = 0, rst = 1; always #5 clk = ~clk;
reg [3:0] sw = 4'b1000;
sd_card_bmp4 #(.CLK_FREQ_HZ(1_000_000)) dut (
    .clk(clk), .rst(rst), .key_next(1'b1), .key_auto(1'b1), .key_prev(1'b1), .key_plus(1'b1), .sw(sw),
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
    .uart_rx(1'b1), .uart_tx(), .vclk(clk), .vrst_n(!rst), .ntc_col(10'd0), .ntc_bits(), .ntc_on(), .ntc_len(), .ntc_new(),
    .ntc_reject(), .ntc_sub_off(), .v_shown(4'd1), .ntc_cs(), .v_res(),
    .alm_col(10'd0), .alm_lvl(), .alm_len(), .alm_mute(),
    .want_page(), .want_pbuf(), .page_info(), .pv_sel(1'b0), .pv_buf(1'b0), .pv_col(11'd0), .pv_meta());
integer fails = 0;
task check; input c; input [8*60-1:0] msg; begin
    if (c) $display("  ok   %0s", msg); else begin $display("  FAIL %0s", msg); fails = fails + 1; end
end endtask
task ser; input on; begin
    force dut.sc_res_set = on; force dut.sc_res_clr = !on; @(posedge clk); #1; release dut.sc_res_set; release dut.sc_res_clr;
    force dut.sc_res_set = 1'b0; force dut.sc_res_clr = 1'b0; repeat (3) @(posedge clk); release dut.sc_res_set; release dut.sc_res_clr;
end endtask
initial begin
    force dut.sc_res_set = 1'b0; force dut.sc_res_clr = 1'b0;
    repeat (5) @(posedge clk); rst = 0; repeat (10) @(posedge clk);
    check(dut.res_on, "power-up with SW4 on: shown");
    release dut.sc_res_set; release dut.sc_res_clr;
    ser(0); check(!dut.res_on, "serial off while SW4 on: hidden (last action wins)");
    sw[3] = 0; repeat (5) @(posedge clk); check(!dut.res_on, "SW4 off: hidden");
    sw[3] = 1; repeat (5) @(posedge clk); check(dut.res_on, "SW4 on: shown");
    sw[3] = 0; repeat (5) @(posedge clk); ser(1); check(dut.res_on, "serial on while SW4 off: shown");
    sw[1] = 1; repeat (5) @(posedge clk); check(dut.res_on, "SW2 (menu) does not touch it");
    rst = 1; repeat (3) @(posedge clk); rst = 0; repeat (10) @(posedge clk);
    check(!dut.res_on, "reset with SW4 off: hidden");
    $display("RESULT fails=%0d %s", fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
endmodule
