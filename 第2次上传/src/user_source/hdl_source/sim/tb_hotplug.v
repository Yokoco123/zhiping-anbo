`timescale 1ns/1ps
// 【拔卡恢复】系统级仿真：sd_card_bmp4（含 fat32_bmp_read / 扫描器 / 流读器 / 缩放器）+ 行为级 TF 卡模型
//   卡模型替换 sd_card_top（同名模块，本文件末尾），卡里是程序生成的 FAT32 小镜像：
//     PIC1~4.BMP（8×8，24 位）、EMERG.BMP、MUSIC.WAV（2 簇）
//   拔卡：正在读的扇区不再回数据；插回后不复位就一直不回（和真卡一样：重新上电的卡要重新初始化）
//   时间缩短：CLK_FREQ_HZ = 200kHz，“1 秒” = 20 万拍；缩放输出 64×48
// 场景：
//   1 上电：5 张图载完，开始读音乐
//   2 读音乐时拔卡 → card_missing、显示不变 → 插回同一张卡 → 不重载，音乐从头读
//   3 音乐暂停（hold）时拔卡 → 巡检发现 → 插回同一张卡
//   4 换一张卡（PIC2 修改时间不同）→ 重新载入全部图片
//   5 载图过程中拔卡 → 这张不算失败，插回后接着载完
module tb_hp;
localparam integer FHZ = 200_000;
localparam integer OW = 64, OH = 48;        // 仿真里缩放输出改小（defparam），否则一张图 30 万像素比读卡超时还慢
defparam dut.bmp_read_m0.u_scaler.OUT_W = OW;
defparam dut.bmp_read_m0.u_scaler.OUT_H = OH;
defparam dut.u_param_store.CLK_FREQ_HZ = 100_000_000;   // Flash 不接（MISO=1），只是别让它的 us 计数变 0
reg clk = 0, rst = 1; always #5 clk = ~clk;

// ---------------- 卡（两张镜像，card_id 选哪张） ----------------
reg        card_present = 1;
reg        card_id = 0;
reg [7:0]  img [0:1][0:64*512-1];

task put32; input k; input integer a; input [31:0] v; begin
    img[k][a] = v[7:0]; img[k][a+1] = v[15:8]; img[k][a+2] = v[23:16]; img[k][a+3] = v[31:24];
end endtask
task put16; input k; input integer a; input [15:0] v; begin
    img[k][a] = v[7:0]; img[k][a+1] = v[15:8];
end endtask
task dirent; input k; input integer slot; input [87:0] name; input [31:0] clu; input [31:0] size; input [31:0] wtime;
    integer a, i; begin
    a = 3 * 512 + slot * 32;
    for (i = 0; i < 11; i = i + 1) img[k][a + i] = name[87 - i * 8 -: 8];
    img[k][a + 11] = 8'h20;
    put32(k, a + 22, wtime);
    put16(k, a + 20, clu[31:16]); put16(k, a + 26, clu[15:0]);
    put32(k, a + 28, size);
end endtask
task bmp; input k; input integer clu; input [7:0] seed; integer a, i; begin
    a = (3 + clu - 2) * 512;
    img[k][a] = "B"; img[k][a+1] = "M"; put32(k, a + 2, 246); put32(k, a + 10, 54); put32(k, a + 14, 40);
    put32(k, a + 18, 8); put32(k, a + 22, 8); put16(k, a + 26, 1); put16(k, a + 28, 24); put32(k, a + 30, 0);
    put32(k, a + 34, 192);
    for (i = 0; i < 192; i = i + 1) img[k][a + 54 + i] = seed + i;
end endtask
task build; input k; input [31:0] pic2_time; integer i, a; begin
    for (i = 0; i < 64 * 512; i = i + 1) img[k][i] = 8'h00;
    // LBA0 引导扇区（无分区表，直接 BPB）
    img[k][0] = 8'hEB; img[k][1] = 8'h58; img[k][2] = 8'h90;
    put16(k, 11, 512); img[k][13] = 1; put16(k, 14, 2); img[k][16] = 1; put16(k, 17, 0); put16(k, 19, 0);
    img[k][21] = 8'hF8; put16(k, 22, 0); put32(k, 32, 64); put32(k, 36, 1); put32(k, 44, 2);
    img[k][510] = 8'h55; img[k][511] = 8'hAA;
    // FAT（LBA2）：簇 2 根目录，3~7 单簇文件，8→9 音乐
    a = 2 * 512;
    put32(k, a + 0, 32'h0FFFFFF8); put32(k, a + 4, 32'h0FFFFFFF);
    for (i = 2; i <= 7; i = i + 1) put32(k, a + i * 4, 32'h0FFFFFFF);
    put32(k, a + 8 * 4, 9); put32(k, a + 9 * 4, 32'h0FFFFFFF);
    // 根目录（LBA3 = 簇 2）
    dirent(k, 0, "PIC1    BMP", 3, 246, 32'h5A21_6000);
    dirent(k, 1, "PIC2    BMP", 4, 246, pic2_time);
    dirent(k, 2, "PIC3    BMP", 5, 246, 32'h5A21_6002);
    dirent(k, 3, "PIC4    BMP", 6, 246, 32'h5A21_6003);
    dirent(k, 4, "EMERG   BMP", 7, 246, 32'h5A21_6004);
    dirent(k, 5, "MUSIC   WAV", 8, 1024, 32'h5A21_6005);
    for (i = 3; i <= 7; i = i + 1) bmp(k, i, i * 16 + k);
    for (i = 0; i < 1024; i = i + 1) img[k][(3 + 8 - 2) * 512 + i] = i;
end endtask

// ---------------- 写侧（SDRAM 写模块）替身 ----------------
wire write_req, write_en; wire [31:0] write_data;
reg  write_req_ack = 0, write_finish_toggle = 0;
integer wr_cnt = 0;
always @(posedge clk) begin
    write_req_ack <= write_req;
    if (write_req) wr_cnt <= 0;
    else if (write_en) begin
        if (wr_cnt == OW * OH - 1) begin wr_cnt <= 0; write_finish_toggle <= ~write_finish_toggle; end
        else wr_cnt <= wr_cnt + 1;
    end
end

reg  [3:0] sw_r = 4'b0000;                 // 【启事】调度仿真里要打开 SW3
reg music_hold = 0;
wire [21:0] boot_info; wire display_valid, emerg_ok, music_byte_valid; wire [3:0] loaded_mask, err_code;
wire [31:0] music_off;
sd_card_bmp4 #(.CLK_FREQ_HZ(FHZ)) dut (
    .clk(clk), .rst(rst), .key_next(1'b1), .key_auto(1'b1), .key_prev(1'b1), .key_plus(1'b1), .sw(sw_r),
    .sw_on(), .bri_pct(), .con_pct(), .vol_pct(), .music_pause(), .period_idx(), .menu_sel(), .tone_allow(),
    .write_emerg(), .emerg_ok(emerg_ok), .bmp_width(16'd640), .bmp_height(16'd480), .display_valid(display_valid),
    .state_code(), .img_num(), .err_code(err_code), .auto_on(), .thumb_mode(), .loaded_mask(loaded_mask), .switch_auto(),
    .trans_busy(1'b0), .music_byte_valid(music_byte_valid), .music_byte(), .music_off(music_off), .music_hold(music_hold),
    .write_finish_toggle(write_finish_toggle), .write_buf_idx(), .disp_buf_idx(), .write_req(write_req),
    .write_req_ack(write_req_ack), .write_en(write_en), .write_data(write_data),
    .SD_nCS(), .SD_DCLK(), .SD_MOSI(), .SD_MISO(1'b1),
    .FLASH_CS_N(), .FLASH_SCLK(), .FLASH_MOSI(), .FLASH_WP_N(), .FLASH_HOLD_N(), .FLASH_MISO(1'b1),
    .param_store_status(), .boot_info(boot_info),
    .ext_alarm_n(1'b1), .uart_rx(1'b1), .uart_tx(), .vclk(clk), .vrst_n(!rst), .ntc_col(10'd0), .ntc_bits(), .ntc_on(), .ntc_len(), .ntc_new(),
    .ntc_reject(), .ntc_sub_off());

wire card_missing = boot_info[19];
initial force dut.auto_st = 1'b0;              // 【按键改造】按原来的拨码（全关 = 手动）开始跑
// 【启事】调度仿真（-DSCHED）用：事件记录
integer ev_log [0:63]; integer ev_t [0:63]; integer ev_n = 0, ev_cur = -1, x0 = 0, t1; reg per_ok;
localparam integer PER_NS = 3000 * (FHZ / 1000) * 10;       // 轮播周期 3 秒（上电默认）
wire [4:0] ev_now = dut.want_page ? (5'd10 + {3'd0, dut.pg_cur}) : {3'd0, dut.img_idx};
always @(posedge clk) if (!rst && display_valid && ev_now != ev_cur) begin
    ev_cur = ev_now;
    if (ev_n < 64) begin ev_log[ev_n] = ev_now; ev_t[ev_n] = $time; ev_n = ev_n + 1; end
end
function integer ev_pic; input integer k; ev_pic = (x0 + k) % 4; endfunction
task show_log; integer i; begin
    $write("       events:"); for (i = 0; i < ev_n; i = i + 1) $write(" %0d@%0dms", ev_log[i], (ev_t[i] - ev_t[0]) / ((FHZ / 1000) * 10)); $display("");
end endtask
task q_pulse; input [1:0] s; begin
    @(negedge clk); force dut.u_serial_cmd.q_new_slot = s; force dut.u_serial_cmd.q_new = 1'b1;
    @(negedge clk); force dut.u_serial_cmd.q_new = 1'b0;
end endtask
integer fails = 0, loads = 0, music_restarts = 0, probes = 0;
integer prog_fd; initial prog_fd = $fopen("hp_prog.txt", "w");   // 进度单独写一个文件，随时 flush
always @(posedge clk) begin
    if (dut.load_start_pulse) loads = loads + 1;
    if (dut.music_start_pulse) music_restarts = music_restarts + 1;
    if (dut.probe_start || (dut.bmp_read_m0.state == 3'd5 && dut.bmp_read_m0.mprb_cnt >= dut.bmp_read_m0.PROBE_MS)) probes = probes + 1;
end
task expect; input c; input [8*72-1:0] msg; begin
    if (c) $display("  ok   %0s", msg); else begin $display("  FAIL %0s  (t=%0t)", msg, $time); fails = fails + 1; end
    $fdisplay(prog_fd, "%0s %0s", c ? "  ok  " : "  FAIL", msg); $fflush(prog_fd);
end endtask
task wait_cycles; input integer n; begin repeat (n) @(posedge clk); end endtask
task wait_until_music; begin wait (dut.bmp_read_m0.state == 3'd5); end endtask

integer l0, m0, t0;
initial begin
    build(0, 32'h5A21_6001);
    build(1, 32'h5A21_7777);                 // 第二张卡：只有 PIC2 的修改时间不同（同名同大小同位置，像是覆盖了一张图）
    for (l0 = 0; l0 < 192; l0 = l0 + 1) img[1][(3 + 4 - 2) * 512 + 54 + l0] = 8'hEE;
    wait_cycles(10); rst = 0;
`ifdef SCHED
    // 【启事】轮播调度：serial_cmd 的启事状态用 force 模拟（Flash 不接，画启事页时 serial_cmd 立刻回 pg_done）
    //   事件 = 启事页 10 + 第几条（0 起）/ 图 0~3，每次变化记一笔，和期望的顺序比
    wait (loaded_mask == 4'hF && dut.emerg_ld);
    wait_until_music;
    $display("== S1 auto rotation, notices 1 and 3: picture -> 1 -> 3 -> next picture");
    force dut.auto_st = 1'b1;                                // 自动轮播开（【按键改造】原来是 SW3）
    force dut.u_serial_cmd.q_mask = 4'b0101;
    x0 = dut.img_idx; ev_n = 0;
    wait (ev_n >= 7);
    per_ok = 1;
    for (t1 = 1; t1 < 7; t1 = t1 + 1)
        if (ev_t[t1] - ev_t[t1 - 1] < PER_NS - (FHZ / 1000) * 10 || ev_t[t1] - ev_t[t1 - 1] > PER_NS + 5 * (FHZ / 1000) * 10) per_ok = 0;
    expect(ev_log[0] == 10 && ev_log[1] == 12 && ev_log[2] == ev_pic(1) && ev_log[3] == 10 && ev_log[4] == 12 &&
           ev_log[5] == ev_pic(2) && ev_log[6] == 10, "order: pages 1,3 between every picture");
    show_log;
    expect(per_ok, "every page and picture stays one period (3 s, ms tick +-1 ms)");

    $display("== S2 new notice (slot 2) while a picture is shown: inserted at once, then the rest");
    wait (ev_log[ev_n - 1] < 10);                           // 现在放的是图
    wait_cycles(FHZ / 1000 * 500);                          // 图放了 0.5 秒
    force dut.u_serial_cmd.q_mask = 4'b0111;
    ev_n = 0; t0 = $time;
    q_pulse(2'd1);
    wait (ev_n >= 3);
    expect(ev_log[0] == 11 && (ev_t[0] - t0) < 50 * (FHZ / 1000) * 10, "slot 2 shown right away");
    expect(ev_log[1] == 12 && ev_log[2] < 10, "then slot 3 (after 2), then a picture");
    show_log;

    $display("== S3 level-3 emergency while a page is shown: back to the picture, no pages until cleared");
    wait (ev_log[ev_n - 1] >= 10);
    m0 = ev_n;
    force dut.u_serial_cmd.alarm_lvl = 2'd3;   // 串口三级（release 前先放回 0：force 的寄存器 release 后保持原值）
    wait_cycles(10);
    expect(!dut.want_page, "page left at once");
    wait_cycles(FHZ / 1000 * 10000);                        // 10 秒
    l0 = 0; for (t1 = m0; t1 < ev_n; t1 = t1 + 1) if (ev_log[t1] >= 10) l0 = l0 + 1;
    expect(l0 == 0 && ev_n > m0 + 2, "10 s of level 3: pictures rotate, no pages");
    force dut.u_serial_cmd.alarm_lvl = 2'd0; release dut.u_serial_cmd.alarm_lvl;
    m0 = ev_n;
    wait (ev_n >= m0 + 1);
    expect(ev_log[m0] == 10, "cleared: pages come back after the current picture");

    $display("== S4 the notice on screen is undone: leave it at once");
    wait (ev_log[ev_n - 1] == 11);
    force dut.u_serial_cmd.q_mask = 4'b0101;
    wait_cycles(10);
    expect(!dut.want_page, "page left");

    $display("== S5 manual mode (SW3 off): only the new notice is shown once, then back to the same picture");
    wait (ev_log[ev_n - 1] < 10);
    force dut.auto_st = 1'b0;                                // 手动（【按键改造】原来是 SW3 关）
    wait_cycles(FHZ / 1000 * 4000);
    m0 = ev_n; l0 = dut.img_idx;
    force dut.u_serial_cmd.q_mask = 4'b1101;
    q_pulse(2'd3);
    wait (ev_n >= m0 + 2);
    expect(ev_log[m0] == 13 && ev_log[m0 + 1] == l0, "slot 4 shown once, then the same picture");
    wait_cycles(FHZ / 1000 * 8000);
    expect(ev_n == m0 + 2, "nothing else happens in manual mode");
    show_log;
    $display("RESULT fails=%0d %s", fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
`endif
`ifdef BADHDR
    // 文件头校验：PIC3 目录项大小 200（像素区装不下），PIC4 像素偏移 250（超出文件）→ 两张都要被拒
    put32(0, 3 * 512 + 2 * 32 + 28, 200);
    put32(0, (3 + 6 - 2) * 512 + 10, 250);
    rst = 1; wait_cycles(5); rst = 0;
    wait (dut.scan_done); wait ((dut.loaded | dut.failed) == 4'hF && (dut.emerg_ld || dut.emerg_failed));
    wait_cycles(100);
    $display("BADHDR loaded=%b failed=%b err=%0d emerg_ld=%b", dut.loaded, dut.failed, err_code, dut.emerg_ld);
    $finish;
`endif

    $display("== 1 boot");
    wait (loaded_mask == 4'hF && dut.emerg_ld);
    wait_until_music;
    expect(display_valid && !card_missing && err_code == 0, "5 pictures loaded, music streaming, no error");
    expect(loads == 5, "exactly 5 loads at boot");

    $display("== 2 pull card while music streams, re-insert the same card");
    l0 = loads; m0 = music_restarts;
    wait_cycles(1000); card_present = 0;
    wait (card_missing); t0 = $time;
    $display("       card_missing after %0d cycles", ($time - t0) / 10);
    expect(display_valid && loaded_mask == 4'hF, "pictures still shown while the card is out");
    wait_cycles(3 * FHZ);                    // 卡拔出 3 秒（中间重试初始化）
    expect(card_missing && dut.cs != 0, "still waiting for the card");
    card_present = 1;
    wait (!card_missing);
    wait_cycles(1000);
    expect(loads == l0, "same card: nothing reloaded");
    expect(display_valid && loaded_mask == 4'hF && dut.emerg_ld, "pictures and EMERG kept");
    wait_until_music;
    expect(music_restarts == m0 + 1, "music restarted once");
    expect(err_code == 0, "timeout error cleared after recovery");

    $display("== 3 music paused (buffer full), pull the card");
    music_hold = 1;
    wait_cycles(FHZ / 2);
    card_present = 0;
    t0 = $time;
    wait (card_missing);
    $display("       found by the music-pause probe after %0d cycles", ($time - t0) / 10);
    expect(($time - t0) / 10 < 2 * FHZ, "detected within 1.5 s (probe 1 s + timeout 0.5 s)");
    music_hold = 0;
    wait_cycles(FHZ);
    card_present = 1;
    wait (!card_missing);
    expect(loads == l0 && loaded_mask == 4'hF, "same card again: nothing reloaded");

    $display("== 4 swap in a different card (PIC2 overwritten)");
    wait_until_music; wait_cycles(1000);
    card_present = 0; wait (card_missing);
    card_id = 1; wait_cycles(FHZ); card_present = 1;
    wait (!card_missing);
    wait_cycles(10);
    expect(!display_valid, "new card: old programme cleared (self-check runs again)");
    wait (loaded_mask == 4'hF && dut.emerg_ld);
    expect(loads == l0 + 5, "all 5 pictures reloaded from the new card");
    expect(display_valid, "new programme shown");

    $display("== 5 pull the card in the middle of loading a picture");
    wait_until_music; wait_cycles(1000);
    // 再换回卡 0：触发一次完整重载，在第 2 张载到一半时拔卡
    card_present = 0; wait (card_missing); card_id = 0; wait_cycles(FHZ / 2); card_present = 1;
    wait (!card_missing);
    wait (dut.load_busy && dut.load_idx == 1 && dut.bmp_read_m0.state == 3'd4);
    wait_cycles(200);                        // 小图一个扇区就读完，拔在读数据中间
    l0 = loads;
    card_present = 0; wait (card_missing);
    expect(dut.failed == 4'd0 && !dut.load_busy, "interrupted picture not counted as failed");
    wait_cycles(FHZ); card_present = 1;
    wait (!card_missing);
    wait (loaded_mask == 4'hF && dut.emerg_ld);
    expect(dut.failed == 4'd0, "all pictures loaded after re-insert");
    $display("       loads during scenario 5 after the pull: %0d", loads - l0);

    $display("== 6 idle probe without music (stream stopped)");
    // 没有音乐时空闲巡检：把音乐文件从卡上“删掉”，换卡触发重载，载完后 fat32 一直空闲
    card_present = 0; wait (card_missing);
    img[0][3 * 512 + 5 * 32] = 8'hE5;        // 删除 MUSIC.WAV 目录项
    wait_cycles(FHZ / 2); card_present = 1;
    wait (!card_missing);
    wait (loaded_mask == 4'hF && dut.emerg_ld);
    wait_cycles(FHZ / 10);
    expect(dut.bmp_read_m0.state == 3'd0, "no music: SD reader idle");
    probes = 0;
    wait_cycles(3 * FHZ);
    $display("       %0d idle probes in 3 s", probes);
    expect(probes >= 2 && probes <= 3, "about one probe per second");
    card_present = 0; t0 = $time;
    wait (card_missing);
    $display("       found by the idle probe after %0d cycles", ($time - t0) / 10);
    expect(($time - t0) / 10 < 2 * FHZ, "detected within 1.5 s");

    $display("RESULT fails=%0d %s", fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
// 进度：每 50 万拍打一行（马上写进文件，跑很久时能看出卡在哪）
integer cyc = 0;
always @(posedge clk) begin cyc = cyc + 1; if (cyc % 100_000 == 0) begin
    $fdisplay(prog_fd, "  [t=%0d k] cs=%0d fat=%0d init=%b scan=%b found=%0d loaded=%b failed=%b busy=%b emg=%b miss=%b loads=%0d present=%b",
             $time / 10_000, dut.cs, dut.bmp_read_m0.state, dut.sd_init_done, dut.scan_done, dut.img_found_count, loaded_mask,
             dut.failed, dut.load_busy, dut.emerg_ld, card_missing, loads, card_present);
    $fflush(prog_fd);
end end
task flush_now; begin $fflush; end endtask
initial begin #1_500_000_000; $display("TIMEOUT cs=%0d state=%0d", dut.cs, dut.bmp_read_m0.state); $finish; end
endmodule

// -----------------------------------------------------------------------------
// 行为级 TF 卡（替换官方 sd_card_top，端口相同）
//   复位后卡在就过 INIT_DLY 拍报 sd_init_done；不在就一直等（真卡：CMD0 一直重发）
//   读扇区：延迟 LAT 拍，每 2 拍一个字节，512 字节后 sd_sec_read_end 一拍（和官方一样是组合输出：状态 = 读完）
//   拔卡：之后所有读都不回（直到复位）
// -----------------------------------------------------------------------------
module sd_card_top #(
    parameter SPI_LOW_SPEED_DIV  = 248,
    parameter SPI_HIGH_SPEED_DIV = 0
)(
    input            clk,
    input            rst,
    output           SD_nCS,
    output           SD_DCLK,
    output           SD_MOSI,
    input            SD_MISO,
    output           sd_init_done,
    input            sd_sec_read,
    input  [31:0]    sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data,
    output reg       sd_sec_read_data_valid,
    output           sd_sec_read_end,
    input            sd_sec_write,
    input  [31:0]    sd_sec_write_addr,
    input  [7:0]     sd_sec_write_data,
    output           sd_sec_write_data_req,
    output           sd_sec_write_end
);
localparam integer INIT_DLY = 3000, LAT = 50;
assign SD_nCS = 1'b1; assign SD_DCLK = 1'b0; assign SD_MOSI = 1'b1;
assign sd_sec_write_data_req = 1'b0; assign sd_sec_write_end = 1'b0;
reg init_done, stale;
assign sd_init_done = init_done;
reg [1:0] st;
assign sd_sec_read_end = (st == 2'd3);
integer cnt, idx;
reg [31:0] lba;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        init_done <= 1'b0; stale <= 1'b0; cnt <= 0; idx <= 0; st <= 0; lba <= 0;
        sd_sec_read_data <= 0; sd_sec_read_data_valid <= 0;
    end else begin
        sd_sec_read_data_valid <= 1'b0;
        if (!tb_hp.card_present) stale <= 1'b1;
        if (!init_done) begin
            if (tb_hp.card_present) begin
                if (cnt >= INIT_DLY) begin init_done <= 1'b1; cnt <= 0; end else cnt <= cnt + 1;
            end else cnt <= 0;
        end else case (st)
            2'd0: if (sd_sec_read) begin lba <= sd_sec_read_addr; cnt <= 0; idx <= 0; st <= 2'd1; end
            2'd1: if (!stale && tb_hp.card_present) begin if (cnt >= LAT) begin cnt <= 0; st <= 2'd2; end else cnt <= cnt + 1; end
            2'd2: if (!stale && tb_hp.card_present) begin
                cnt <= cnt + 1;
                if (cnt[0]) begin
                    if (idx == 512) st <= 2'd3;   // 和官方控制器一样：最后一个字节之后下一拍才“读完”（不和数据有效同拍）
                    else begin
                        sd_sec_read_data       <= (lba < 64) ? tb_hp.img[tb_hp.card_id][lba * 512 + idx] : 8'h00;
                        sd_sec_read_data_valid <= 1'b1;
                        idx <= idx + 1;
                    end
                end
            end
            default: st <= 2'd0;
        endcase
    end
end
endmodule
