`timescale 1ns/1ps
// frame_fifo_write 新旧对比：随机写请求 / 写长度（含 0、比突发短、不是突发整数倍）/ FIFO 水位 / 忙信号，所有输出逐拍比较
module tb_ffw;
reg clk = 0, rst = 1; always #4 clk = ~clk;
reg init_done, rd_busy, sdr_busy, wreq; reg [9:0] rdusedw; reg [20:0] wlen; reg [1:0] idx;
`define P(s) .rst(rst), .mem_clk(clk), .Sdr_init_done(init_done), .Sdr_init_ref_vld(1'b0), .Sdr_busy(sdr_busy), .App_rd_busy(rd_busy), \
  .O_wr_busy(busy_``s), .App_wr_en(en_``s), .App_wr_addr(addr_``s), \
  .write_req(wreq), .write_req_ack(ack_``s), .write_finish(fin_``s), \
  .write_addr_0(21'h1000), .write_addr_1(21'h40000), .write_addr_2(21'h80000), .write_addr_3(21'hC0000), .write_addr_index(idx), \
  .write_len(wlen), .fifo_aclr(aclr_``s), .rdusedw(rdusedw)
wire busy_o, en_o, ack_o, fin_o, aclr_o, busy_n, en_n, ack_n, fin_n, aclr_n; wire [20:0] addr_o, addr_n;
frame_fifo_write_orig #(.WRITE_V_FLIP(1)) u_o (`P(o));
frame_fifo_write      #(.WRITE_V_FLIP(1)) u_n (`P(n));
integer cyc, fails = 0, bursts = 0, frames = 0;
always @(posedge clk) if (!rst) begin
  if ({busy_o, en_o, ack_o, fin_o, aclr_o, addr_o} !== {busy_n, en_n, ack_n, fin_n, aclr_n, addr_n}) begin
    fails = fails + 1; if (fails < 5) $display("MISMATCH t=%0t", $time); end
  if (u_o.state != u_n.state) begin fails = fails + 1; if (fails < 5) $display("STATE MISMATCH t=%0t", $time); end
  if (busy_o && !en_o && u_o.state == 2) bursts = bursts + 1;
  if (fin_o) frames = frames + 1;
end
initial begin
  init_done = 0; rd_busy = 0; sdr_busy = 0; wreq = 0; rdusedw = 0; wlen = 0; idx = 0;
  repeat (5) @(negedge clk); rst = 0; repeat (5) @(negedge clk); init_done = 1;
  for (cyc = 0; cyc < 3_000_000; cyc = cyc + 1) begin
    @(negedge clk);
    rdusedw  = ($random % 3 == 0) ? ($random & 10'h3FF) : ($random % 2 == 0) ? (10'd120 + ($random & 15)) : ($random & 10'h0FF);   // 120~135：卡在"剩余量"边界上
    rd_busy  = ($random % 4 == 0);
    sdr_busy = ($random % 6 == 0);
    if (!wreq && (u_o.state == 0) && $random % 50 == 0) begin
      wreq = 1; idx = $random;
      case ($random & 15) 0: wlen = 307200; 1, 2, 3, 4: wlen = 128; 5, 6, 7, 8, 9: wlen = 128 * (1 + ($random & 7)); default: wlen = 128 * (1 + ($random & 63)); endcase
    end else if (wreq && (ack_o || ack_n) && $random % 4 == 0) wreq = 0;
  end
  $display("RESULT cycles=%0d write_frames_finished=%0d fails=%0d %s", cyc, frames, fails, fails == 0 ? "PASS" : "FAIL");
  $finish;
end
endmodule
