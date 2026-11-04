`timescale 1ns/1ps
// seg_status 仿真：把扫描出来的 seg_sel / seg_data 按板上位置（从左到右）还原成 8 个字符，和期望的文字比
module tb_seg;
reg clk = 0, rst = 1; always #5 clk = ~clk;
reg emerg = 0, menu = 0, valid = 0;
reg [3:0] num = 0, err = 0; reg [2:0] tot = 0;
reg [7:0] bri = 100, con = 100, vol = 80; reg [2:0] per = 1; reg [1:0] msel = 0;
reg [7:0] lat = 0; reg lat_ok = 0; reg [6:0] pinfo = 0; reg mt = 0;
wire [7:0] sel, dat;
seg_status dut (.clk(clk), .rst(rst), .emerg(emerg), .menu_on(menu), .display_valid(valid),
    .img_num(num), .img_total(tot), .err_code(err), .bri_pct(bri), .con_pct(con), .vol_pct(vol),
    .period_idx(per), .menu_sel(msel), .lat_val(lat), .lat_ok(lat_ok), .page_info(pinfo), .muted(mt), .seg_sel(sel), .seg_data(dat));

// 段码 → 字符
function [7:0] chr; input [7:0] d; begin
    case (d[6:0])
        7'b100_0000: chr = "0"; 7'b111_1001: chr = "1"; 7'b010_0100: chr = "2"; 7'b011_0000: chr = "3";
        7'b001_1001: chr = "4"; 7'b001_0010: chr = "5"; 7'b000_0010: chr = "6"; 7'b111_1000: chr = "7";
        7'b000_0000: chr = "8"; 7'b001_0000: chr = "9"; 7'b011_1111: chr = "-"; 7'b000_1100: chr = "P";
        7'b100_0001: chr = "U"; 7'b000_0011: chr = "b"; 7'b100_0110: chr = "C"; 7'b000_0111: chr = "t";
        7'b000_0110: chr = "E"; 7'b010_1111: chr = "r"; 7'b111_1111: chr = " "; 7'b100_1000: chr = "n";
        default: chr = "?";
    endcase

end endfunction
// seg_sel 位 → 从左数第几位（板上 SEL7 SEL6 SEL5..SEL0；pin.adc seg_sel[0..5] = SEL5..SEL0，[6] = SEL6，[7] = SEL7）
function integer bit2pos; input integer b; begin
    case (b) 7: bit2pos = 0; 6: bit2pos = 1; 0: bit2pos = 2; 1: bit2pos = 3;
             2: bit2pos = 4; 3: bit2pos = 5; 4: bit2pos = 6; default: bit2pos = 7; endcase
end endfunction

reg [8*8-1:0] shown; reg [7:0] dps; integer seen, bad_sel, gaps;
always @(posedge clk) begin : cap
    integer b, n, hit;
    n = 0; hit = -1;
    for (b = 0; b < 8; b = b + 1) if (!sel[b]) begin n = n + 1; hit = b; end
    if (n > 1) bad_sel = bad_sel + 1;
    if (n == 0) gaps = gaps + 1;
    if (n == 1) begin
        shown[(7 - bit2pos(hit)) * 8 +: 8] = chr(dat);
        dps[7 - bit2pos(hit)] = !dat[7];
        seen = seen | (1 << bit2pos(hit));
    end
end
integer fails = 0;
task look; input [8*8-1:0] want; input [8*40-1:0] msg; begin look_dp(want, 8'h00, msg); end endtask
task look_dp; input [8*8-1:0] want; input [7:0] want_dp; input [8*40-1:0] msg; begin
    repeat (20) @(posedge clk);                              // 输入打两拍
    seen = 0; shown = "????????"; dps = 0;
    repeat (1 << 17) @(posedge clk);                         // 扫完一整圈
    if (seen == 8'hFF && shown == want && dps == want_dp) $display("  ok   [%s] dp=%b  %0s", shown, dps, msg);
    else begin $display("  FAIL [%s] dp=%b want [%s] dp=%b seen=%b  %0s", shown, dps, want, want_dp, seen[7:0], msg); fails = fails + 1; end
end endtask

initial begin
    bad_sel = 0; gaps = 0;
    repeat (5) @(posedge clk); rst = 0;
    look("----U 80", "boot: no picture yet, volume 80");
    err = 4;            look("Er 4U 80", "all pictures failed: error 4");
    valid = 1; num = 2; tot = 4;
                        look("P2-4U 80", "playing picture 2 of 4");
    err = 1;            look("P2-4U 80", "partial failure: normal display");
    vol = 0;            look("P2-4U  0", "volume 0");
    vol = 100;          look("P2-4U100", "volume 100");
    menu = 1; msel = 0; bri = 150; look("P2-4b150", "menu: brightness 150");
    msel = 1; con = 50;  look("P2-4C 50", "menu: contrast 50");
    msel = 2; vol = 8;   look("P2-4U  8", "menu: volume 8");
    msel = 3; per = 0;   look("P2-4t  1", "menu: period 1 s");
    per = 3;             look("P2-4t 10", "menu: period 10 s");
    per = 5;             look("P2-4t 60", "menu: period 60 s");
    menu = 0;            look("P2-4U  8", "menu closed: back to volume");
    num = 4; vol = 99;   look("P4-4U 99", "picture 4, volume 99");
    pinfo = {1'b1, 3'd2, 3'd3}; look("n2-3U 99", "notice page 2 of 3");
    pinfo = 0;           look("P4-4U 99", "back to the picture");
    emerg = 1;
    look("505  ---", "emergency entry: SOS lit at once, latency not measured yet");
    lat = 96; lat_ok = 1;
    look_dp("505   96", 8'b00000010, "emergency: latency 9.6 ms (decimal point)");
    lat = 179; look_dp("505  179", 8'b00000010, "latency 17.9 ms");
    lat = 3;   look_dp("505   03", 8'b00000010, "latency 0.3 ms");
    mt = 1;    look_dp("505   03", 8'b00100010, "muted: dot after the second S");
    mt = 0;
    dut.cnt = 26'h0000000; look_dp("      03", 8'b00000010, "emergency: SOS (blink off), value stays");
    lat_ok = 0;
    emerg = 0; menu = 1; msel = 0;
                         look("P4-4b150", "after emergency, menu again");
    if (bad_sel != 0) begin $display("  FAIL two digits on at once (%0d)", bad_sel); fails = fails + 1; end
    else $display("  ok   never two digits at once");
    if (gaps == 0) begin $display("  FAIL no blank gap between digits"); fails = fails + 1; end
    else $display("  ok   blank gap between digits");
    $display("RESULT fails=%0d %s", fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
endmodule
