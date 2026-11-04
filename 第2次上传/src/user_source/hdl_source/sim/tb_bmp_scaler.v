`timescale 1ns/1ps
// bmp_scaler 双线性版测试：独立整数模型逐像素对比 + 与理想浮点双线性比较误差
module tb;
parameter integer SW = 640;
parameter integer SH = 480;
parameter integer KA = 1;
parameter integer OW = 640, OH = 480;

reg clk = 0, rst = 1, clear = 1, start = 0;
reg in_valid = 0; reg [7:0] in_byte = 0;
wire in_pause, out_valid, done, overflow; wire [23:0] out_data;
always #5 clk = ~clk;

bmp_scaler #(.OUT_W(OW), .OUT_H(OH), .KEEP_ASPECT(KA)) dut (
    .clk(clk), .rst(rst), .clear(clear), .start(start),
    .src_w(SW[12:0]), .src_h(SH[12:0]),
    .in_valid(in_valid), .in_byte(in_byte), .in_pause(in_pause),
    .out_valid(out_valid), .out_data(out_data), .done(done), .overflow(overflow));

// 源图：带渐变、硬边、棋盘的伪随机图案
function [7:0] pf; input integer x, y, c;
    integer v;
    begin
        case (c)
            0: v = (x * 255) / (SW > 1 ? SW - 1 : 1);                 // R 横向渐变
            1: v = ((x / 3 + y / 3) % 2) ? 230 : 20;                  // G 3px 棋盘（硬边）
            default: v = (x * 37 + y * 91 + ((x * y) % 13) * 17) % 256; // B 伪随机
        endcase
        pf = v[7:0];
    end
endfunction

integer w_out, h_out, xoff, yb;
integer i, j, u, v, x, y, c, t, s, x0i, need, wgt, a, b, d;
reg [23:0] HS [0:4096*640-1];
reg [23:0] EXP [0:OW*OH-1];
real rmax_err; integer max_err, nerr, nout;

function integer lerp; input integer a, b, w;
    integer p;
    begin
        p = (b - a) * w + 128;
        lerp = a + (p >>> 8);
    end
endfunction

// 坐标映射：返回 {lo, hi, w}（lo/hi 源下标，w 权重）
integer m_lo, m_hi, m_w;
task map; input integer dd, S, D;
    begin
        t = ((2 * dd + 1) * S * 256) / (2 * D);
        if (t < 128) begin m_lo = 0; m_hi = 0; m_w = 0; end
        else begin
            s = t - 128; x0i = s / 256;
            if (x0i >= S - 1) begin m_lo = S - 1; m_hi = S - 1; m_w = 0; end
            else begin m_lo = x0i; m_hi = x0i + 1; m_w = s % 256; end
        end
    end
endtask

task build_model;
    begin
        if (KA) begin
            if (SW * OH >= SH * OW) begin
                w_out = OW; h_out = (SH * OW + SW / 2) / SW;
                if (h_out < 1) h_out = 1; if (h_out > OH) h_out = OH;
            end else begin
                h_out = OH; w_out = (SW * OH + SH / 2) / SH;
                if (w_out < 1) w_out = 1; if (w_out > OW) w_out = OW;
            end
        end else begin w_out = OW; h_out = OH; end
        xoff = (OW - w_out) / 2;
        yb   = (OH - h_out) - (OH - h_out) / 2;
        for (y = 0; y < SH; y = y + 1)
            for (u = 0; u < w_out; u = u + 1) begin
                map(u, SW, w_out);
                for (c = 0; c < 3; c = c + 1) begin
                    a = pf(m_lo, y, c); b = pf(m_hi, y, c);
                    HS[y * OW + u][23 - 8 * c -: 8] = lerp(a, b, m_w);
                end
            end
        for (i = 0; i < OW * OH; i = i + 1) EXP[i] = 24'd0;
        for (v = 0; v < h_out; v = v + 1) begin
            map(v, SH, h_out);
            for (u = 0; u < w_out; u = u + 1)
                for (c = 0; c < 3; c = c + 1) begin
                    a = HS[m_lo * OW + u][23 - 8 * c -: 8];
                    b = HS[m_hi * OW + u][23 - 8 * c -: 8];
                    EXP[(yb + v) * OW + xoff + u][23 - 8 * c -: 8] = lerp(a, b, m_w);
                end
        end
    end
endtask

// 理想双线性（浮点，同样中心对齐 + 边缘夹取）
function real ideal; input integer uu, vv, c;
    real sx, sy, fx, fy, p00, p10, p01, p11; integer ix, iy, ix1, iy1;
    begin
        sx = (uu + 0.5) * SW / w_out - 0.5; sy = (vv + 0.5) * SH / h_out - 0.5;
        if (sx < 0) sx = 0; if (sy < 0) sy = 0;
        if (sx > SW - 1) sx = SW - 1; if (sy > SH - 1) sy = SH - 1;
        ix = $rtoi(sx); iy = $rtoi(sy); fx = sx - ix; fy = sy - iy;
        ix1 = (ix + 1 < SW) ? ix + 1 : ix; iy1 = (iy + 1 < SH) ? iy + 1 : iy;
        p00 = pf(ix, iy, c); p10 = pf(ix1, iy, c); p01 = pf(ix, iy1, c); p11 = pf(ix1, iy1, c);
        ideal = (p00 * (1 - fx) + p10 * fx) * (1 - fy) + (p01 * (1 - fx) + p11 * fx) * fy;
    end
endfunction

// 输出收集与比较
integer ofs, r, col, dv; real e;
always @(posedge clk) if (out_valid) begin
    if (nout < OW * OH) begin
        if (out_data !== EXP[nout]) begin
            nerr = nerr + 1;
            if (nerr <= 5) $display("  MISMATCH idx=%0d (row %0d col %0d) got %h exp %h", nout, nout / OW, nout % OW, out_data, EXP[nout]);
        end
        r = nout / OW; col = nout % OW;
        if (r >= yb && r < yb + h_out && col >= xoff && col < xoff + w_out)
            for (c = 0; c < 3; c = c + 1) begin
                e = out_data[23 - 8 * c -: 8] - ideal(col - xoff, r - yb, c);
                if (e < 0) e = -e;
                if (e > rmax_err) rmax_err = e;
            end
        if (SW == OW && SH == OH)
            if (out_data !== {pf(col, r, 0), pf(col, r, 1), pf(col, r, 2)}) begin
                nerr = nerr + 1;
                if (nerr <= 5) $display("  NOT IDENTITY at %0d", nout);
            end
    end
    nout = nout + 1;
end

// 喂字节：仿流读器，每扇区开始前看 in_pause，扇区内 2~3 拍一个字节
integer total, sent, sec_left, rowbytes, bx, by, bk, cyc;
reg [7:0] bb;
initial begin
    nerr = 0; nout = 0; rmax_err = 0;
    build_model;
    repeat (5) @(posedge clk); rst <= 0;
    repeat (3) @(posedge clk); clear <= 0;
    @(posedge clk); start <= 1; @(posedge clk); start <= 0;
    rowbytes = ((3 * SW + 3) / 4) * 4;
    total = rowbytes * SH; sent = 0; sec_left = 512 - 54;
    while (sent < total) begin
        if (sec_left == 0) begin
            while (in_pause) @(posedge clk);
            sec_left = 512;
        end
        by = sent / rowbytes; bx = sent % rowbytes;
        if (bx < 3 * SW) begin
            bk = bx % 3;   // 0=B 1=G 2=R
            bb = pf(bx / 3, by, 2 - bk);
        end else bb = 8'hEE;
        in_valid <= 1; in_byte <= bb; @(posedge clk);
        in_valid <= 0; if (sent % 3 == 0) @(posedge clk);
        sent = sent + 1; sec_left = sec_left - 1;
    end
    cyc = 0;
    while (!done && cyc < 5000000) begin @(posedge clk); cyc = cyc + 1; end
    repeat (10) @(posedge clk);
    $display("RESULT %0dx%0d KA=%0d: w_out=%0d h_out=%0d out=%0d mismatches=%0d overflow=%0d done=%0d max|err vs ideal|=%0.2f %s",
             SW, SH, KA, w_out, h_out, nout, nerr, overflow, done, rmax_err,
             (nerr == 0 && nout == OW * OH && !overflow && done) ? "PASS" : "FAIL");
    $finish;
end
endmodule
