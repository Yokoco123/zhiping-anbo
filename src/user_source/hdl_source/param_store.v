`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// 【参数掉电保存】亮度 / 对比度 / 音量 / 轮播周期 存进板上独立的用户 Flash U33（W25Q64，8MB）
// U33 和存比特流的配置 Flash U39 是两颗芯片，这里怎么写都不会碰到固件。
//
//   上电（含 Key1 长按复位）：核对芯片 ID 和写保护 → 读两个记录槽 → 取校验正确、版本较新的那条，
//                             通过 load_valid 交给 param_adjust；没有有效记录就保持默认值
//   保存：SW2 菜单关闭的那一刻，参数和 Flash 里的不一样才写（一样就不写，省擦写次数）
//   【按键改造】另外存三个开关 flags = {波形关, 字幕关, 自动轮播关}（0 = 开，旧记录里这几位本来就是 0，读出来就是“都开”）：
//     开关一变（不在菜单里）就保存；放在音量字段的第 3~5 位（原来要求是 0，现在只要求第 6~7 位是 0）
//   防断电：两个 4KB 槽轮流写，每条记录带版本号 + CRC16，写到一半断电最多丢这一次修改
//
// 【省资源】2026-10-27 重写（原来用参考工程的 5 个模块，约 1760 LUT）：
//   Flash 里的记录格式、槽地址、选槽规则、版本号规则和原来完全一样，旧版本存的参数新版本能直接读出来。
//   记录 96 位 = {版本 32, 周期 32, 音量 8, 模式 8, CRC16}，CRC16 多项式 0x1021、初值 FFFF、高位先算，覆盖前 80 位；
//   借用参考工程的字段装我们的参数：周期字段 = {8'hA5 标记, 亮度, 对比度, 音量}，音量字段 = {5'b0, 轮播档位}，
//   模式字段 = 8'h01（格式号）。两槽：选 CRC 对、版本较新（按 32 位回绕比较）的那条；新记录版本 = 当前 + 1，
//   写到当前有效槽的另一个槽（都无效时写槽 0）。
//   省在哪里：
//     - 只有一个 SPI 移位引擎（SCLK = clk / 8），所有命令都是“命令字节 + 可选 3 字节地址 + n 个数据字节”
//     - 一个 96 位寄存器 rec 兼做读槽缓冲、写入数据、回读校验（循环移位，不另存一份）
//     - CRC 边收边算 / 边发边算，记录的 CRC 两个字节直接从 CRC 寄存器发出去，不用单独的 80 拍
//     - 读槽 0 时只记下它的版本和解出来的参数，不存整条记录
//     - 长时间（重试间隔、擦除超时）数上层的 1ms 节拍
//   擦除 / 编程后查忙（05）直到不忙，最后把 12 个字节读回来逐位比对，不对就报 F。
//
// status（给数码管）：0 启动中  1 已载入保存的参数  2 没有记录，用默认值  3 正在保存  5 保存成功
//                     E 芯片不认识或写保护（不再访问 Flash，用默认值）  F 写入出错
// ENABLE_WRITE = 0 时只读不写（第一步上板验证用）
// -----------------------------------------------------------------------------
module param_store #(
    parameter integer CLK_FREQ_HZ  = 100_000_000,
    parameter         ENABLE_WRITE = 1'b0,
    parameter integer RETRY_MS     = 200       // 认芯片失败后隔多久再试（仿真时改小），1~2047
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       ms_tick,              // 上层的 1ms 节拍
    input  wire       menu_on,              // SW2，菜单关闭时保存
    input  wire [7:0] bri_pct,              // param_adjust 当前值
    input  wire [7:0] con_pct,
    input  wire [7:0] vol_pct,
    input  wire [2:0] period_idx,
    input  wire [2:0] flags,                // 【按键改造】{波形关, 字幕关, 自动轮播关}
    output reg        load_valid,           // 单拍：把下面的值写进 param_adjust
    output reg  [7:0] ld_bri,
    output reg  [7:0] ld_con,
    output reg  [7:0] ld_vol,
    output reg  [2:0] ld_period,
    output reg  [2:0] ld_flags,             // 【按键改造】
    output reg  [3:0] status,
    output wire       flash_cs_n,
    output wire       flash_sclk,
    output wire       flash_mosi,
    output wire       flash_wp_n,
    output wire       flash_hold_n,
    input  wire       flash_miso,
    // 【串口指令】字库也放在这颗 Flash 里，serial_cmd 要读写时先申请：本模块空闲（READY）时让出 SPI 引脚，
    // 让出期间不开始保存（菜单关闭的保存请求挂着，还回来再存）
    input  wire       ext_req,
    output reg        ext_grant,
    input  wire       ext_cs_n,
    input  wire       ext_sclk,
    input  wire       ext_mosi,
    output wire       chip_off              // 1 = 芯片不认识 / 写保护，不再访问（字库也不能用）
);

localparam integer CYC_PER_US  = CLK_FREQ_HZ / 1_000_000;
localparam [13:0]  STARTUP_CYC = CYC_PER_US * 100;      // 上电后 100us 再访问
localparam [13:0]  WAKE_CYC    = CYC_PER_US * 10;       // 释放掉电（AB）后至少 3us
localparam [13:0]  POLL_CYC    = CYC_PER_US * 50;       // 50us 查一次忙
localparam [3:0]   CS_GAP_CYC  = 4'd10;                 // CS 高电平至少 50ns
localparam [10:0]  BUSY_TMO_MS = 11'd2000;              // 擦除最长 400ms、页编程最长 3ms，2 秒还忙算出错
localparam [10:0]  RETRY_W     = RETRY_MS;
localparam [1:0]   RETRY_MAX   = 2'd3;
localparam [23:0]  SLOT0       = 24'h7FE000;
localparam [23:0]  SLOT1       = 24'h7FF000;
localparam [7:0]   TAG         = 8'hA5;
localparam [7:0]   FMT         = 8'h01;

// 默认值，和 param_adjust 的复位值一致
localparam [7:0] DEF_BRI = 8'd100;
localparam [7:0] DEF_CON = 8'd100;
localparam [7:0] DEF_VOL = 8'd80;
localparam [2:0] DEF_PER = 3'd1;

assign flash_wp_n   = 1'b1;
assign flash_hold_n = 1'b1;
// SPI 引脚：自己的引擎，或让给 serial_cmd（ext_grant 是寄存器，只在双方 CS 都是高的时候变）
reg own_cs_n, own_sclk, own_mosi;
assign flash_cs_n = ext_grant ? ext_cs_n : own_cs_n;
assign flash_sclk = ext_grant ? ext_sclk : own_sclk;
assign flash_mosi = ext_grant ? ext_mosi : own_mosi;

// ---------------- SPI 移位引擎（模式 0，SCLK = clk / 8） ----------------
// 一次传输：CS 拉低 → 头（命令 8 位，或命令 + 地址 32 位）→ 数据 db 位 → CS 拉高至少 CS_GAP_CYC 拍
// hdr 每一位都左移、低位移进收到的位：头发完以后 hdr 低位就是收到的数据（读 ID 的 3 个字节、状态寄存器）
localparam [1:0] M_RD = 2'd0, M_SLOT = 2'd1, M_PROG = 2'd2, M_VER = 2'd3;
//   M_RD   只收到 hdr      M_SLOT 读一条记录进 rec，边收边算 CRC
//   M_PROG 发 rec 的前 80 位（边发边算 CRC），后 16 位发 CRC 寄存器，rec 循环移位 → 发完 rec 就是完整记录
//   M_VER  回读，和 rec 逐位比较，rec 循环移位不变
reg        xbusy;
reg        xgap;
reg  [2:0] xcnt;                    // 一位 8 拍：0 换 MOSI，3 拉高 SCLK 采样，7 拉低 SCLK、处理这一位
reg  [3:0] gcnt;
reg  [5:0] hb;                      // 头还剩几位
reg  [6:0] db;                      // 数据还剩几位
reg  [1:0] xmode;
reg [31:0] hdr;
reg [95:0] rec;
reg [15:0] crc;
reg        allff;                   // 读到的记录全是 FF（空槽）
reg        mism;                    // 回读不一致
reg        miso_q, rxb;
wire       in_hdr  = (hb != 6'd0);
wire       crc_ph  = (db > 7'd16);  // 数据前 80 位（CRC 覆盖的部分）
wire       crc_in  = (xmode == M_PROG) ? rec[95] : rxb;
wire [15:0] crc_nx = (crc[15] ^ crc_in) ? ({crc[14:0], 1'b0} ^ 16'h1021) : {crc[14:0], 1'b0};
wire       mosi_w  = in_hdr ? hdr[31] : (xmode == M_PROG) ? (crc_ph ? rec[95] : crc[15]) : 1'b1;
wire       xlast   = (hb == 6'd1 && db == 7'd0) || (hb == 6'd0 && db == 7'd1);

// ---------------- 记录内容 ----------------
wire [31:0] r_ver = rec[95:64];
wire [7:0]  r_bri = rec[55:48];
wire [7:0]  r_con = rec[47:40];
wire [7:0]  r_vol = rec[39:32];
wire [2:0]  r_per = rec[26:24];
wire [2:0]  r_flg = rec[29:27];          // 【按键改造】
wire        r_good = !allff && (crc == rec[15:0]);            // 读槽结束时：有内容且 CRC 对
wire        r_fmt  = (rec[63:56] == TAG) && (rec[23:16] == FMT) && (rec[31:30] == 2'd0) &&
                     (r_bri >= 8'd20) && (r_bri <= 8'd150) &&
                     (r_con >= 8'd50) && (r_con <= 8'd150) &&
                     (r_vol <= 8'd100) && (r_per <= 3'd5);    // 是我们的格式、数值在范围内
// 两槽当前有效的那条
reg         act_valid;
reg         act_slot;
reg  [31:0] act_ver;
reg         act_fmt;
wire [31:0] ver_d   = r_ver - act_ver;
wire        r_newer = (r_ver != act_ver) && !ver_d[31];           // 槽 1 比槽 0 新（32 位回绕比较）
wire        take1   = r_good && (!act_valid || r_newer);           // 读完槽 1：用槽 1

// ---------------- 菜单关闭 → 要不要保存 ----------------
reg  [29:0] saved;                      // Flash 里现在的内容 {开关, 亮度, 对比度, 音量, 档位}
wire [29:0] cur = {flags, bri_pct, con_pct, vol_pct, period_idx};
reg  [2:0]  flags_d;                    // 【按键改造】
reg         menu_d;
reg         pend;
wire        menu_close = menu_d && !menu_on;

// ---------------- 流程 ----------------
localparam [3:0] P_BOOT = 4'd0, P_ID = 4'd1, P_SR1 = 4'd2, P_SR2 = 4'd3, P_CHK = 4'd4, P_SLOT0 = 4'd5,
                 P_SLOT1 = 4'd6, P_READY = 4'd7, P_ERASE = 4'd8, P_POLL = 4'd9, P_POLLCHK = 4'd10,
                 P_WREN2 = 4'd11, P_PROG = 4'd12, P_VERIFY = 4'd13, P_DONE = 4'd14, P_RETRY = 4'd15;
reg  [3:0]  pc;
reg         off;                    // 芯片不认识：不再访问
assign chip_off = off;
reg  [13:0] dly;                    // 下一步之前等几拍
reg         dz;                     // 【时序】= (dly == 0)，和 dly 一起更新，省掉 14 位比较
reg  [10:0] ms_cnt;
reg  [1:0]  retries;
reg         id_ok, sr_ok;
reg         tgt;                    // 这次写哪个槽
reg         poll_ret;               // 查忙完了去哪：0 编程 1 回读
wire        step = !xbusy && dz && !off;

task launch;                        // 开始一次传输
    input [7:0]  c;
    input [23:0] a;
    input        has_a;
    input [6:0]  nbits;
    input [1:0]  m;
    begin
        xbusy      <= 1'b1;
        xgap       <= 1'b0;
        xcnt       <= 3'd0;
        hdr        <= {c, a};
        hb         <= has_a ? 6'd32 : 6'd8;
        db         <= nbits;
        xmode      <= m;
        crc        <= 16'hFFFF;
        allff      <= 1'b1;
        own_cs_n <= 1'b0;
    end
endtask

always @(posedge clk or posedge rst) begin
    if (rst) begin
        xbusy <= 1'b0; xgap <= 1'b0; xcnt <= 3'd0; gcnt <= 4'd0; hb <= 6'd0; db <= 7'd0; xmode <= M_RD;
        hdr <= 32'd0; rec <= 96'd0; crc <= 16'hFFFF; allff <= 1'b1; mism <= 1'b0; miso_q <= 1'b1; rxb <= 1'b1;
        own_cs_n <= 1'b1; own_sclk <= 1'b0; own_mosi <= 1'b1;
        act_valid <= 1'b0; act_slot <= 1'b0; act_ver <= 32'd0; act_fmt <= 1'b0;
        saved     <= {3'b000, DEF_BRI, DEF_CON, DEF_VOL, DEF_PER};
        flags_d   <= 3'b000;
        ld_flags  <= 3'b000;
        menu_d    <= 1'b0;
        ext_grant <= 1'b0;
        pend      <= 1'b0;
        pc        <= P_BOOT;
        off       <= 1'b0;
        dly       <= STARTUP_CYC;
        dz        <= (STARTUP_CYC == 14'd0);
        ms_cnt    <= 11'd0;
        retries   <= 2'd0;
        id_ok     <= 1'b0;
        sr_ok     <= 1'b0;
        tgt       <= 1'b0;
        poll_ret  <= 1'b0;
        load_valid <= 1'b0;
        ld_bri    <= DEF_BRI;
        ld_con    <= DEF_CON;
        ld_vol    <= DEF_VOL;
        ld_period <= DEF_PER;
        status    <= 4'h0;
    end else begin
        load_valid <= 1'b0;
        menu_d     <= menu_on;
        flags_d    <= flags;
        miso_q     <= flash_miso;
        if (ms_tick && (ms_cnt != 11'h7FF))
            ms_cnt <= ms_cnt + 11'd1;
        if (!xbusy && !dz) begin
            dly <= dly - 14'd1;
            dz  <= (dly == 14'd1);
        end

        // 菜单关上时值变了就挂一个保存请求；Flash 正忙时先挂着，忙完再存（存的是那时的最新值）
        if ((menu_close || ((flags != flags_d) && !menu_on)) && (cur != saved))   // 【按键改造】开关变了也存
            pend <= 1'b1;

        // ---------------- SPI 引擎 ----------------
        if (xbusy) begin
            if (xgap) begin
                gcnt <= gcnt + 4'd1;
                if (gcnt == CS_GAP_CYC - 4'd1)
                    xbusy <= 1'b0;
            end else begin
                xcnt <= xcnt + 3'd1;
                if (xcnt == 3'd0)
                    own_mosi <= mosi_w;
                if (xcnt == 3'd3) begin
                    own_sclk <= 1'b1;
                    rxb        <= miso_q;
                end
                if (xcnt == 3'd7) begin
                    own_sclk <= 1'b0;
                    hdr        <= {hdr[30:0], rxb};
                    if (in_hdr) begin
                        hb <= hb - 6'd1;
                    end else begin
                        db <= db - 7'd1;
                        case (xmode)
                            M_SLOT: begin
                                rec   <= {rec[94:0], rxb};
                                allff <= allff & rxb;
                                if (crc_ph) crc <= crc_nx;
                            end
                            M_PROG: begin
                                if (crc_ph) begin
                                    rec <= {rec[94:0], rec[95]};
                                    crc <= crc_nx;
                                end else begin
                                    rec <= {rec[94:0], crc[15]};
                                    crc <= {crc[14:0], 1'b0};
                                end
                            end
                            M_VER: begin
                                rec  <= {rec[94:0], rec[95]};
                                mism <= mism | (rxb ^ rec[95]);
                            end
                            default: ;
                        endcase
                    end
                    if (xlast) begin
                        own_cs_n <= 1'b1;
                        own_mosi <= 1'b1;
                        xgap       <= 1'b1;
                        gcnt       <= 4'd0;
                    end
                end
            end
        end

        // ---------------- 流程：上一次传输结束、等待时间到了才走下一步 ----------------
        if (step) case (pc)
            P_BOOT: begin                                    // 释放掉电
                launch(8'hAB, 24'd0, 1'b0, 7'd0, M_RD);
                dly <= WAKE_CYC;
                dz  <= (WAKE_CYC == 14'd0);
                pc  <= P_ID;
            end
            P_ID: begin                                      // 读 JEDEC ID（3 字节）
                launch(8'h9F, 24'd0, 1'b0, 7'd24, M_RD);
                pc <= P_SR1;
            end
            P_SR1: begin
                // 容量 64Mbit 的 25Q64（xx 40 17，不限厂家）
                id_ok <= (hdr[15:0] == 16'h4017) && (hdr[23:16] != 8'h00) && (hdr[23:16] != 8'hFF);
                launch(8'h05, 24'd0, 1'b0, 7'd8, M_RD);
                pc <= P_SR2;
            end
            P_SR2: begin
                sr_ok <= (hdr[1:0] == 2'b00) && (hdr[4:2] == 3'b000);   // 不忙、没有写使能残留、没有块保护
                launch(8'h35, 24'd0, 1'b0, 7'd8, M_RD);
                pc <= P_CHK;
            end
            P_CHK: begin
                if (id_ok && sr_ok && !hdr[6]) begin             // 状态寄存器 2 的 CMP 也要是 0
                    launch(8'h03, SLOT0, 1'b1, 7'd96, M_SLOT);
                    pc <= P_SLOT0;
                end else if (retries != RETRY_MAX) begin
                    // 可能是上次复位时芯片还在擦除（忙），等一会再认一次
                    retries <= retries + 2'd1;
                    ms_cnt  <= 11'd0;
                    pc      <= P_RETRY;
                end else begin
                    status <= 4'hE;
                    off    <= 1'b1;
                end
            end
            P_RETRY: if (ms_cnt >= RETRY_W) begin
                dly <= STARTUP_CYC;
                dz  <= (STARTUP_CYC == 14'd0);
                pc  <= P_BOOT;
            end
            P_SLOT0: begin
                act_valid <= r_good;
                act_slot  <= 1'b0;
                act_ver   <= r_good ? r_ver : 32'd0;
                act_fmt   <= r_fmt;
                if (r_good) begin
                    ld_bri <= r_bri; ld_con <= r_con; ld_vol <= r_vol; ld_period <= r_per; ld_flags <= r_flg;
                end
                launch(8'h03, SLOT1, 1'b1, 7'd96, M_SLOT);
                pc <= P_SLOT1;
            end
            P_SLOT1: begin
                if (take1) begin
                    act_valid <= 1'b1;
                    act_slot  <= 1'b1;
                    act_ver   <= r_ver;
                    act_fmt   <= r_fmt;
                    ld_bri <= r_bri; ld_con <= r_con; ld_vol <= r_vol; ld_period <= r_per; ld_flags <= r_flg;
                end
                if (take1 ? r_fmt : (act_valid && act_fmt)) begin
                    load_valid <= 1'b1;
                    saved      <= take1 ? {r_flg, r_bri, r_con, r_vol, r_per} : {ld_flags, ld_bri, ld_con, ld_vol, ld_period};
                    status     <= 4'h1;
                end else begin
                    status <= 4'h2;                          // 空芯片或记录不认识：用默认值
                end
                pc <= P_READY;
            end
            P_READY: begin
                if (ENABLE_WRITE == 0)
                    pend <= 1'b0;
                if (ext_grant) begin
                    if (!ext_req)
                        ext_grant <= 1'b0;                  // serial_cmd 用完了
                end else if (pend && (ENABLE_WRITE != 0)) begin
                    pend   <= 1'b0;
                    rec    <= {act_ver + 32'd1, TAG, bri_pct, con_pct, vol_pct, 2'd0, flags, period_idx, FMT, 16'h0000};
                    saved  <= cur;                           // 先记下；写失败会在下面改回“不确定”
                    tgt    <= act_valid && !act_slot;        // 写另一个槽；都无效写槽 0
                    status <= 4'h3;
                    launch(8'h06, 24'd0, 1'b0, 7'd0, M_RD);  // 写使能
                    pc     <= P_ERASE;
                end else if (ext_req) begin
                    ext_grant <= 1'b1;                      // 保存优先，空闲时才让出
                end
            end
            P_ERASE: begin                                   // 扇区擦除 4KB
                launch(8'h20, tgt ? SLOT1 : SLOT0, 1'b1, 7'd0, M_RD);
                ms_cnt   <= 11'd0;
                poll_ret <= 1'b0;
                pc       <= P_POLL;
            end
            P_POLL: begin                                    // 读状态寄存器 1
                launch(8'h05, 24'd0, 1'b0, 7'd8, M_RD);
                pc <= P_POLLCHK;
            end
            P_POLLCHK: begin
                if (hdr[0]) begin                            // 还在忙
                    if (ms_cnt >= BUSY_TMO_MS) begin
                        status <= 4'hF;
                        saved  <= 30'h3FFFFFFF;               // 不知道 Flash 里是什么了：下次关菜单一定重写
                        pc     <= P_READY;
                    end else begin
                        dly <= POLL_CYC;
                        dz  <= (POLL_CYC == 14'd0);
                        pc  <= P_POLL;
                    end
                end else begin
                    pc <= poll_ret ? P_VERIFY : P_WREN2;
                end
            end
            P_WREN2: begin
                launch(8'h06, 24'd0, 1'b0, 7'd0, M_RD);
                pc <= P_PROG;
            end
            P_PROG: begin                                    // 页编程 12 字节
                launch(8'h02, tgt ? SLOT1 : SLOT0, 1'b1, 7'd96, M_PROG);
                ms_cnt   <= 11'd0;
                poll_ret <= 1'b1;
                pc       <= P_POLL;
            end
            P_VERIFY: begin                                  // 读回来比对
                launch(8'h03, tgt ? SLOT1 : SLOT0, 1'b1, 7'd96, M_VER);
                mism <= 1'b0;
                pc   <= P_DONE;
            end
            P_DONE: begin
                if (mism) begin
                    status <= 4'hF;
                    saved  <= 30'h3FFFFFFF;
                end else begin
                    status    <= 4'h5;
                    act_valid <= 1'b1;
                    act_slot  <= tgt;
                    act_ver   <= r_ver;
                    act_fmt   <= 1'b1;
                end
                pc <= P_READY;
            end
            default: pc <= P_READY;
        endcase
    end
end

endmodule
