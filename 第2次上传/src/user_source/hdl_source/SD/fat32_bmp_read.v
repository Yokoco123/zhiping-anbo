`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// FAT32 版 bmp_read
// 端口与 bmp_read 完全相同，sd_card_bmp 里只需把模块名 bmp_read 换成 fat32_bmp_read。
//
// 内部结构：
//   fat32_volume_scanner : 解析 MBR/BPB，在根目录里找 PIC1~PIC4.BMP（参考模块，未改）
//   fat32_file_streamer  : 按 FAT 链读出文件字节流（参考模块，未改）
//   扇区读适配           : 把两者的 sector_* 接口转成官方 sd_card_top 的 sd_sec_* 接口，
//                          扫描阶段给扫描器用，加载阶段给流读器用
//   BMP 头校验/像素拼装  : 沿用 bmp_read 的严格校验和错误码
//   【拔卡恢复】TF 卡座没有卡检测脚：任何读扇区超时都报 card_lost；不读卡的时候（没有音乐 / 音乐暂停）
//              每秒巡检读一次 0 号扇区，拔卡最多 1.5 秒就能发现；fs_sig 给上层判断插回的是不是同一张卡
//
// 与 bmp_read 的约定差异：
//   scan_found_sector 不再是物理扇区号，而是资源编号 0~3（PIC1~PIC4）；
//   sd_card_bmp 原样把它存进 img_sector0~3，再通过 load_sector 传回，所以上层不用改。
// -----------------------------------------------------------------------------
module fat32_bmp_read #(
    parameter integer CLK_FREQ_HZ = 100_000_000
)(
    input                       clk,
    input                       rst,
    input                       ms_tick,             // 【省资源】上层的 1ms 节拍：读扇区超时、音乐暂停巡检按毫秒数
    output                      ready,

    input                       scan_start,
    input  [31:0]               scan_start_sector,   // 未使用，保留端口兼容
    input  [31:0]               scan_max_sector,     // 未使用
    input  [2:0]                scan_target_count,   // 未使用
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,

    input                       load_start,
    input                       load_abort,
    input  [31:0]               load_sector,         // 低 2 位 = 资源编号；【应急模式】第 2 位 = 1 表示 EMERG.BMP

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output                      bmp_data_wr_en,      // 改由 bmp_scaler 输出，固定 640×480 个像素
    output     [23:0]           bmp_data,
    output reg                  load_error,
    output reg [3:0]            bmp_error,

    // 背景音乐：图片全部预载完后，由上层发 music_start，循环流式读 MUSIC.WAV
    input                       music_start,
    output                      music_found,         // 根目录里有 MUSIC.WAV
    output                      emerg_found,         // 【应急模式】根目录里有 EMERG.BMP
    output                      music_byte_valid,
    output [7:0]                music_byte,
    output [31:0]               music_off,
    input                       music_hold,          // wav_player 缓冲快满：暂停读下一个扇区
    // 【拔卡恢复】TF 卡座没有卡检测脚，只能靠“读扇区超时”发现卡被拔掉
    input                       probe_start,         // 空闲时上层每秒发一次：读一下 0 号扇区，看卡还在不在
    output reg                  card_lost,           // 单拍：读扇区超时（卡被拔掉 / 接触不良），上层要重新初始化 SD 卡
    output     [31:0]           fs_sig,              // 卡指纹（扫描器给出），插回卡后比对是不是同一张卡
    output     [25:0]           src_dims             // 【分辨率显示】最近一次读到的 BMP 宽高 {高 13 位, 宽 13 位}，载图成功时由上层记下
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_REPORT    = 3'd2;   // 把扫描到的 PIC1~4 逐个报给上层
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;
localparam ST_MUSIC     = 3'd5;   // 循环读 MUSIC.WAV
localparam ST_LOAD_FLUSH = 3'd6;  // 文件读完，等缩放器把剩下的行发完
localparam ST_PROBE     = 3'd7;   // 【拔卡恢复】巡检：读一次 0 号扇区（空闲时由上层发起；音乐暂停太久时自己发起）

localparam ERR_NONE      = 4'd0;
localparam ERR_HEADER    = 4'd1;   // BMP 头校验失败
localparam ERR_TIMEOUT   = 4'd2;   // 读扇区超时
localparam ERR_TRUNCATED = 4'd3;   // 像素数不足
localparam ERR_FS        = 4'd4;   // 不是 FAT32 / 根目录里没有 PIC1~4.BMP
localparam ERR_FAT       = 4'd5;   // 读文件时 FAT 链出错
// 7 = 没有 55AA 引导签名，8 = 分区/BPB 不是 FAT32（见 ST_SCAN）

localparam [9:0]  SECTOR_TIMEOUT_MS = 10'd500;   // 单扇区 500ms
localparam [10:0] PROBE_MS          = 11'd1000;  // 【拔卡恢复】音乐缓冲一直满（暂停）超过 1 秒就巡检一次

reg [2:0] state;
assign ready = (state == ST_IDLE);

wire use_streamer = (state == ST_LOAD_WAIT) || (state == ST_LOAD_DATA) || (state == ST_MUSIC);
wire mus_pause    = (state == ST_MUSIC) && music_hold;
wire scl_pause;                                          // 缩放器字节缓冲过半
wire scl_hold     = (state == ST_LOAD_DATA) && scl_pause;
wire probing      = (state == ST_PROBE);                 // 【拔卡恢复】巡检读占用扇区读口

// ---------------------------------------------------------------------------
// 局部复位：读卡超时 / 上层中止时，单独复位扫描器、流读器和适配器，
// 不影响已经扫描到的文件表（扫描器只在扫描超时时才复位）
// ---------------------------------------------------------------------------
reg kill_scan;
reg kill_load;
reg kill_probe;              // 【拔卡恢复】巡检超时：只复位适配器
reg scn_rst_n;
reg str_rst_n;
reg adp_rst_n;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        scn_rst_n <= 1'b0;
        str_rst_n <= 1'b0;
        adp_rst_n <= 1'b0;
    end else begin
        scn_rst_n <= ~kill_scan;
        str_rst_n <= ~kill_load;
        adp_rst_n <= ~(kill_scan | kill_load | kill_probe);
    end
end

// ---------------------------------------------------------------------------
// 扇区读适配：sector_req(单拍) → sd_sec_read(电平，保持到 sd_sec_read_end)
// 同时补出官方接口没有的 busy 和字节序号
// ---------------------------------------------------------------------------
wire        scn_req;
wire [31:0] scn_lba;
wire        str_req;
wire [31:0] str_lba;
reg         prb_req;                // 【拔卡恢复】巡检读请求（单拍）
wire        sec_req = probing ? prb_req : use_streamer ? str_req : scn_req;
wire [31:0] sec_lba = probing ? 32'd0  : use_streamer ? str_lba : scn_lba;
reg         sec_busy;
reg  [8:0]  sec_idx;

always @(posedge clk or negedge adp_rst_n) begin
    if (!adp_rst_n) begin
        sd_sec_read      <= 1'b0;
        sd_sec_read_addr <= 32'd0;
        sec_busy         <= 1'b0;
        sec_idx          <= 9'd0;
    end else if (!sec_busy) begin
        if (sec_req) begin
            sd_sec_read      <= 1'b1;
            sd_sec_read_addr <= sec_lba;
            sec_busy         <= 1'b1;
            sec_idx          <= 9'd0;
        end
    end else if (sd_sec_read_end) begin
        sd_sec_read <= 1'b0;
        sec_busy    <= 1'b0;
    end else if (sd_sec_read_data_valid) begin
        sec_idx <= sec_idx + 9'd1;
    end
end

// ---------------------------------------------------------------------------
// 卷扫描器：找 PIC1~PIC4.BMP 的起始簇和大小
// ---------------------------------------------------------------------------
reg         scn_start;
wire        scn_done_p;
wire [7:0]  scn_err;
wire [7:0]  spc;
wire [31:0] fat_lba;
wire [31:0] data_lba;
wire [31:0] max_clu;
wire [3:0]  res_valid;
wire [31:0] res_clu0, res_clu1, res_clu2, res_clu3;
wire [31:0] res_size0, res_size1, res_size2, res_size3;
wire        mus_valid;
wire [31:0] mus_clu;
wire [31:0] mus_size;
wire        emg_valid;
wire [31:0] emg_clu;
wire [31:0] emg_size;

fat32_volume_scanner u_scanner (
    .clk                 (clk),
    .rst_n               (scn_rst_n),
    .scan_start          (scn_start),
    .scan_busy           (),
    .scan_done           (scn_done_p),
    .fs_error            (scn_err),
    .partition_lba       (),
    .sectors_per_cluster (spc),
    .fat_start_lba       (fat_lba),
    .data_start_lba      (data_lba),
    .max_cluster         (max_clu),
    .resource_valid      (res_valid),
    .resource0_cluster   (res_clu0),
    .resource1_cluster   (res_clu1),
    .resource2_cluster   (res_clu2),
    .resource3_cluster   (res_clu3),
    .resource0_size      (res_size0),
    .resource1_size      (res_size1),
    .resource2_size      (res_size2),
    .resource3_size      (res_size3),
    .music_valid         (mus_valid),
    .music_cluster       (mus_clu),
    .music_size          (mus_size),
    .emerg_valid         (emg_valid),
    .emerg_cluster       (emg_clu),
    .emerg_size          (emg_size),
    .dir_signature       (fs_sig),
    .sector_req          (scn_req),
    .sector_lba          (scn_lba),
    .sector_busy         (sec_busy),
    .sector_valid        (sd_sec_read_data_valid & ~use_streamer & ~probing),
    .sector_byte         (sd_sec_read_data),
    .sector_byte_index   (sec_idx),
    .sector_done         (sd_sec_read_end & ~use_streamer & ~probing),
    .sector_error        (8'd0)
);

// ---------------------------------------------------------------------------
// 文件流读取器：按 FAT 链输出文件字节
// ---------------------------------------------------------------------------
reg         str_start;
reg  [31:0] cur_cluster;
reg  [31:0] cur_size;       // 目录项里的文件大小
wire        str_done_p;
wire        str_valid;
wire [7:0]  str_byte;
wire [31:0] str_off;
wire [7:0]  str_err;

fat32_file_streamer u_streamer (
    .clk                 (clk),
    .rst_n               (str_rst_n),
    .file_start          (str_start),
    .first_cluster       (cur_cluster),
    .file_size           (cur_size),
    .sectors_per_cluster (spc),
    .fat_start_lba       (fat_lba),
    .data_start_lba      (data_lba),
    .max_cluster         (max_clu),
    .file_busy           (),
    .file_done           (str_done_p),
    .file_valid          (str_valid),
    .file_byte           (str_byte),
    .file_byte_offset    (str_off),
    .fs_error            (str_err),
    .sector_req          (str_req),
    .sector_lba          (str_lba),
    .sector_busy         (sec_busy | mus_pause | scl_hold | probing),   // 音乐缓冲满时假装忙，流读器停在发请求前；缩放器同理；【拔卡恢复】巡检时也停住
    .sector_valid        (sd_sec_read_data_valid & use_streamer),
    .sector_byte         (sd_sec_read_data),
    .sector_byte_index   (sec_idx),
    .sector_done         (sd_sec_read_end & use_streamer),
    .sector_error        (8'd0)
);

// 音乐字节流直接送给 wav_player（解析文件头也在那边做）
assign music_found      = mus_valid;
assign emerg_found      = emg_valid;
assign music_byte_valid = str_valid && (state == ST_MUSIC);
assign music_byte       = str_byte;
assign music_off        = str_off;

function [31:0] clu_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0:    clu_lut = res_clu0;
            2'd1:    clu_lut = res_clu1;
            2'd2:    clu_lut = res_clu2;
            default: clu_lut = res_clu3;
        endcase
    end
endfunction

function [31:0] size_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0:    size_lut = res_size0;
            2'd1:    size_lut = res_size1;
            2'd2:    size_lut = res_size2;
            default: size_lut = res_size3;
        endcase
    end
endfunction

// ---------------------------------------------------------------------------
// BMP 头捕获（文件偏移 0~33）与严格校验
// ---------------------------------------------------------------------------
// 【省资源 第4轮】只比“等不等于某个值”的字段（BM、DIB 头长度、平面数、位深、压缩方式、宽高的高 16 位）
//   收到时就算成 1 位标志，不再存整个字段；像素偏移和宽高低 16 位要参与计算，照样存。
//   校验只在偏移 34 用一次，那时 0~33 字节都已经是这张图的（和原来一样）
reg        h_b, h_m;                // 第 0、1 字节 = 'B'、'M'
reg [31:0] pixel_offset;
reg        d14_ge40;                // DIB 头长度 >= 40：最低字节 >= 40，或者高 3 字节不全为 0
reg        d15_nz, d16_nz, d17_nz;
reg [15:0] width;                   // 宽高的低 16 位（高 16 位只要求是 0）
reg [15:0] height;
assign src_dims = {height[12:0], width[12:0]};
reg        w20_z, w21_z, h24_z, h25_z;
reg        p26_1, p27_0;            // 平面数 = 1
reg        c28_24, c29_0;           // 位深 = 24
reg        z30, z31, z32, z33;      // 压缩方式 = 0
wire [7:0] hb = str_byte;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        h_b          <= 1'b0;
        h_m          <= 1'b0;
        pixel_offset <= 32'd0;
        {d14_ge40, d15_nz, d16_nz, d17_nz} <= 4'b0000;
        width        <= 16'd0;
        height       <= 16'd0;
        {w20_z, w21_z, h24_z, h25_z} <= 4'b1111;
        {p26_1, p27_0, c28_24, c29_0} <= 4'b0101;
        {z30, z31, z32, z33} <= 4'b1111;
    end else if (str_start) begin
        h_b          <= 1'b0;       // 清掉上一张的头，防止短文件沿用旧值通过校验
        h_m          <= 1'b0;
    end else if (str_valid && (str_off < 32'd34)) begin
        case (str_off[5:0])
            6'd0 : h_b                  <= (hb == "B");
            6'd1 : h_m                  <= (hb == "M");
            6'd10: pixel_offset[7:0]    <= hb;
            6'd11: pixel_offset[15:8]   <= hb;
            6'd12: pixel_offset[23:16]  <= hb;
            6'd13: pixel_offset[31:24]  <= hb;
            6'd14: d14_ge40             <= (hb >= 8'd40);
            6'd15: d15_nz               <= (hb != 8'd0);
            6'd16: d16_nz               <= (hb != 8'd0);
            6'd17: d17_nz               <= (hb != 8'd0);
            6'd18: width[7:0]           <= hb;
            6'd19: width[15:8]          <= hb;
            6'd20: w20_z                <= (hb == 8'd0);
            6'd21: w21_z                <= (hb == 8'd0);
            6'd22: height[7:0]          <= hb;
            6'd23: height[15:8]         <= hb;
            6'd24: h24_z                <= (hb == 8'd0);
            6'd25: h25_z                <= (hb == 8'd0);
            6'd26: p26_1                <= (hb == 8'd1);
            6'd27: p27_0                <= (hb == 8'd0);
            6'd28: c28_24               <= (hb == 8'd24);
            6'd29: c29_0                <= (hb == 8'd0);
            6'd30: z30                  <= (hb == 8'd0);
            6'd31: z31                  <= (hb == 8'd0);
            6'd32: z32                  <= (hb == 8'd0);
            6'd33: z33                  <= (hb == 8'd0);
            default: ;
        endcase
    end
end

// 不再要求 640×480：宽高 1~4096 都接受，由 bmp_scaler 缩放到 640×480
// （bmp_width/bmp_height 端口保留不用）。高度为负的自上而下 BMP 不支持，按文件头错误处理。
// 像素区字节数 = 行字节数（3W 补到 4 的倍数）× H，宽高在偏移 25 就收齐了，
// 这里用两级寄存器算乘法，到偏移 34 校验时早已稳定
localparam [15:0] MAX_DIM = 16'd4096;
wire dims_ok = w20_z && w21_z && (width  != 16'd0) && (width  <= MAX_DIM) &&
               h24_z && h25_z && (height != 16'd0) && (height <= MAX_DIM);
reg [13:0] row_bytes_r;
reg [27:0] pix_bytes_r;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        row_bytes_r <= 14'd0;
        pix_bytes_r <= 28'd0;
    end else begin
        row_bytes_r <= {width[12:0], 1'b0} + width[12:0] + width[1:0];
        pix_bytes_r <= row_bytes_r * height[12:0];
    end
end
wire [31:0] pixel_bytes = {4'd0, pix_bytes_r};
// 【时序收敛 2026-10-27】和文件大小有关的三项比较提前打两拍：像素偏移在文件头第 13 字节、宽高在第 25 字节就收齐了，
// 到第 34 字节校验时这些寄存器早已稳定（一个字节要好几十拍），结果和原来一拍算完相同
reg [31:0] size_left;               // 文件大小 - 像素偏移
reg        off_ok;                  // 54 <= 像素偏移 < 文件大小
reg        left_ok;                 // 像素区装得下
always @(posedge clk or posedge rst) begin
    if (rst) begin
        size_left <= 32'd0;
        off_ok    <= 1'b0;
        left_ok   <= 1'b0;
    end else begin
        size_left <= cur_size - pixel_offset;
        off_ok    <= (pixel_offset >= 32'd54) && (pixel_offset < cur_size);
        left_ok   <= (size_left >= pixel_bytes);
    end
end
// 文件长度用目录项里的大小（比 BMP 头里的 file_size 字段更可靠）
wire header_match = h_b && h_m &&
                    (d14_ge40 || d15_nz || d16_nz || d17_nz) &&
                    dims_ok &&
                    p26_1 && p27_0 &&
                    c28_24 && c29_0 &&
                    z30 && z31 && z32 && z33 &&
                    off_ok && left_ok;

// ---------------------------------------------------------------------------
// 像素拼装：BMP 按 B、G、R 顺序存放，和原 bmp_read 输出格式一致
// ---------------------------------------------------------------------------
// 【时序修复】校验结果和像素区间在读完文件头（偏移 34）后锁存，
// 像素通路只用寄存器比较，不再走一长串减法/比较组合逻辑
reg        hdr_ok;
reg [31:0] pix_end;           // pixel_offset + 像素字节数
always @(posedge clk or posedge rst) begin
    if (rst) begin
        hdr_ok  <= 1'b0;
        pix_end <= 32'd0;
    end else if (str_start) begin
        hdr_ok  <= 1'b0;
    end else if (str_valid && (str_off == 32'd34)) begin
        hdr_ok  <= header_match;
        pix_end <= pixel_offset + pixel_bytes;
    end
end

wire pix_byte = str_valid && (state == ST_LOAD_DATA) && hdr_ok &&
                (str_off >= pixel_offset) && (str_off < pix_end);
reg [27:0] pix_byte_cnt;     // 收到的像素区字节数（含行尾填充），判断文件是否被截断
reg        hdr_bad;          // 文件头已读完但校验失败
reg        scl_start;        // 文件头校验通过：启动缩放器

always @(posedge clk or posedge rst) begin
    if (rst) begin
        pix_byte_cnt <= 28'd0;
        hdr_bad      <= 1'b0;
        scl_start    <= 1'b0;
    end else if (str_start) begin
        pix_byte_cnt <= 28'd0;
        hdr_bad      <= 1'b0;
        scl_start    <= 1'b0;
    end else begin
        scl_start <= str_valid && (str_off == 32'd34) && header_match && (state == ST_LOAD_DATA);
        if (str_valid && (str_off == 32'd54) && !hdr_ok)
            hdr_bad <= 1'b1;
        if (pix_byte)
            pix_byte_cnt <= pix_byte_cnt + 28'd1;
    end
end

// 像素字节 → 缩放器 → 640×480 像素流（BMP 的 B、G、R 拼装也在缩放器里做）
wire scl_done;
wire scl_ovf;
bmp_scaler #(
    .OUT_W       (640),
    .OUT_H       (480),
    .KEEP_ASPECT (0)               // 1 = 保持宽高比补黑边，0 = 拉伸铺满（2026-10 改为铺满：任意尺寸都铺满 640×480，非 4:3 会变形）
) u_scaler (
    .clk       (clk),
    .rst       (rst),
    .clear     (!((state == ST_LOAD_DATA) || (state == ST_LOAD_FLUSH))),
    .start     (scl_start),
    .src_w     (width[12:0]),
    .src_h     (height[12:0]),
    .in_valid  (pix_byte),
    .in_byte   (str_byte),
    .in_pause  (scl_pause),
    .out_valid (bmp_data_wr_en),
    .out_data  (bmp_data),
    .done      (scl_done),
    .overflow  (scl_ovf)
);

// write_req_ack 来自 ext_mem_clk 域，打两拍同步
reg write_req_ack_d1;
reg write_req_ack_d2;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        write_req_ack_d1 <= 1'b0;
        write_req_ack_d2 <= 1'b0;
    end else begin
        write_req_ack_d1 <= write_req_ack;
        write_req_ack_d2 <= write_req_ack_d1;
    end
end

// 单扇区读超时：扫描或加载期间，每读完一个扇区清零
reg [9:0]  tmo_cnt;          // 毫秒
wire       tmo = (tmo_cnt >= SECTOR_TIMEOUT_MS);
always @(posedge clk or posedge rst) begin
    if (rst)
        tmo_cnt <= 10'd0;
    else if (((state == ST_SCAN) || ((state == ST_LOAD_DATA) && !scl_hold) || (state == ST_LOAD_FLUSH) ||
              ((state == ST_MUSIC) && !music_hold) || probing)
             && !sd_sec_read_end) begin
        if (ms_tick && !tmo)
            tmo_cnt <= tmo_cnt + 10'd1;
    end else
        tmo_cnt <= 10'd0;
end

// 【拔卡恢复】音乐暂停时缓冲一直满、不读卡，超过 1 秒就自己巡检一次（空闲时的巡检由上层发 probe_start）
reg [10:0] mprb_cnt;         // 毫秒
always @(posedge clk or posedge rst) begin
    if (rst)
        mprb_cnt <= 11'd0;
    else if ((state == ST_MUSIC) && music_hold && !sec_busy)
        mprb_cnt <= ((mprb_cnt >= PROBE_MS) || !ms_tick) ? mprb_cnt : (mprb_cnt + 11'd1);
    else
        mprb_cnt <= 11'd0;
end

// ---------------------------------------------------------------------------
// 主状态机
// ---------------------------------------------------------------------------
reg [1:0] report_idx;
reg       prb_ret;          // 【拔卡恢复】巡检完回到 1 = 音乐 0 = 空闲

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        load_error        <= 1'b0;
        bmp_error         <= ERR_NONE;
        scn_start         <= 1'b0;
        str_start         <= 1'b0;
        kill_scan         <= 1'b0;
        kill_load         <= 1'b0;
        cur_cluster       <= 32'd0;
        cur_size          <= 32'd0;
        report_idx        <= 2'd0;
        kill_probe        <= 1'b0;
        prb_req           <= 1'b0;
        prb_ret           <= 1'b0;
        card_lost         <= 1'b0;
    end else if (!sd_init_done) begin
        state            <= ST_IDLE;
        state_code       <= 4'd0;
        write_req        <= 1'b0;
        scan_done        <= 1'b0;
        scan_found_valid <= 1'b0;
        scan_found_total <= 3'd0;
        load_error       <= 1'b0;
        scn_start        <= 1'b0;
        str_start        <= 1'b0;
        kill_scan        <= 1'b0;
        kill_load        <= 1'b1;          // 【拔卡恢复】卡没初始化好时流读器和适配器一直复位（重新初始化时清掉卡住的读请求）
        kill_probe       <= 1'b0;
        prb_req          <= 1'b0;
        card_lost        <= 1'b0;
    end else begin
        scan_found_valid <= 1'b0;
        load_error       <= 1'b0;
        scn_start        <= 1'b0;
        str_start        <= 1'b0;
        kill_scan        <= 1'b0;
        kill_load        <= 1'b0;
        kill_probe       <= 1'b0;
        prb_req          <= 1'b0;
        card_lost        <= 1'b0;

        if (load_abort && use_streamer) begin
            // 上层 1 秒整体超时：立即中止本次加载，保留文件表
            state     <= ST_IDLE;
            write_req <= 1'b0;
            kill_load <= 1'b1;
            bmp_error <= ERR_TIMEOUT;
        end else begin
            case (state)
                ST_IDLE: begin
                    state_code <= 4'd1;
                    write_req  <= 1'b0;
                    if (scan_start) begin
                        scan_done        <= 1'b0;
                        scan_found_total <= 3'd0;
                        scn_start        <= 1'b1;
                        state            <= ST_SCAN;
                    end else if (music_start && mus_valid) begin
                        // 开始循环读背景音乐
                        cur_cluster <= mus_clu;
                        cur_size    <= mus_size;
                        str_start   <= 1'b1;
                        state       <= ST_MUSIC;
                    end else if (load_start) begin
                        if (load_sector[2] ? !emg_valid : !res_valid[load_sector[1:0]]) begin
                            load_error <= 1'b1;
                            bmp_error  <= ERR_FS;
                        end else begin
                            cur_cluster <= load_sector[2] ? emg_clu  : clu_lut(load_sector[1:0]);
                            cur_size    <= load_sector[2] ? emg_size : size_lut(load_sector[1:0]);
                            write_req   <= 1'b1;
                            state       <= ST_LOAD_WAIT;
                        end
                    end else if (probe_start && !sec_busy) begin
                        // 【拔卡恢复】空闲巡检
                        prb_ret <= 1'b0;
                        prb_req <= 1'b1;
                        state   <= ST_PROBE;
                    end
                end

                ST_SCAN: begin
                    state_code <= 4'd2;
                    if (scn_done_p) begin
                        // 扫描器错误码细分到数码管：
                        //   7 = LBA0/引导扇区没有 55AA 签名
                        //   8 = 分区类型或 BPB 不支持（不是 FAT32）
                        //   4 = 文件系统正常，但根目录第一个扇区里没找到 PIC1~4.BMP
                        // 0x22 且找到部分文件时不报错，用找到的几张继续播放
                        if (scn_err == 8'h20)
                            bmp_error <= 4'd7;
                        else if (scn_err == 8'h21)
                            bmp_error <= 4'd8;
                        else if (res_valid == 4'd0)
                            bmp_error <= ERR_FS;
                        else
                            bmp_error <= ERR_NONE;   // 【拔卡恢复】重新扫描成功，清掉拔卡时留下的超时错误
                        report_idx <= 2'd0;
                        state      <= ST_REPORT;
                    end else if (tmo) begin
                        kill_scan <= 1'b1;
                        bmp_error <= ERR_TIMEOUT;
                        scan_done <= 1'b1;
                        card_lost <= 1'b1;   // 【拔卡恢复】
                        state     <= ST_IDLE;
                    end
                end

                ST_REPORT: begin
                    state_code <= 4'd2;
                    if (res_valid[report_idx]) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= {30'd0, report_idx};
                        scan_found_total  <= scan_found_total + 3'd1;
                    end
                    report_idx <= report_idx + 2'd1;
                    if (report_idx == 2'd3) begin
                        scan_done <= 1'b1;
                        state     <= ST_IDLE;
                    end
                end

                ST_LOAD_WAIT: begin
                    state_code <= 4'd3;
                    if (write_req_ack_d2) begin
                        write_req <= 1'b0;
                        str_start <= 1'b1;
                        state     <= ST_LOAD_DATA;
                    end
                end

                ST_LOAD_DATA: begin
                    state_code <= 4'd4;
                    if (str_done_p) begin
                        state <= ST_IDLE;
                        if (str_err != 8'd0) begin
                            load_error <= 1'b1;
                            bmp_error  <= ERR_FAT;
                        end else if (!hdr_ok) begin
                            load_error <= 1'b1;
                            bmp_error  <= ERR_HEADER;
                        end else if (pix_byte_cnt < pix_bytes_r) begin
                            load_error <= 1'b1;
                            bmp_error  <= ERR_TRUNCATED;
                        end else begin
                            state      <= ST_LOAD_FLUSH;   // 等缩放器发完最后几行
                        end
                    end else if (hdr_bad && sd_sec_read_end) begin
                        // 文件头不合格：在扇区边界停止，不必把整个文件读完
                        kill_load  <= 1'b1;
                        load_error <= 1'b1;
                        bmp_error  <= ERR_HEADER;
                        state      <= ST_IDLE;
                    end else if (tmo) begin
                        kill_load  <= 1'b1;
                        load_error <= 1'b1;
                        bmp_error  <= ERR_TIMEOUT;
                        card_lost  <= 1'b1;   // 【拔卡恢复】
                        state      <= ST_IDLE;
                    end
                end

                ST_LOAD_FLUSH: begin
                    // 最多十几毫秒（640×480 像素，4 拍一个）
                    state_code <= 4'd4;
                    if (scl_ovf) begin
                        load_error <= 1'b1;
                        bmp_error  <= ERR_TRUNCATED;
                        state      <= ST_IDLE;
                    end else if (scl_done) begin
                        bmp_error  <= ERR_NONE;
                        state      <= ST_IDLE;
                    end else if (tmo) begin
                        load_error <= 1'b1;
                        bmp_error  <= ERR_TIMEOUT;
                        state      <= ST_IDLE;
                    end
                end

                ST_MUSIC: begin
                    // 数码管状态位显示 5 = 正在播放背景音乐
                    state_code <= 4'd5;
                    if (str_done_p) begin
                        if (str_err != 8'd0) begin
                            state     <= ST_IDLE;
                            bmp_error <= ERR_FAT;
                        end else begin
                            str_start <= 1'b1;        // 播完从头再读，循环播放
                        end
                    end else if (tmo) begin
                        kill_load <= 1'b1;
                        bmp_error <= ERR_TIMEOUT;
                        card_lost <= 1'b1;    // 【拔卡恢复】
                        state     <= ST_IDLE;
                    end else if (mprb_cnt >= PROBE_MS) begin
                        // 【拔卡恢复】音乐暂停中、好久没读卡：巡检一次，完了回来接着读（流读器原地停着）
                        prb_ret <= 1'b1;
                        prb_req <= 1'b1;
                        state   <= ST_PROBE;
                    end
                end

                ST_PROBE: begin
                    // 【拔卡恢复】读 0 号扇区（字节不送给扫描器和流读器），读完就回去；超时 = 卡没了
                    if (sd_sec_read_end) begin
                        state <= prb_ret ? ST_MUSIC : ST_IDLE;
                    end else if (tmo) begin
                        kill_probe <= 1'b1;
                        kill_load  <= prb_ret;
                        card_lost  <= 1'b1;
                        state      <= ST_IDLE;
                    end
                end

                default: begin
                    state      <= ST_IDLE;
                    state_code <= 4'd1;
                    write_req  <= 1'b0;
                end
            endcase
        end
    end
end

endmodule
