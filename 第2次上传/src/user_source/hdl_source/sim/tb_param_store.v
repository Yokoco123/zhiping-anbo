`timescale 1ns/1ps
// param_store 仿真：空芯片 → 保存 → 不变不写 → 重新上电载入 → 两槽轮流 → 保存中断电 → CRC 损坏 → 认不出芯片
// 【省资源】同一个 tb 跑新旧两版（-DOLD = 改之前的 param_store_pre_lut.v.bak + flash/），每步把两个槽的 12 字节和擦写次数记进
// `LOG，两份必须完全一样（= Flash 格式、选槽、版本号都和原来一样）。等待改成看 status（新旧状态机编码不同）。用法 run_param_equiv.sh
module tb;
parameter EW = 1;
reg clk = 0, rst = 1; always #5 clk = ~clk;
reg menu = 0; reg [7:0] bri = 100, con = 100, vol = 80; reg [2:0] per = 1;
wire load_valid; wire [7:0] lb, lc, lv; wire [2:0] lp; wire [3:0] status;
wire cs_n, sclk, mosi, miso, wp_n, hold_n;
reg ms_tick = 0; integer msd = 0;
always @(posedge clk) begin msd = (msd == 99_999) ? 0 : msd + 1; ms_tick <= (msd == 0); end
param_store #(.CLK_FREQ_HZ(100_000_000), .ENABLE_WRITE(EW), .RETRY_MS(1)) dut (
    .clk(clk), .rst(rst),
`ifndef OLD
    .ms_tick(ms_tick), .flags(3'b000), .ld_flags(),          // 【按键改造】开关保持 0：记录内容应该和原来完全一样
`endif
    .menu_on(menu), .bri_pct(bri), .con_pct(con), .vol_pct(vol), .period_idx(per),
    .load_valid(load_valid), .ld_bri(lb), .ld_con(lc), .ld_vol(lv), .ld_period(lp), .status(status),
`ifdef OLD
    .jedec_id(),
`endif
   
    .flash_cs_n(cs_n), .flash_sclk(sclk), .flash_mosi(mosi), .flash_wp_n(wp_n), .flash_hold_n(hold_n), .flash_miso(miso)
`ifndef OLD
    , .ext_req(1'b0), .ext_grant(), .ext_cs_n(1'b1), .ext_sclk(1'b0), .ext_mosi(1'b1), .chip_off()
`endif
    );
w25q64_model flash (.cs_n(cs_n), .sclk(sclk), .mosi(mosi), .miso(miso));

integer fails = 0, loads = 0; reg [26:0] last_load;
integer lf, si; initial lf = $fopen(`LOG, "w");
// 记一笔：状态、载入的值、两槽内容、擦写次数
task snap; begin
    $fwrite(lf, "st=%h loads=%0d last=%h er=%0d pr=%0d s0=", status, loads, last_load, flash.erase_cnt, flash.prog_cnt);
    for (si = 0; si < 12; si = si + 1) $fwrite(lf, "%h", flash.mem[si]);
    $fwrite(lf, " s1=");
    for (si = 0; si < 12; si = si + 1) $fwrite(lf, "%h", flash.mem[4096 + si]);
    $fwrite(lf, "\n");
end endtask
always @(posedge clk) if (load_valid) begin loads = loads + 1; last_load = {lb, lc, lv, lp}; end

task check; input c; input [8*60-1:0] msg; begin
    if (c) $display("  ok   %0s", msg); else begin $display("  FAIL %0s (status=%h)", msg, status); fails = fails + 1; end
end endtask
task power_up; begin   // 复位 = 重新上电
    rst = 1; loads = 0; repeat (20) @(posedge clk); rst = 0;
    wait (status != 4'h0); repeat (5) @(posedge clk);
    snap;
end endtask
task close_menu; begin
    @(negedge clk) menu = 1; repeat (50) @(negedge clk); menu = 0; repeat (5) @(posedge clk);   // 下降沿改输入，避免和 DUT 采样竞争
end endtask
task wait_save; begin
    wait (status == 4'h3); wait (status != 4'h3); repeat (5) @(posedge clk);
    snap;
end endtask
task setv; input [7:0] b, c, v; input [2:0] p; begin @(negedge clk); bri = b; con = c; vol = v; per = p; end endtask

integer e0, p0;
integer pk;
// 往模型里直接写一条记录（CRC 在 tb 里独立算；bad = 1 时故意弄错 CRC）
task putrec; input integer slot; input [31:0] ver; input [7:0] tag; input [7:0] b, c, v; input [2:0] p; input [7:0] fmt; input bad;
    reg [95:0] r; reg [15:0] cr; integer q; begin
    r = {ver, tag, b, c, v, 5'd0, p, fmt, 16'h0};
    cr = 16'hFFFF;
    for (q = 95; q >= 16; q = q - 1) cr = (cr[15] ^ r[q]) ? ({cr[14:0], 1'b0} ^ 16'h1021) : {cr[14:0], 1'b0};
    r[15:0] = cr ^ (bad ? 16'h0001 : 16'h0);
    for (q = 0; q < 12; q = q + 1) flash.mem[slot * 4096 + q] = r[95 - q * 8 -: 8];
end endtask
initial begin
    $display("== 1 blank chip");
    power_up;
    check(status == 4'h2 && loads == 0, "blank flash -> defaults, status 2, no load");

    $display("== 2 save after change");
    setv(120, 90, 50, 3); close_menu;
    if (EW) begin
        wait_save;
        check(status == 4'h5, "save ok, status 5");
        check(flash.erase_cnt == 1 && flash.prog_cnt == 1, "one erase + one program");
    end else begin
        repeat (20000) @(posedge clk);
        check(flash.erase_cnt == 0 && flash.prog_cnt == 0, "read-only: menu close does NOT write");
    end

    $display("== 3 close menu without change");
    e0 = flash.erase_cnt; close_menu; repeat (20000) @(posedge clk);
    check(flash.erase_cnt == e0, "unchanged -> no write");

    if (EW) begin
        $display("== 4 power cycle restores");
        setv(100, 100, 80, 1); power_up;   // param_adjust 复位回默认值，等 Flash 载入
        check(status == 4'h1 && loads == 1 && last_load == {8'd120, 8'd90, 8'd50, 3'd3}, "loaded 120/90/50/3, status 1");
        setv(120, 90, 50, 3);

        $display("== 5 second save goes to other slot");
        setv(60, 140, 0, 5); close_menu; wait_save;
        check(flash.mem[4096+3] == 8'h02 && flash.mem[3] == 8'h01, "slot0 ver1, slot1 ver2");
        power_up;
        check(status == 4'h1 && last_load == {8'd60, 8'd140, 8'd0, 3'd5}, "newest (ver2) loaded");
        setv(60, 140, 0, 5);

        $display("== 6 power cut during erase of third save");
        setv(150, 50, 100, 0); close_menu;
        wait (flash.busy == 1); #100_000;      // 擦除进行中
        rst = 1; #50; rst = 0; loads = 0;      // 掉电重启（芯片里擦除继续进行）
        wait (status != 4'h0); repeat (5) @(posedge clk);
        snap;
        check(status == 4'h1 && last_load == {8'd60, 8'd140, 8'd0, 3'd5}, "after cut: previous (ver2) still loaded");
        check(flash.mem[0] == 8'hFF, "slot0 was erased by interrupted save");
        check(dut.retries != 0, "preflight retried while chip busy");

        $display("== 7 corrupt CRC of the only good slot");
        flash.mem[4096+11] = flash.mem[4096+11] ^ 8'h01;
        setv(100, 100, 80, 1); power_up;
        check(status == 4'h2 && loads == 0, "bad CRC -> defaults, status 2");

        $display("== 8 save works again after corruption");
        setv(30, 60, 10, 2); close_menu; wait_save;
        power_up;
        check(status == 4'h1 && last_load == {8'd30, 8'd60, 8'd10, 3'd2}, "new record readable");

        $display("== 10 preloaded slot pairs (version wrap / tie / bad format), then save");
        for (pk = 0; pk < 7; pk = pk + 1) begin
            for (si = 0; si < 8192; si = si + 1) flash.mem[si] = 8'hFF;
            case (pk)
                0: begin putrec(0, 32'd5,         8'hA5, 40, 60, 70, 2, 8'h01, 0); putrec(1, 32'd4,         8'hA5, 41, 61, 71, 3, 8'h01, 0); end
                1: begin putrec(0, 32'hFFFFFFFF, 8'hA5, 40, 60, 70, 2, 8'h01, 0); putrec(1, 32'd0,         8'hA5, 41, 61, 71, 3, 8'h01, 0); end
                2: begin putrec(0, 32'd0,         8'hA5, 40, 60, 70, 2, 8'h01, 0); putrec(1, 32'h80000000, 8'hA5, 41, 61, 71, 3, 8'h01, 0); end
                3: begin putrec(0, 32'd9,         8'hA5, 40, 60, 70, 2, 8'h01, 0); putrec(1, 32'd9,         8'hA5, 41, 61, 71, 3, 8'h01, 0); end
                4: begin putrec(0, 32'd7,         8'h5A, 40, 60, 70, 2, 8'h01, 0); end                       // 不是我们的标记
                5: begin putrec(0, 32'd7,         8'hA5, 200, 60, 70, 2, 8'h01, 0); putrec(1, 32'd6, 8'hA5, 41, 61, 71, 3, 8'h01, 0); end // 最新那条亮度越界
                default: begin putrec(0, 32'd3,   8'hA5, 40, 60, 70, 2, 8'h01, 1); putrec(1, 32'd2,         8'hA5, 41, 61, 71, 3, 8'h01, 0); end // 槽 0 CRC 错
            endcase
            setv(100, 100, 80, 1); power_up;
            $display("       case %0d: status %h load %h", pk, status, last_load);
            setv(90, 110, 33, 4); close_menu; wait_save;
            $display("       case %0d: save status %h", pk, status);
            power_up;
            check(status == 4'h1 && last_load == {8'd90, 8'd110, 8'd33, 3'd4}, "saved record reads back");
            setv(90, 110, 33, 4);
        end

        $display("== 11 a stuck bit: verify must catch it");
        flash.stuck = 1;
        setv(22, 66, 11, 0); close_menu; wait_save;
        check(status == 4'hF, "verify mismatch -> status F");
        flash.stuck = 0;
        close_menu; repeat (20000) @(posedge clk); wait (status != 4'h3); repeat (5) @(posedge clk); snap;
        check(status == 4'h5, "after F, next menu close rewrites and succeeds");
        power_up;
        check(status == 4'h1 && last_load == {8'd22, 8'd66, 8'd11, 3'd0}, "and it reads back");
    end

    $display("== 9 unknown chip");
    flash.jedec = 24'hEF3017; e0 = flash.erase_cnt; p0 = flash.prog_cnt;
    power_up;
    check(status == 4'hE && loads == 0, "W25X64 id -> status E, defaults");
    setv(77, 77, 77, 4); close_menu; repeat (20000) @(posedge clk);
    check(flash.erase_cnt == e0 && flash.prog_cnt == p0, "no write when chip rejected");

    snap;
    check(flash.bad_access == 0, "never touched flash outside 0x7FE000~0x7FFFFF");
    $display("RESULT EW=%0d fails=%0d %s", EW, fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
initial begin #400_000_000; $display("TIMEOUT status=%h", status); $finish; end
endmodule
