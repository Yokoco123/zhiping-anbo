`timescale 1ns/1ps
// 仿真用 W25Q64 行为模型（SPI 模式 0）：存最后 8KB（0x7FE000~0x7FFFFF，参数）和开头 704KB（0x000000~0x0AFFFF，字库），
// 【启事】0x100000 起 4KB；【自定义字幕】0x101000 起 4KB；【串口照片】0x200000 ~ 0x5FFFFF（4 张照片各 1MB，只支持 D8 擦除）。其余地址读出 FF。支持 AB 9F 05 35 15 06 20 D8 02 03；擦除 / 编程有忙时间；越界擦写记为 bad_access。
module w25q64_model #(
    parameter integer ERASE_NS = 300_000,
    parameter integer PROG_NS  = 20_000,
    parameter integer BLOCK_NS = 500_000      // D8 擦 64KB
)(
    input  wire cs_n,
    input  wire sclk,
    input  wire mosi,
    output reg  miso
);
reg [23:0] jedec = 24'hEF4017;
reg [7:0]  mem [0:8191];
reg [7:0]  lo  [0:720895];      // 0x000000 ~ 0x0AFFFF
reg [7:0]  qm  [0:4095];        // 0x100000 ~ 0x100FFF【启事】
reg [7:0]  phm [0:4194303];     // 0x200000 ~ 0x5FFFFF【串口照片】
integer    ph_blk = 0, ph_prog = 0;
integer    q_erase = 0, q_prog = 0;
reg [7:0]  sm  [0:4095];        // 0x101000 ~ 0x101FFF (custom subtitles)
integer    s_erase = 0, s_prog = 0;
integer    blk_cnt = 0, page_cnt = 0;
reg [7:0]  sr2 = 8'h00;
reg        wel = 0, busy = 0;
reg        stuck = 0;             // 1 = 坏了一位：编程时第 6 个字节最低位写不成 0（测回读校验）
integer    erase_cnt = 0, prog_cnt = 0, bad_access = 0, i;
initial begin for (i = 0; i < 8192; i = i + 1) mem[i] = 8'hFF; for (i = 0; i < 720896; i = i + 1) lo[i] = 8'hFF; for (i = 0; i < 4096; i = i + 1) begin qm[i] = 8'hFF; sm[i] = 8'hFF; end for (i = 0; i < 4194304; i = i + 1) phm[i] = 8'hFF; miso = 1'b1; end

reg [7:0]  sh, cmd;
reg [2:0]  bitn;
integer    nbyte;
reg [23:0] addr;
reg [23:0] ea;                 // 擦除地址：命令那一刻锁存（真芯片如此；原来擦完才取 addr，期间别的命令会改掉它）
reg [7:0]  outb;
wire [7:0] sr1 = {6'd0, wel, busy};

function inrange; input [23:0] a; inrange = (a >= 24'h7FE000); endfunction
function inlo;    input [23:0] a; inlo    = (a <  24'h0B0000); endfunction
function inq;     input [23:0] a; inq     = (a[23:12] == 12'h100); endfunction
function ins;     input [23:0] a; ins     = (a[23:12] == 12'h101); endfunction
function inph;    input [23:0] a; inph    = (a >= 24'h200000) && (a < 24'h600000); endfunction
reg [23:0] pa;
reg [23:0] ba;                 // D8 擦除地址
integer    j;

always @(negedge cs_n) begin bitn = 0; nbyte = 0; cmd = 8'h00; outb = 8'hFF; end
always @(posedge cs_n) begin
    // 命令在 CS 拉高时生效
    if (nbyte >= 1) begin
        if (cmd == 8'h06 && !busy) wel = 1;
        if (cmd == 8'h20 && nbyte == 4 && wel && !busy) begin
            if (inq(addr)) begin
                q_erase = q_erase + 1; busy = 1; wel = 0;
                fork begin #(ERASE_NS); for (j = 0; j < 4096; j = j + 1) qm[j] = 8'hFF; busy = 0; end join_none
            end else if (ins(addr)) begin
                s_erase = s_erase + 1; busy = 1; wel = 0;
                fork begin #(ERASE_NS); for (j = 0; j < 4096; j = j + 1) sm[j] = 8'hFF; busy = 0; end join_none
            end else if (inlo(addr)) begin
                busy = 1; wel = 0; ea = addr;
                fork begin #(ERASE_NS); for (j = 0; j < 4096; j = j + 1) lo[{ea[19:12], 12'd0} + j] = 8'hFF; busy = 0; end join_none
            end else if (!inrange(addr)) bad_access = bad_access + 1;
            else begin
                erase_cnt = erase_cnt + 1; busy = 1; wel = 0; ea = addr;
                fork begin #(ERASE_NS); for (i = 0; i < 4096; i = i + 1) mem[{ea[12], 12'd0} + i] = 8'hFF; busy = 0; end join_none
            end
        end
        if (cmd == 8'hD8 && nbyte == 4 && wel && !busy) begin
            if (inph(addr)) begin
                ph_blk = ph_blk + 1; busy = 1; wel = 0; ba = addr - 24'h200000;
                fork begin #(BLOCK_NS); for (j = 0; j < 65536; j = j + 1) phm[{ba[21:16], 16'd0} + j] = 8'hFF; busy = 0; end join_none
            end else if (!inlo(addr)) bad_access = bad_access + 1;
            else begin
                blk_cnt = blk_cnt + 1; busy = 1; wel = 0; ba = addr;
                fork begin #(BLOCK_NS); for (j = 0; j < 65536; j = j + 1) lo[{ba[19:16], 16'd0} + j] = 8'hFF; busy = 0; end join_none
            end
        end
        if (cmd == 8'h02 && nbyte >= 5 && wel && !busy) begin
            if (inq(addr)) q_prog = q_prog + 1; else if (ins(addr)) s_prog = s_prog + 1; else if (inph(addr)) ph_prog = ph_prog + 1; else if (inlo(addr)) page_cnt = page_cnt + 1; else prog_cnt = prog_cnt + 1; busy = 1; wel = 0;
            fork begin #(PROG_NS); busy = 0; end join_none
        end
    end
end
always @(posedge sclk) if (!cs_n) begin
    sh = {sh[6:0], mosi};
    bitn = bitn + 1;
    if (bitn == 0) begin
        if (nbyte == 0) cmd = sh;
        else if (nbyte <= 3) addr = {addr[15:0], sh};
        else if (cmd == 8'h02 && wel && !busy) begin
            if (inq(addr)) qm[addr[11:0]] = qm[addr[11:0]] & sh;
            else if (ins(addr)) sm[addr[11:0]] = sm[addr[11:0]] & sh;
            else if (inph(addr)) begin pa = addr - 24'h200000; phm[pa[21:0]] = phm[pa[21:0]] & sh; end
            else if (inlo(addr)) lo[addr[19:0]] = lo[addr[19:0]] & sh;
            else if (!inrange(addr)) bad_access = bad_access + 1;
            else mem[addr[12:0]] = mem[addr[12:0]] & ((stuck && addr[3:0] == 4'd5) ? (sh | 8'h01) : sh);      // 编程只能把 1 变 0
            addr[7:0] = addr[7:0] + 1;                        // 页内回绕
        end
        nbyte = nbyte + 1;
        // 准备下一个要输出的字节
        case (cmd)
            8'h9F: outb = (nbyte == 1) ? jedec[23:16] : (nbyte == 2) ? jedec[15:8] : jedec[7:0];
            8'h05: outb = sr1;
            8'h35: outb = sr2;
            8'h15: outb = 8'h00;
            8'h03: if (nbyte >= 4) begin
                       pa = addr - 24'h200000;
                       outb = inq(addr) ? qm[addr[11:0]] : ins(addr) ? sm[addr[11:0]] : inph(addr) ? phm[pa[21:0]] : inlo(addr) ? lo[addr[19:0]] : inrange(addr) ? mem[addr[12:0]] : 8'hFF;
                       addr = addr + 1;
                   end
            default: outb = 8'hFF;
        endcase
    end
end
always @(negedge sclk) if (!cs_n) begin
    miso <= (nbyte >= 1 && (cmd == 8'h9F || cmd == 8'h05 || cmd == 8'h35 || cmd == 8'h15 || (cmd == 8'h03 && nbyte >= 4)))
            ? outb[7 - bitn] : 1'b1;
end
endmodule
