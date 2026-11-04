`timescale 1ns/1ps
// 【时序 t4】frame_fifo_read 改前（frame_fifo_read_old）和改后逐拍比所有输出：随机读请求 / 缩略图 / FIFO 满 / SDRAM 忙
//   BURST_SIZE 和顶层一样用 256（缩略图 128），另跑一遍 BURST_SIZE = 128
module tb_ffr;
reg clk = 0, rst = 1; always #4 clk = ~clk;
reg init_done = 0, ref_vld = 0, sdr_busy = 0, sdr_rd_en = 0, wr_busy = 0;
reg read_req = 0; reg [1:0] idx = 0; reg thumb = 0; reg [9:0] wrusedw = 0;
reg [20:0] a0 = 21'd0, a1 = 21'd307200, a2 = 21'd614400, a3 = 21'd921600, len = 21'd307200;
wire        en_o, en_n, ack_o, ack_n, fin_o, fin_n, aclr_o, aclr_n, th_o, th_n, busy_o, busy_n;
wire [20:0] ad_o, ad_n;
`ifndef BS
`define BS 256
`endif
frame_fifo_read_old #(.BURST_SIZE(`BS)) o (.rst(rst), .mem_clk(clk), .Sdr_init_done(init_done), .Sdr_init_ref_vld(ref_vld),
    .Sdr_busy(sdr_busy), .Sdr_rd_en(sdr_rd_en), .App_wr_busy(wr_busy), .O_rd_busy(busy_o), .App_rd_en(en_o), .App_rd_addr(ad_o),
    .read_req(read_req), .read_req_ack(ack_o), .read_finish(fin_o), .read_addr_0(a0), .read_addr_1(a1), .read_addr_2(a2),
    .read_addr_3(a3), .read_addr_index(idx), .read_len(len), .fifo_aclr(aclr_o), .wrusedw(wrusedw), .thumb_mode(thumb), .thumb_active(th_o));
frame_fifo_read #(.BURST_SIZE(`BS)) n (.rst(rst), .mem_clk(clk), .Sdr_init_done(init_done), .Sdr_init_ref_vld(ref_vld),
    .Sdr_busy(sdr_busy), .Sdr_rd_en(sdr_rd_en), .App_wr_busy(wr_busy), .O_rd_busy(busy_n), .App_rd_en(en_n), .App_rd_addr(ad_n),
    .read_req(read_req), .read_req_ack(ack_n), .read_finish(fin_n), .read_addr_0(a0), .read_addr_1(a1), .read_addr_2(a2),
    .read_addr_3(a3), .read_addr_index(idx), .read_len(len), .fifo_aclr(aclr_n), .wrusedw(wrusedw), .thumb_mode(thumb), .thumb_active(th_n));

integer diff = 0, cyc = 0, frames = 0, bursts = 0, tbursts = 0;
always @(posedge clk) if (!rst) begin
    cyc = cyc + 1;
    if ({en_o, ad_o, ack_o, fin_o, aclr_o, th_o, busy_o} !== {en_n, ad_n, ack_n, fin_n, aclr_n, th_n, busy_n}) begin
        if (diff < 5) $display("DIFF t=%0t en %b/%b addr %0d/%0d ack %b/%b fin %b/%b th %b/%b", $time, en_o, en_n, ad_o, ad_n, ack_o, ack_n, fin_o, fin_n, th_o, th_n);
        diff = diff + 1;
    end
    if (fin_o) frames = frames + 1;
    if (o.rd_burst_finish) begin bursts = bursts + 1; if (th_o) tbursts = tbursts + 1; end
end
// FIFO 用量：读出去一半随机，突发进来就加
always @(posedge clk) begin
    if (en_o && wrusedw < 10'd1000) wrusedw <= wrusedw + 10'd1;
    else if (($random & 3) == 0 && wrusedw != 0) wrusedw <= wrusedw - (($random & 1) ? 10'd2 : 10'd1);
    sdr_busy <= (($random & 63) == 0);
    wr_busy  <= (($random & 31) == 0);
end
integer k;
initial begin
    repeat (10) @(posedge clk); rst = 0; init_done = 1;
    for (k = 0; k < 40; k = k + 1) begin
        // 一帧：随机 bank / 缩略图，有时候读到一半就来下一个请求（帧头被提前）
        @(negedge clk); idx = $random; thumb = (($random & 3) == 0); len = (k % 5 == 0) ? 21'd2000 : 21'd307200 / 16;
        repeat (3) @(posedge clk);
        read_req = 1; wait (ack_o); repeat (4) @(posedge clk); read_req = 0;
        repeat (($random & 1) ? 4000 : 60000) @(posedge clk);
    end
    $display("cycles %0d, frames done %0d, bursts %0d (thumbnail %0d), diffs %0d", cyc, frames, bursts, tbursts, diff);
    $display("RESULT %s", (diff == 0 && bursts > 100 && tbursts > 20) ? "PASS" : "FAIL");
    $finish;
end
endmodule
