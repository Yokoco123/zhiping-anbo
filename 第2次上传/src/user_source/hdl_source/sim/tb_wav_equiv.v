`timescale 1ns/1ps
// 【时序】wav_player 改前 / 改后对比：同样的字节流（几种 WAV + 坏文件 + 循环重读），
//   环形缓冲写入的样本序列、status、hold 必须一样（改后晚一拍，只比顺序和内容）
module tb_wav;
reg clk = 0, rst = 1; always #5 clk = ~clk;
reg vclk = 0; always #20 vclk = ~vclk;
reg bv = 0; reg [7:0] bd = 0; reg [31:0] bo = 0;
reg tick = 0;
wire h_new, h_old; wire [3:0] s_new, s_old; wire a_new, a_old;
wire signed [15:0] ln, rn, lo, ro;
wav_player     n (.wr_clk(clk), .wr_rst(rst), .byte_valid(bv), .byte_data(bd), .byte_off(bo), .hold(h_new), .status(s_new),
                  .rd_clk(vclk), .rd_rst_n(!rst), .sample_tick(tick), .volume(8'd255), .pause(1'b0), .out_left(ln), .out_right(rn), .active(a_new));
wav_player_old o (.wr_clk(clk), .wr_rst(rst), .byte_valid(bv), .byte_data(bd), .byte_off(bo), .hold(h_old), .status(s_old),
                  .rd_clk(vclk), .rd_rst_n(!rst), .sample_tick(tick), .volume(8'd255), .pause(1'b0), .out_left(lo), .out_right(ro), .active(a_old));
// 写入序列
reg [31:0] wn [0:65535]; reg [31:0] wo [0:65535]; integer nn = 0, no = 0;
always @(posedge clk) begin
    if (n.we) begin wn[nn] = {n.waddr, 20'd0} ^ n.wdata; nn = nn + 1; end
    if (o.we) begin wo[no] = {o.waddr, 20'd0} ^ o.wdata; no = no + 1; end
end
integer fails = 0, sdiff = 0, k;
reg [3:0] s_old_d; reg h_old_d;
always @(posedge clk) begin s_old_d <= s_old; h_old_d <= h_old; end
// SAMELAT：新旧都有输入寄存器（第 4 轮省资源对比第 3 轮），状态同一拍比
`ifdef SAMELAT
always @(posedge clk) if (!rst && (s_new !== s_old || h_new !== h_old)) sdiff = sdiff + 1;
`else
always @(posedge clk) if (!rst && (s_new !== s_old_d)) sdiff = sdiff + 1;
`endif

reg [7:0] f [0:8191]; integer flen;
task put32; input integer at; input [31:0] v; begin f[at] = v[7:0]; f[at+1] = v[15:8]; f[at+2] = v[23:16]; f[at+3] = v[31:24]; end endtask
task put16; input integer at; input [15:0] v; begin f[at] = v[7:0]; f[at+1] = v[15:8]; end endtask
// 生成一个 WAV：ch 声道，rate，可选 LIST 块（奇数长度），data n 字节
task mkwav; input integer ch; input integer rate; input integer list_len; input integer dn; input integer bits; integer p, i; begin
    f[0]="R"; f[1]="I"; f[2]="F"; f[3]="F"; put32(4, 0); f[8]="W"; f[9]="A"; f[10]="V"; f[11]="E";
    p = 12;
    if (list_len >= 0) begin
        f[p]="L"; f[p+1]="I"; f[p+2]="S"; f[p+3]="T"; put32(p+4, list_len); p = p + 8;
        for (i = 0; i < list_len + (list_len & 1); i = i + 1) f[p+i] = i * 7; p = p + list_len + (list_len & 1);
    end
    f[p]="f"; f[p+1]="m"; f[p+2]="t"; f[p+3]=" "; put32(p+4, 18); p = p + 8;
    put16(p, 1); put16(p+2, ch); put32(p+4, rate); put32(p+8, rate*ch*2); put16(p+12, ch*2); put16(p+14, bits); put16(p+16, 0); p = p + 18;
    f[p]="d"; f[p+1]="a"; f[p+2]="t"; f[p+3]="a"; put32(p+4, dn); p = p + 8;
    for (i = 0; i < dn; i = i + 1) f[p+i] = (i * 37 + 11) ^ (i >> 3);
    flen = p + dn;
end endtask
// 送一遍文件（偏移从 0 起），字节之间随机停顿；sector 边界看 hold
integer seed = 5;
task play; integer i; begin
    for (i = 0; i < flen; i = i + 1) begin
        if ((i % 512) == 0) while (h_old || h_new) @(posedge clk);
        @(negedge clk) bv = 1; bd = f[i]; bo = i;
        @(negedge clk) bv = 0;
        repeat ($unsigned($random(seed)) % 3) @(negedge clk);
    end
    repeat (10) @(negedge clk);
end endtask
task cmp; input [8*40-1:0] msg; integer i, bad; begin
    repeat (20) @(posedge clk);
    bad = (nn != no);
    for (i = 0; i < nn && i < no; i = i + 1) if (wn[i] !== wo[i]) bad = bad + 1;
    if (bad == 0 && s_new == s_old && h_new == h_old) $display("  ok   %0s  (%0d samples, status %0d)", msg, nn, s_new);
    else begin $display("  FAIL %0s  new %0d / old %0d samples, status %0d/%0d, bad %0d", msg, nn, no, s_new, s_old, bad); fails = fails + 1; end
end endtask
// 读侧慢慢取，免得一直 hold
always begin repeat (40) @(posedge vclk); tick = 1; @(posedge vclk); tick = 0; end

initial begin
    repeat (5) @(posedge clk); rst = 0;
    mkwav(2, 48000, 27, 3000, 16); play; cmp("stereo + odd LIST chunk");
    play;                            cmp("looped (offset back to 0)");
    mkwav(1, 48000, -1, 2001, 16); play; cmp("mono, odd data length");
    mkwav(2, 44100, -1, 400, 16);  play; cmp("44.1kHz -> unsupported");
    rst = 1; repeat (5) @(posedge clk); rst = 0; nn = 0; no = 0;
    mkwav(2, 48000, 0, 1000, 16);  play; cmp("zero-length LIST chunk");
    f[0] = "X"; play;                cmp("not RIFF");
    rst = 1; repeat (5) @(posedge clk); rst = 0; nn = 0; no = 0;
    mkwav(2, 48000, 4000, 2000, 16); play; cmp("big LIST chunk");
    // 【第 4 轮】文件头逐字节改坏 / fmt 各字段的各种取值（无 LIST 块：fmt 在 12，字段从 20 开始，data 块头在 38）
    for (k = 0; k < 12; k = k + 1) if (k < 4 || k >= 8) begin
        rst = 1; repeat (5) @(posedge clk); rst = 0; nn = 0; no = 0;
        mkwav(2, 48000, -1, 200, 16); f[k] = f[k] ^ (8'h01 << (k & 7)); play; cmp("RIFF/WAVE byte corrupted");
    end
    for (k = 0; k < 40; k = k + 1) begin
        rst = 1; repeat (5) @(posedge clk); rst = 0; nn = 0; no = 0;
        mkwav(2, 48000, -1, 200, 16);
        case (k)
            0:  put16(20, 3);          1:  put16(20, 16'h0101);   2:  put16(22, 0);          3:  put16(22, 1);
            4:  put16(22, 3);          5:  put16(22, 16'h0102);   6:  put16(22, 16'h0201);   7:  put32(24, 44100);
            8:  put32(24, 48000 + 65536); 9: put32(24, 32'h0100BB80); 10: put32(24, 32'h0000BB81); 11: put32(24, 32'h0000BC80);
            12: put16(34, 8);          13: put16(34, 16'h0110);   14: put16(34, 24);         15: put32(16, 14);
            16: put32(16, 16);         17: put32(16, 15);         18: f[12] = "F";            19: f[15] = "_";
            20: f[38] = "D";           21: f[41] = "A";           22: f[39] = "b";           23: put32(42, 0);
            24: put32(42, 1);          25: put32(42, 32'hFFFFFFFF); 26: f[14] = "x";          27: f[40] = "T";
            28: begin put16(22, 1); put32(24, 48000); end              29: begin put16(22, 1); put16(34, 8); end
            30: put16(20, 16'h0001);   31: put16(20, 16'h0100);   32: put16(22, 16'h0002);   33: put16(34, 16'h1000);
            34: put32(24, 32'h00BB8000); 35: put32(24, 32'h0000BB00); 36: put16(34, 16'h0010); 37: put32(16, 32'h00010012);
            38: put32(16, 0);          default: put32(16, 32'h0000_0011);
        endcase
        play; cmp("fmt / chunk-id variant");
        play; cmp("  ... looped");
    end
    if (sdiff != 0) begin $display("  FAIL status differs on %0d cycles", sdiff); fails = fails + 1; end
    $display("RESULT fails=%0d %s", fails, fails == 0 ? "PASS" : "FAIL");
    $finish;
end
endmodule
