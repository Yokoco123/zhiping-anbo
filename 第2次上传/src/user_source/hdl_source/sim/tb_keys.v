`timescale 1ns/1ps
// 【省资源】按键回归：同一串按键（带抖动的短按 / 长按 / 小于 50ms 的毛刺 / 菜单里按住连发）
// 分别喂给改之前和改之后的 sd_card_bmp4，把每个按键事件发生的时刻（毫秒）写进文件，两份对比。
// CLK_FREQ_HZ = 100kHz：1ms = 100 拍。卡不接（SD_MISO=1），只看按键。
// 用法见 run_keys.sh
module tb_keys;
localparam integer FHZ = 100_000;
localparam integer MS  = FHZ / 1000;
defparam dut.u_param_store.CLK_FREQ_HZ = 100_000_000;   // Flash 不接，只是别让它的 us 计数变 0（它自检会 $finish）
reg clk = 0, rst = 1; always #5 clk = ~clk;
reg k_next = 1, k_auto = 1, k_prev = 1, k_plus = 1;
reg [3:0] sw = 4'b0000;

sd_card_bmp4 #(.CLK_FREQ_HZ(FHZ)) dut (
    .clk(clk), .rst(rst), .key_next(k_next), .key_auto(k_auto), .key_prev(k_prev), .key_plus(k_plus), .sw(sw),
    .sw_on(), .bri_pct(), .con_pct(), .vol_pct(), .music_pause(), .period_idx(), .menu_sel(), .tone_allow(),
    .write_emerg(), .emerg_ok(), .bmp_width(16'd640), .bmp_height(16'd480), .display_valid(),
    .state_code(), .img_num(), .err_code(), .auto_on(), .thumb_mode(), .loaded_mask(), .switch_auto(),
    .trans_busy(1'b0), .music_byte_valid(), .music_byte(), .music_off(), .music_hold(1'b0),
    .write_finish_toggle(1'b0), .write_buf_idx(), .disp_buf_idx(), .write_req(),
    .write_req_ack(1'b0), .write_en(), .write_data(),
    .SD_nCS(), .SD_DCLK(), .SD_MOSI(), .SD_MISO(1'b1),
    .FLASH_CS_N(), .FLASH_SCLK(), .FLASH_MOSI(), .FLASH_WP_N(), .FLASH_HOLD_N(), .FLASH_MISO(1'b1),
    .param_store_status(), .boot_info()
`ifndef OLDDUT
  , .ext_alarm_n(1'b1), .uart_rx(1'b1), .uart_tx(), .vclk(clk), .vrst_n(!rst), .ntc_col(10'd0), .ntc_bits(), .ntc_on(), .ntc_len(), .ntc_new(),
    .ntc_reject(), .ntc_sub_off());
`else
    );
`endif

integer fd, t0;
initial fd = $fopen(`OUTFILE, "w");
// 事件：名字 + 毫秒（从复位释放算起）
always @(posedge clk) if (!rst) begin
    if (dut.key_next_short)    $fdisplay(fd, "next_short %0d", ($time / 10 - t0) / MS);
    if (dut.key_next_long)     $fdisplay(fd, "next_long  %0d", ($time / 10 - t0) / MS);
    if (dut.key_prev_short)    $fdisplay(fd, "prev_short %0d", ($time / 10 - t0) / MS);
    if (dut.key_auto_short)    $fdisplay(fd, "auto_short %0d", ($time / 10 - t0) / MS);
    if (dut.key_auto_long)     $fdisplay(fd, "auto_long  %0d", ($time / 10 - t0) / MS);
    if (dut.key_auto_press)    $fdisplay(fd, "auto_press %0d", ($time / 10 - t0) / MS);
    if (dut.key_plus_press)    $fdisplay(fd, "plus_press %0d", ($time / 10 - t0) / MS);
    if (dut.u_param_adjust.p_fine)   $fdisplay(fd, "p_fine     %0d", ($time / 10 - t0) / MS);
    if (dut.u_param_adjust.p_coarse) $fdisplay(fd, "p_coarse   %0d", ($time / 10 - t0) / MS);
    if (dut.u_param_adjust.m_fine)   $fdisplay(fd, "m_fine     %0d", ($time / 10 - t0) / MS);
    if (dut.u_param_adjust.m_coarse) $fdisplay(fd, "m_coarse   %0d", ($time / 10 - t0) / MS);
end

task wait_ms; input integer n; begin repeat (n * MS) @(negedge clk); end endtask
// 按下 / 松开时各抖 8ms（每 1ms 翻一次）
task bounce_to; input integer which; input v; integer i; begin
    for (i = 0; i < 8; i = i + 1) begin set_key(which, i[0] ? v : ~v); wait_ms(1); end
    set_key(which, v);
end endtask
task set_key; input integer which; input v; begin
    case (which) 0: k_next = v; 1: k_auto = v; 2: k_prev = v; default: k_plus = v; endcase
end endtask
task press; input integer which; input integer hold_ms; begin
    bounce_to(which, 1'b0); wait_ms(hold_ms); bounce_to(which, 1'b1); wait_ms(300);
end endtask
task glitch; input integer which; input integer len_ms; begin
    set_key(which, 1'b0); wait_ms(len_ms); set_key(which, 1'b1); wait_ms(200);
end endtask

integer w;
initial begin
    repeat (20) @(negedge clk); rst = 0; t0 = $time / 10;
    wait_ms(100);
    for (w = 0; w < 4; w = w + 1) begin
        glitch(w, 30);                     // 30ms 毛刺：不该有任何事件
        glitch(w, 45);                     // 门限 50ms，节拍量化有 1ms，45ms 必须被滤掉
        press(w, 200);                     // 短按
        press(w, 980);                     // 接近 1 秒还是短按
        press(w, 1500);                    // 长按
    end
    // 菜单里 KEY3 / Key4 按住连发
    sw = 4'b0010; wait_ms(50);
    press(3, 1700);
    press(1, 1250);
    press(3, 100);
    sw = 4'b0000; wait_ms(50);
    $fclose(fd);
    $display("KEYS_DONE");
    $finish;
end
endmodule
