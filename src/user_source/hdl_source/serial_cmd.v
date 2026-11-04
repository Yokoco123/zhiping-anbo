`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// 【串口指令】电脑上的普通串口助手（板载 CH340，921600 8N1，UTF-8）直接打字控制信息屏：
//   口令 空格 指令，例如   8848 通知 寻物启事：一卡通遗失于图书馆二楼
//                          8848 撤销通知 / 字幕开 / 字幕关 / 音乐开 / 音乐关 / 下一张 / 上一张 / 帮助 / 装字库
//   一条指令以回车 / 换行结束，或者停顿 IDLE_MS（串口助手不加换行时）。口令、关键字、回复文字都在
//   subtitle/cmd.txt（gen_cmd.ps1 生成 cmd_rom.v），回复是 UTF-8 中文，串口助手里直接能看。
//   口令不对：回复“口令错误”，并给开机画面模块一个 reject（右上角红框“非法指令已拒绝”）
//
// 通知文字的字形：板上用户 Flash U33 里的宋体 16 像素字库（notice_tool/gen_font.ps1 生成 FONT.BIN），
//   按 Unicode 编码直接算地址（见 gidx），每个字 32 字节 = 16 列 × 16 位，ASCII 只用前 8 列。
//   收到通知：逐字 UTF-8 解码 → 读 Flash 字形 → 写进通知 RAM（2 块 × 1024 列，写不在显示的那块，写完才切换）
// 字库安装（只需一次，断电不丢）：发“口令 装字库” → 擦除字库区 → 回复 READY → 串口助手发送 FONT.BIN 文件
//   → 每收满 256 字节编一页 → 收到最后的标记页后核对 CRC32 → 写标记页 → 从 Flash 读回全部数据再算一遍 CRC32
//   上电时也读回校验一遍（约 0.5 秒），通过才算“已安装”（font_status 给开机自检页）
// Flash 和参数存储（param_store）共用：要用时 fl_req，等 fl_grant 才动引脚。
// 【三级应急】口令 应急1/应急2/应急3 [火灾|地震|治安|故障] [内容]：一级紧急撤离 / 二级就地避险 / 三级区域警戒；口令 解除。
//   只写类型不写内容：显示这一类的提示语；类型也不写：显示这一级的提示语（都在 cmd.txt）。
//   文字用同一个字库画进“应急文字 RAM”（和通知分开，解除后通知照常），每行 LINE_W 列自动换行，最多 3 行，显示时放大 2 倍。
//   等级：SW1 打开 = 一级（硬件强制，串口解除不了）；否则用串口设的等级。alarm_lvl 给 sd_card_bmp4（只是串口设的），
//   v_alm 给显示（已经算上 SW1）。三级时普通通知暂停显示（v_on = 0）。
// 【启事】口令 寻人 / 寻物 / 招领（失物招领）内容：最多 4 条，存进“启事 RAM”（qram，每条 512 字节：类别、字节数、UTF-8 原文），
//   每次发布 / 撤销都把整块写进 Flash 的 Q_ADDR 扇区（最后 4 字节是标记，写完才算数），上电读回来，断电不丢。
//   发布后 q_new 通知 sd_card_bmp4 马上插播；轮到哪条，sd_card_bmp4 发 pg_req，这里用字库把原文画进“启事页缓冲”
//   （2 块 × 2048 列，每行 LINE_W 列自动换行，最多 4 行；写的是没在显示的那块），画完 pg_done，切页时直接换块。
//   【自动字号】先按大字（显示时放大 2 倍）排；放不下就按小字（原大 16 像素）重排：不带照片每行 576 列（36 字），
//   带照片每行 224 列（14 字），最多 2040 列（约 127 个汉字）。pv_meta 最高位 = 小字。
//   口令 启事 = 串口回复现有的启事原文；撤销1~4 / 撤销全部。
//   收指令不再要求状态机空闲：画启事页 / 存 Flash 的时候串口发来的字也照收，处理完再解析。
// 【按键改造】一级应急也可以由按键（k_alarm：Key4 长按，进入 / 解除）和干接点（x_alarm：扩展口接地，只进入）触发，
//   和串口改的是同一个等级（谁后操作听谁的）；消音（KEY3 短按 k_mute 或 口令 消音）只关声音，画面告警保持，等级一变就恢复声音。
//   字幕开 / 字幕关 / 轮播开 / 轮播关 只发单拍给 sd_card_bmp4，开关状态在那里（和按键共用，掉电保存）。
// 【串口照片】口令 照片n（n = 第几条启事，这一条要已经发布）：流程和装字库一样（擦 Flash → READY → 串口助手发 PHOTO.BIN → 逐页编程
//   → 标记页核对 CRC → 读回校验），照片存在 Flash 0x200000 + (n-1) × 1MB。PHOTO.BIN 是电脑工具 notice_tool/gen_photo.ps1 生成的
//   720×640 原图（RGB565，按 2×2 一组排好），装好后启事类别字节第 4 位置 1（存在启事扇区里，撤销 / 换成新启事就自动清掉）。
//   画这一条的启事页时，文字画好后从 Flash 读照片，硬件 2×2 平均缩成 360×320，经 sd_card_bmp4 写进 SDRAM 的照片缓冲
//   （ph_need / ph_grant 和 SD 卡载图错开；两块缓冲和启事页缓冲一一对应），启事页左边显示照片、右边文字。
// 【自定义字幕】口令 字幕n 内容（n = 第几张图 1~4）：把这张图下面的滚动字幕换成这句话；口令 字幕n（不写内容）= 恢复默认字幕。
//   原文存进启事 RAM 的后一半（qram[1024..]，格式和启事一样：[0] = 1 有效、[1] 字节数、[2..] UTF-8），整块写进 Flash 的
//   S_ADDR 扇区（标记 "SB01"），上电读回，断电不丢。
//   不另占显示 RAM：字幕条显示通知时不显示图片字幕，所以没有通知时，正在显示的图（v_shown）有自定义字幕，就用字库
//   把它画进通知 RAM（写不在显示的那块，画完再切），v_cs = 1 告诉字幕条从通知 RAM 读、按普通字幕的样式显示。
//   换图后重新画（约 2ms，字幕本来就从右端重新进入，看不出来）；来了通知就让给通知，撤销通知后再画回来。
// 时钟：sd_card_clk（75MHz）。通知 RAM 的读口和给显示的状态在 video_clk 域（vclk），状态打三拍、连续两拍相同才用。
// -----------------------------------------------------------------------------
module serial_cmd #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer BAUD        = 921_600,    // 【三级应急】串口提速：装字库约 8 秒（115200 要 1 分钟）
    parameter integer LINE_W      = 288,        // 【三级应急】应急文字每行列数（18 个汉字，放大 2 倍后 576 像素）
    parameter integer FONT_PAGES  = 2700,       // FONT.BIN 数据部分的页数（256 字节一页），后面再跟 1 页标记
    parameter [31:0]  FONT_GLYPHS = 32'd21599,
    parameter integer IDLE_MS     = 20,         // 停顿这么久算一条指令结束
    parameter integer FIRST_MS    = 60000,      // READY 之后等文件开始
    parameter integer BYTE_MS     = 2000,       // 文件传输中两个字节最多隔多久
    parameter integer BUSY_MS     = 3000,       // 擦除 / 编程查忙的超时
    parameter integer PH_PAGES    = 3600,       // 【串口照片】PHOTO.BIN 数据部分的页数：720×640×2 字节 = 3600 页，后面再跟 1 页标记
    parameter integer PH_ROWS     = 320         // 【串口照片】照片缩小后的行数（仿真里可以改小）
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        ms_tick,
    input  wire        uart_rx,
    output wire        uart_tx,
    input  wire        emerg_mode,              // 应急接管（SW1 或串口一级 / 二级）：音乐、翻页指令不执行
    input  wire        sw1,                     // 【三级应急】硬件强制一级（现在不用，接 0）
    input  wire        k_alarm,                 // 【按键改造】单拍：Key4 长按 —— 没有应急就进一级，有应急就解除
    input  wire        x_alarm,                 // 【按键改造】单拍：干接点闭合 —— 进一级（已经是一级就不动）
    input  wire        k_mute,                  // 【按键改造】单拍：应急时 KEY3 短按 —— 消音
    // Flash（经 param_store 仲裁）
    output reg         fl_req,
    input  wire        fl_grant,
    input  wire        fl_off,                  // 芯片不认识：字库不能用
    output reg         fl_cs_n,
    output reg         fl_sclk,
    output reg         fl_mosi,
    input  wire        fl_miso,
    // 给 sd_card_bmp4（单拍）
    output reg         music_play,
    output reg         music_stop,
    output reg         img_next,
    output reg         img_prev,
    output reg         osd_set,                 // 【按键改造】单拍：字幕开 / 字幕关 / 轮播开 / 轮播关
    output reg         osd_clr,
    output reg         auto_set,
    output reg         auto_clr,
    output reg         wave_set,                // 【波形开关】单拍：波形开 / 波形关
    output reg         wave_clr,
    output reg         res_set,                 // 【分辨率显示】单拍：分辨率开 / 分辨率关
    output reg         res_clr,
    output reg         muted,                   // 【按键改造】已消音（sd_card_clk 域，给数码管）
    output reg  [1:0]  font_status,             // 0 检查中 1 已安装 2 未安装 / 损坏 3 Flash 不可用
    output reg  [1:0]  alarm_lvl,               // 【三级应急】串口设的等级：0 无 1 紧急撤离 2 就地避险 3 区域警戒（不含 SW1）
    // 【启事】和 sd_card_bmp4 的轮播调度（sd_card_clk 域）
    output reg  [3:0]  q_mask,                  // 哪几条有启事
    output reg         q_new,                   // 单拍：刚发布了第 q_new_slot 条，要马上插播
    output reg  [1:0]  q_new_slot,
    input  wire        pg_req,                  // 单拍：把第 pg_slot 条画进启事页缓冲 pg_buf
    input  wire [1:0]  pg_slot,
    input  wire        pg_buf,
    output reg         pg_done,                 // 单拍：画好了
    // 显示（video_clk 域）
    input  wire        vclk,
    input  wire        vrst_n,
    input  wire [9:0]  rd_col,
    output reg  [15:0] rd_bits,
    output wire        v_on,
    output wire [10:0] v_len,
    output reg         v_new,                   // 单拍：换了通知（字幕条从右端重新进入）
    output reg         v_reject,                // 单拍：口令错误
    output reg         v_sub_off,               // 1 = 串口关掉了每张图的字幕
    input  wire [3:0]  v_shown,                 // 【自定义字幕】正在显示第几张图（1~4，0 = 还没出图）
    output reg         v_cs,                    // 【自定义字幕】1 = 字幕条从通知 RAM 读这张图的自定义字幕（普通字幕样式，长度 v_len）
    // 【三级应急】（video_clk 域）
    input  wire [9:0]  a_col,                   // 应急文字 RAM 的列（有应急文字时 rd_bits 读的是它）
    output reg  [1:0]  v_alm,                   // 实际等级（SW1 打开 = 1）
    output reg  [9:0]  v_alen,                  // 应急文字列数，0 = 没有文字
    output reg         v_mute,                  // 【按键改造】已消音（video_clk 域，给警报声）
    // 【启事】启事页（video_clk 域）
    input  wire        pv_sel,                  // 1 = 正在显示启事页：读口给它（没有应急文字时），底部通知条不显示
    input  wire        pv_buf,                  // 显示的是哪块缓冲
    input  wire [10:0] pv_col,
    output wire [20:0] pv_meta,                 // 这块缓冲画的是什么：{小字, 有照片, 类别 2 位, 列数 11 位, 第几条 3 位, 共几条 3 位}
    // 【串口照片】照片写 SDRAM（sd_card_clk 域，经 sd_card_bmp4 接到 frame_read_write 的写口）
    output reg         ph_need,                 // 要用 SDRAM 写口（从等许可到写完一直是 1）
    input  wire        ph_grant,                // sd_card_bmp4：没在载图，写口给照片（ph_need 落下才收回）
    output reg         ph_wreq,                 // 写请求（电平，等到 ph_wack）
    input  wire        ph_wack,                 // 写请求应答（已同步）
    input  wire        ph_wfin,                 // 单拍：SDRAM 那边写完了（已同步）
    output reg         ph_we,
    output reg  [23:0] ph_px,                   // {R, G, B}
    output wire        ph_pbuf                  // 写哪块照片缓冲（= 正在画的启事页缓冲）
);

localparam integer BIT_CYC    = (CLK_FREQ_HZ + BAUD / 2) / BAUD;  // 四舍五入：75MHz / 921600 = 81（实际 925926 bps，误差 +0.47%）
localparam [23:0]  MARK_ADDR  = FONT_PAGES * 256;
localparam [19:0]  DATA_BYTES = FONT_PAGES * 256;
localparam [3:0]   NBLK       = (FONT_PAGES * 256 + 256 + 65535) / 65536;   // 要擦的 64KB 块数
localparam [19:0]  FILE_BYTES = FONT_PAGES * 256 + 256;
localparam [11:0]  FT_MKPG    = FONT_PAGES;                 // 字库标记页是第几页
// 【串口照片】
localparam [19:0]  PH_BYTES   = PH_PAGES * 256;
localparam [19:0]  PH_FILE    = PH_PAGES * 256 + 256;
localparam [11:0]  PH_MKPG    = PH_PAGES;
localparam [3:0]   PH_NBLK    = (PH_PAGES * 256 + 256 + 65535) / 65536;     // 15 块 = 960KB
localparam [8:0]   PH_LW      = 9'd112;                     // 有照片时文字每行 112 列（7 个汉字）
localparam [10:0]  PH_COLS    = 11'd672;                    // 最多 6 行
localparam [9:0]   PX0        = 10'd16;                     // 照片在屏上的左边（宽 360），上边 112（高 320），见 notice_page
localparam [9:0]   PXW        = 10'd360;

// cmd_rom 里字符串编号（gen_cmd.ps1 固定顺序）
localparam [6:0] K_PIN = 7'd0, K_NOTICE = 7'd1, K_CLEAR = 7'd2, K_SUBON = 7'd3, K_SUBOFF = 7'd4, K_MUSON = 7'd5,
                 K_MUSOFF = 7'd6, K_NEXT = 7'd7, K_PREV = 7'd8, K_HELP = 7'd9, K_FONT = 7'd10,
                 K_ALM1 = 7'd11, K_ALM2 = 7'd12, K_ALM3 = 7'd13, K_ALMCLR = 7'd14,
                 K_QP = 7'd15, K_QT = 7'd16, K_QF = 7'd17, K_QF2 = 7'd18,                 // 【启事】寻人 寻物 招领 失物招领
                 K_QLIST = 7'd19, K_QDALL = 7'd20, K_QDEL = 7'd21,                        // 启事 撤销全部 撤销
                 K_AUTOON = 7'd22, K_AUTOOFF = 7'd23, K_MUTE = 7'd24;                      // 【按键改造】轮播开 轮播关 消音；关键字到 K_MUTE 为止
localparam [6:0] K_TY_FIRE = 7'd25, K_TY_FAULT = 7'd28;                          // 应急类型 25~28
localparam [6:0] K_TP_FIRE = 7'd29, K_TP_L1 = 7'd33;                             // 类型提示语 29~32，等级提示语 33~35
localparam [6:0] R_OK_NOTICE = 7'd36, R_OK_TRUNC = 7'd37, R_OK_CLEAR = 7'd38, R_OK_SUBON = 7'd39, R_OK_SUBOFF = 7'd40,
                 R_OK_MUSON = 7'd41, R_OK_MUSOFF = 7'd42, R_OK_NEXT = 7'd43, R_OK_PREV = 7'd44, R_HELP = 7'd45,
                 R_ERR_PIN = 7'd46, R_ERR_UNKNOWN = 7'd47, R_ERR_EMPTY = 7'd48, R_ERR_NOFONT = 7'd49, R_ERR_FLASH = 7'd50,
                 R_ERR_EMERG = 7'd51, R_FONT_READY = 7'd52, R_FONT_OK = 7'd53, R_FONT_BAD = 7'd54, R_FONT_BROKEN = 7'd55,
                 R_OK_ALM1 = 7'd56, R_OK_ALMCLR = 7'd59, R_OK_ALMSW1 = 7'd60, R_OK_ALMNOTXT = 7'd61;   // 56~58 一~三级
localparam [6:0] R_OK_Q1 = 7'd62, R_OK_QLONG = 7'd66, R_ERR_QFULL = 7'd67, R_OK_QDEL = 7'd68,     // 【启事】62~65 第 1~4 条
                 R_OK_QDALL = 7'd69, R_ERR_QNONE = 7'd70, R_ERR_QSAVE = 7'd71, R_LS_HEAD = 7'd72,
                 R_LS_N1 = 7'd73, R_LS_T1 = 7'd77, R_LS_EMPTY = 7'd80, R_LS_EOL = 7'd81;          // 列表片段：编号 73~76，类别 77~79
localparam [6:0] R_OK_AUTOON = 7'd82, R_OK_AUTOOFF = 7'd83, R_OK_MUTE = 7'd84, R_ERR_NOALM = 7'd85;   // 【按键改造】
localparam [6:0] K_PHOTO = 7'd86, R_PH_READY = 7'd87, R_PH_OK = 7'd88, R_PH_BAD = 7'd89, R_PH_BROKEN = 7'd90; // 【串口照片】
localparam [6:0] K_SUB = 7'd91, R_SUB_OK = 7'd92, R_SUB_LONG = 7'd93, R_SUB_DEF = 7'd94, R_SUB_BADN = 7'd95;   // 【自定义字幕】
localparam [6:0] K_WAVEON = 7'd96, K_WAVEOFF = 7'd97, K_RESON = 7'd98, K_RESOFF = 7'd99,             // 【波形开关】【分辨率显示】
                 R_OK_WAVEON = 7'd100, R_OK_WAVEOFF = 7'd101, R_OK_RESON = 7'd102, R_OK_RESOFF = 7'd103;
localparam [10:0] ALM_COLS = LINE_W * 3;                                         // 应急文字最多 3 行
// 【启事】
localparam [10:0] PG_COLS  = LINE_W * 4;                                         // 启事页文字最多 4 行
localparam [7:0]  Q_MAX    = 8'd250;                                             // 【自定义字幕】每条最多存 250 字节
localparam [8:0]  Q_MAXN   = 9'd500;                                             // 【自动字号】每条启事最多存 500 字节（小字画满约 381 字节）
localparam [11:0] PS_COLS  = 12'd2040;                                           // 【自动字号】小字最多 2040 列（启事页缓冲 2048 列）
localparam [23:0] Q_ADDR   = 24'h100000;                                         // Flash 里的启事扇区（字库在 0~0xAFFFF，参数在 0x7FE000）
localparam [23:0] S_ADDR   = 24'h101000;                                         // 【自定义字幕】紧挨着的下一个 4KB 扇区
localparam [1:0]  T_NTC = 2'd0, T_ALM = 2'd1, T_PAGE = 2'd2;                     // 画到哪：通知 / 应急文字 / 启事页

// ======================= 串口接收 =======================
reg  [2:0] rx_s;
always @(posedge clk or posedge rst)
    if (rst) rx_s <= 3'b111;
    else     rx_s <= {rx_s[1:0], uart_rx};
wire rx = rx_s[2];
reg        rx_busy;
reg  [9:0] rx_cnt;
reg  [3:0] rx_bit;
reg  [7:0] rx_sh;
reg        rx_valid;
reg  [7:0] rx_byte;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        rx_busy <= 1'b0; rx_cnt <= 10'd0; rx_bit <= 4'd0; rx_sh <= 8'd0; rx_valid <= 1'b0; rx_byte <= 8'd0;
    end else begin
        rx_valid <= 1'b0;
        if (!rx_busy) begin
            if (!rx) begin rx_busy <= 1'b1; rx_cnt <= 10'd0; rx_bit <= 4'd0; end
        end else if (rx_cnt == ((rx_bit == 4'd0) ? (BIT_CYC / 2 - 1) : (BIT_CYC - 1))) begin
            rx_cnt <= 10'd0;
            if (rx_bit == 4'd0) begin
                if (rx) rx_busy <= 1'b0;
                else    rx_bit  <= 4'd1;
            end else if (rx_bit == 4'd9) begin
                rx_busy <= 1'b0;
                if (rx) begin rx_valid <= 1'b1; rx_byte <= rx_sh; end
            end else begin
                rx_sh  <= {rx, rx_sh[7:1]};
                rx_bit <= rx_bit + 4'd1;
            end
        end else
            rx_cnt <= rx_cnt + 10'd1;
    end
end

// ======================= 字符串 ROM（两个读口：A 比较关键字，B 发回复） =======================
reg  [6:0]  csid;                   // 正在比较 / 要回复的字符串
wire [11:0] s_start;
wire [7:0]  s_len;
reg  [11:0] ra_a, ra_b;
wire [7:0] rom_a, rom_b;
cmd_rom u_rom (.clk(clk), .addr_a(ra_a), .data_a(rom_a), .addr_b(ra_b), .data_b(rom_b),
               .sid(csid), .s_start(s_start), .s_len(s_len));

// ======================= 【启事】启事 RAM（4 条 × 256 字节） =======================
// 每条：[0] 类别（0 空 1 寻人 2 寻物 3 招领）[1] 字节数 [2..] UTF-8 原文；最后 4 字节（第 4 条的 252~255）是 Flash 标记 "QS01"
// 一个读口，三个用的地方不会同时用：Flash 页编程（存）、串口发原文（列表）、解析 / 渲染时按 p_ra 读
// 【自动字号】每条 512 字节（0~2047），[0] 的第 5 位是字节数的第 8 位；标记 "QS02" 在 2044~2047
// 【自定义字幕】2048~3071（qb = 1）放 4 张图的自定义字幕，每条 256 字节（[0] = 1 有效），标记 "SB01"
reg  [7:0] qram [0:3071] /* fehdl force_ram=1, ram_style="bram" */;
reg        qb;                      // 【自定义字幕】读写 / 存 Flash 的是哪一半：0 启事，1 字幕
reg        q_we;
reg [11:0] q_wa;
reg  [7:0] q_wd;
reg  [1:0] q_slot;                  // 读第几条（渲染 / 发布）
reg        e_q;                     // 页编程的数据从启事 RAM 取
reg  [2:0] q_pg;                    // 编程第几页（启事 8 页，字幕 4 页）
reg        txq;                     // 串口正在发启事原文
reg  [1:0] txq_slot;
reg  [8:0] txq_a, txq_end;
reg  [7:0] q_rd, q_q;
wire       e_prog;                  // SPI 引擎在编程（声明在这里，下面 SPI 引擎里赋值）
wire [7:0] e_ra;
reg  [8:0] p_ra;                    // 解析 / 核对标记页时读 lbuf 的地址（渲染启事时也用它读启事 RAM）
wire [11:0] q_ra = (e_prog && e_q) ? (qb ? {2'b10, q_pg[1:0], e_ra} : {1'b0, q_pg, e_ra}) :
                   txq ? {1'b0, txq_slot, txq_a} : (qb ? {2'b10, q_slot, p_ra[7:0]} : {1'b0, q_slot, p_ra});
always @(posedge clk) begin
    if (q_we) qram[q_wa] <= q_wd;
    q_rd <= qram[q_ra];
    q_q  <= q_rd;                   // 和 lb_q 一样再打一拍
end

// ======================= 串口发送（回复，从 ROM 口 B 读，遇到 0 停；【启事】或者从启事 RAM 发一条原文） =======================
reg        tx_run, tx_busy, tx_line;
reg  [1:0] tx_wait;
reg  [9:0] tx_cnt;
reg  [3:0] tx_bit;
reg  [9:0] tx_sh;
reg        reply_go;
reg  [11:0] reply_at;
reg        qtx_go;                  // 【启事】发第 qtx_slot 条的原文（qtx_len 字节）
reg  [1:0] qtx_slot;
reg  [8:0] qtx_len;
assign uart_tx = tx_line;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        tx_run <= 1'b0; tx_busy <= 1'b0; tx_line <= 1'b1; tx_wait <= 2'd0; tx_cnt <= 10'd0; tx_bit <= 4'd0;
        tx_sh <= 10'h3FF; ra_b <= 12'd0; txq <= 1'b0; txq_slot <= 2'd0; txq_a <= 9'd0; txq_end <= 9'd0;
    end else begin
        if (tx_wait != 2'd0) tx_wait <= tx_wait - 2'd1;
        if (reply_go) begin
            ra_b    <= reply_at;
            txq     <= 1'b0;
            tx_run  <= 1'b1;
            tx_wait <= 2'd2;
        end else if (qtx_go) begin
            txq      <= 1'b1;
            txq_slot <= qtx_slot;
            txq_a    <= 9'd2;
            txq_end  <= qtx_len + 9'd2;
            tx_run   <= 1'b1;
            tx_wait  <= 2'd2;
        end else if (tx_run && !tx_busy && (tx_wait == 2'd0)) begin
            if (txq ? (txq_a == txq_end) : (rom_b == 8'h00)) begin
                tx_run <= 1'b0;
                txq    <= 1'b0;
            end else begin
                tx_sh   <= {1'b1, (txq ? q_rd : rom_b), 1'b0};
                tx_busy <= 1'b1;
                tx_cnt  <= 10'd0;
                tx_bit  <= 4'd0;
                if (txq) txq_a <= txq_a + 9'd1;
                else     ra_b  <= ra_b + 12'd1;
                tx_wait <= 2'd2;
            end
        end
        if (tx_busy) begin
            tx_line <= tx_sh[0];
            if (tx_cnt == BIT_CYC - 1) begin
                tx_cnt <= 10'd0;
                tx_sh  <= {1'b1, tx_sh[9:1]};
                if (tx_bit == 4'd9) tx_busy <= 1'b0;
                else                tx_bit  <= tx_bit + 4'd1;
            end else
                tx_cnt <= tx_cnt + 10'd1;
        end else
            tx_line <= 1'b1;
    end
end

// ======================= 行缓冲 / 页缓冲（512 字节） =======================
// 指令模式：一条指令的 UTF-8 字节；装字库：两个 256 字节页轮流收
reg  [7:0] lbuf [0:511];
reg        lb_we;
reg  [8:0] lb_wa;
reg  [7:0] lb_wd;
reg  [7:0] lb_rd;
reg        e_half;                  // （e_prog = SPI 引擎在编程：读口给引擎）
wire [8:0] lb_ra = e_prog ? {e_half, e_ra} : p_ra;
always @(posedge clk) begin
    if (lb_we) lbuf[lb_wa] <= lb_wd;
    lb_rd <= lbuf[lb_ra];
end
// 【时序】解析 / 核对用的读数据再打一拍（BRAM 出数要 3ns 多，直接接比较器太紧）：
//   读完都等 rdw = 2 拍，第 2 拍时 lb_q / rom_q 已经是这次读的数据，流程不变
reg  [7:0] lb_q, rom_q;
always @(posedge clk) begin
    lb_q  <= lb_rd;
    rom_q <= rom_a;
end

// ======================= SPI 引擎（模式 0，SCLK = clk / 8，按字节） =======================
// 一次传输：命令 1 字节 [+ 地址 3 字节] + e_n 个数据字节；读到的数据字节逐个给 e_rx_v / e_rx_b
reg        e_go;
reg  [7:0] e_cmd;
reg [23:0] e_addr;
reg        e_has_a;
reg [19:0] e_n;
reg        e_wr;                    // 数据字节从页缓冲发（页编程）
reg        e_busy;
reg        e_gap;
reg  [3:0] e_gcnt;
reg  [2:0] e_xc, e_bit;
reg  [2:0] e_hb;                    // 头还剩几个字节（不含正在发的）
reg        e_indata;
reg [19:0] e_left;                  // 数据还剩几个字节（不含正在发的）
reg  [7:0] e_osh, e_ish;
reg  [7:0] e_idx;                   // 页缓冲里下一个要发的字节
reg        e_rx_v;
reg  [7:0] e_rx_b;
reg        miso_q;
assign e_prog = e_busy && e_wr;
assign e_ra   = e_idx;
wire [7:0] e_hdr_byte = (e_hb == 3'd3) ? e_addr[23:16] : (e_hb == 3'd2) ? e_addr[15:8] : e_addr[7:0];
always @(posedge clk or posedge rst) begin
    if (rst) begin
        e_busy <= 1'b0; e_gap <= 1'b0; e_gcnt <= 4'd0; e_xc <= 3'd0; e_bit <= 3'd0; e_hb <= 3'd0; e_indata <= 1'b0;
        e_left <= 20'd0; e_osh <= 8'hFF; e_ish <= 8'd0; e_idx <= 8'd0; e_rx_v <= 1'b0; e_rx_b <= 8'd0; miso_q <= 1'b1;
        fl_cs_n <= 1'b1; fl_sclk <= 1'b0; fl_mosi <= 1'b1;
    end else begin
        e_rx_v <= 1'b0;
        miso_q <= fl_miso;
        if (e_go) begin
            e_busy   <= 1'b1;
            e_gap    <= 1'b0;
            e_xc     <= 3'd0;
            e_bit    <= 3'd0;
            e_osh    <= e_cmd;
            e_hb     <= e_has_a ? 3'd3 : 3'd0;
            e_indata <= 1'b0;
            e_left   <= e_n;
            e_idx    <= 8'd0;
            fl_cs_n  <= 1'b0;
        end else if (e_busy && e_gap) begin
            e_gcnt <= e_gcnt + 4'd1;
            if (e_gcnt == 4'd11) e_busy <= 1'b0;             // CS 高电平保持 120ns
        end else if (e_busy) begin
            e_xc <= e_xc + 3'd1;
            if (e_xc == 3'd0) fl_mosi <= e_osh[7];
            if (e_xc == 3'd3) begin fl_sclk <= 1'b1; e_ish <= {e_ish[6:0], miso_q}; end
            if (e_xc == 3'd7) begin
                fl_sclk <= 1'b0;
                e_osh   <= {e_osh[6:0], 1'b1};
                e_bit   <= e_bit + 3'd1;
                if (e_bit == 3'd7) begin
                    // 一个字节完了
                    if (e_indata) begin e_rx_v <= 1'b1; e_rx_b <= e_ish; end
                    if (e_hb != 3'd0) begin
                        e_osh <= e_hdr_byte;
                        e_hb  <= e_hb - 3'd1;
                    end else if (e_left != 20'd0) begin
                        // 下一个数据字节
                        e_left   <= e_left - 20'd1;
                        e_indata <= 1'b1;
                        e_osh    <= e_wr ? (e_q ? q_rd : lb_rd) : 8'hFF;   // 【启事】存启事时数据从启事 RAM 取
                        e_idx    <= e_idx + 8'd1;
                    end else begin
                        fl_cs_n <= 1'b1;
                        fl_mosi <= 1'b1;
                        e_gap   <= 1'b1;
                        e_gcnt  <= 4'd0;
                    end
                end
            end
        end
    end
end

// ======================= CRC32（0x04C11DB7，高位先，一拍 1 位） =======================
reg  [31:0] crc;
reg  [7:0]  c_sh;
reg  [3:0]  c_n;
wire [31:0] crc_nx = (crc[31] ^ c_sh[7]) ? ({crc[30:0], 1'b0} ^ 32'h04C11DB7) : {crc[30:0], 1'b0};

// ======================= 字形编号：Unicode → 字库里第几个字（和 gen_font.ps1 一致） =======================
// 【省资源 第4轮】原来每一段各有一个减法再加法；现在先判断在哪一段，再减一个按段选的常数（只用一个减法器）：
//   0020~007E → cp - 0020        00A0~00FF → cp - 00A0 + 95    = cp - 0041
//   2000~206F → cp - 2000 + 191 = cp - 1F41    3000~303F → cp - 3000 + 303 = cp - 2ED1
//   4E00~9FFF → cp - 4E00 + 367 = cp - 4C91    FF00~FFEF → cp - FF00 + 21359 = cp - AB91
//   和原来逐个编码相同（sim/tb_gidx.v 跑全部 65536 个）
function [15:0] gidx;               // 16'hFFFF = 字库里没有
    input [15:0] cp;
    reg   [15:0] k;
    reg          hit;
    begin
        hit = 1'b1;
        if      (cp >= 16'h0020 && cp <= 16'h007E) k = 16'h0020;
        else if (cp >= 16'h00A0 && cp <= 16'h00FF) k = 16'h0041;
        else if (cp >= 16'h2000 && cp <= 16'h206F) k = 16'h1F41;
        else if (cp >= 16'h3000 && cp <= 16'h303F) k = 16'h2ED1;
        else if (cp >= 16'h4E00 && cp <= 16'h9FFF) k = 16'h4C91;
        else if (cp >= 16'hFF00 && cp <= 16'hFFEF) k = 16'hAB91;
        else begin k = 16'h0000; hit = 1'b0; end
        gidx = hit ? (cp - k) : 16'hFFFF;
    end
endfunction

// 【串口照片】标记页开头 16 字节应该是什么（字库 / 照片；16~19 是 CRC）
//   字库 "ZPFONT01" + 字数 + 数据字节数；照片 "ZPPHOT02" + 宽 720 高 640 + 数据字节数（大端）
function [7:0] mk_exp;
    input [3:0] j;
    input       isph;
    begin
        case (j)
            4'd0:  mk_exp = "Z";
            4'd1:  mk_exp = "P";
            4'd2:  mk_exp = isph ? "P" : "F";
            4'd3:  mk_exp = isph ? "H" : "O";
            4'd4:  mk_exp = isph ? "O" : "N";
            4'd5:  mk_exp = "T";
            4'd6:  mk_exp = "0";
            4'd7:  mk_exp = isph ? "2" : "1";      // 照片 02 = RGB565 720×640（01 是早期的 RGB888 480×640，不再认）
            4'd8:  mk_exp = isph ? 8'h02 : FONT_GLYPHS[31:24];   // 照片宽 720 = 0x02D0
            4'd9:  mk_exp = isph ? 8'hD0 : FONT_GLYPHS[23:16];
            4'd10: mk_exp = isph ? 8'h02 : FONT_GLYPHS[15:8];
            4'd11: mk_exp = isph ? 8'h80 : FONT_GLYPHS[7:0];
            4'd12: mk_exp = 8'd0;
            4'd13: mk_exp = isph ? {4'd0, PH_BYTES[19:16]} : {4'd0, DATA_BYTES[19:16]};
            4'd14: mk_exp = isph ? PH_BYTES[15:8] : DATA_BYTES[15:8];
            default: mk_exp = isph ? PH_BYTES[7:0] : DATA_BYTES[7:0];
        endcase
    end
endfunction
// RGB565 的分量扩成 8 位（高位补到低位，0 → 0，满 → 255）
function [7:0] c5to8; input [4:0] v; c5to8 = {v, v[4:2]}; endfunction
function [7:0] c6to8; input [5:0] v; c6to8 = {v, v[5:4]}; endfunction
// 4 个 8 位数的和 → 平均（四舍五入）
function [7:0] rnd4;
    input [9:0] s;
    reg   [10:0] t;
    begin
        t    = {1'b0, s} + 11'd2;
        rnd4 = t[9:2];
    end
endfunction

// ======================= 通知 RAM：写 sd_card_clk，读 video_clk =======================
// 【三级应急】{00, 通知双缓冲 2 × 1024 列}、{01, 应急文字双缓冲 2 × 1024 列}；【启事】{1, 启事页双缓冲 2 × 2048 列}
// 读口只有一个：有应急文字时给应急文字（列号 a_col 由 emergency_overlay 选：警示页文字面板那几行给面板，其余给字幕条），
//   否则显示启事页时给启事页，否则给字幕条
//   【应急改版】三级时启事照常放：启事页上读口给启事页（启事页上不显示字幕条）
reg  [15:0] nram [0:8191] /* fehdl force_ram=1, ram_style="bram_32k" */;
reg         n_we;
reg  [12:0] n_wa;
reg  [15:0] n_wd;
always @(posedge clk)
    if (n_we) nram[n_wa] <= n_wd;
reg         v_wbuf, v_abuf;
wire        v_alm_rd = (v_alm != 2'd0) && (v_alen != 10'd0) && !(pv_sel && (v_alm == 2'd3));
always @(posedge vclk)
    rd_bits <= nram[v_alm_rd ? {2'b01, v_abuf, a_col} : pv_sel ? {1'b1, pv_buf, pv_col} : {2'b00, v_wbuf, rd_col}];

// ======================= 主状态机 =======================
localparam [6:0]
    S_BOOT    = 7'd0,  S_IDLE    = 7'd1,  S_REPLY   = 7'd2,
    S_GET     = 7'd3,  S_GET_W   = 7'd4,                         // 读 lbuf[p..p+2] 到 b0 b1 b2（渲染启事时读启事 RAM）
    S_WS      = 7'd5,                                            // 跳过空格（ASCII / 全角）
    S_CMP     = 7'd6,  S_CMP_W   = 7'd7,  S_CMP_D   = 7'd8,      // 和 ROM 里第 csid 条比
    S_PIN_D   = 7'd9,  S_KW      = 7'd10, S_KW_D    = 7'd11, S_TAIL = 7'd12, S_EXEC = 7'd13,
    S_SEP     = 7'd14, S_R_REQ   = 7'd15, S_R_CHAR  = 7'd16, S_R_DEC = 7'd17, S_R_IDX = 7'd18, S_R_READ = 7'd19,
    S_R_WAIT  = 7'd20, S_R_END   = 7'd21,
    S_V_REQ   = 7'd22, S_V_MARK  = 7'd23, S_V_MARKW = 7'd24, S_V_DATA = 7'd25, S_V_DATAW = 7'd26, S_V_END = 7'd27,
    S_I_REQ   = 7'd28, S_I_WREN  = 7'd29, S_I_ERASE = 7'd30, S_I_POLL = 7'd31, S_I_POLLW = 7'd32,
    S_I_RX    = 7'd33, S_I_PWREN = 7'd34, S_I_PROG  = 7'd35, S_I_TRCHK = 7'd36, S_I_TRCHKW = 7'd37, S_I_TRCHKD = 7'd38,
    S_I_FAIL  = 7'd39, S_PIN_SP = 7'd40,
    S_ATYPE   = 7'd41, S_ABODY   = 7'd42, S_TCP     = 7'd43, S_TCP_W  = 7'd44, S_R_PAD = 7'd45,   // 【三级应急】
    // 【启事】
    S_QL_REQ  = 7'd46, S_QL_RD   = 7'd47, S_QL_CHK  = 7'd48,     // 上电读回
    S_QK2     = 7'd49, S_QPUB    = 7'd50, S_QCP     = 7'd51, S_QCP_W = 7'd52, S_QHDR = 7'd53, S_QHDR2 = 7'd54,   // 发布
    S_QDEL    = 7'd55, S_QCLR    = 7'd56,                        // 撤销
    S_QSV     = 7'd57, S_QSV_MAG = 7'd58, S_QSV_REQ = 7'd59, S_QSV_WREN = 7'd60, S_QSV_ER = 7'd61,          // 存 Flash
    S_QSV_PWREN = 7'd62, S_QSV_PROG = 7'd63, S_QSV_NEXT = 7'd64, S_QSV_END = 7'd65, S_QSV_FAIL = 7'd66,
    S_LS      = 7'd67,                                           // 列表
    S_PG      = 7'd68,                                           // 画启事页
    // 【串口照片】
    S_PM      = 7'd69, S_PM_RD   = 7'd70,                        // 上电核对照片标记
    S_PH_REQ  = 7'd71, S_PH_GW   = 7'd72, S_PH_ACK  = 7'd73, S_PH_ROW = 7'd74, S_PH_PIX = 7'd75,   // 照片写 SDRAM
    S_PH_FIN  = 7'd76, S_PH_END  = 7'd77, S_PH_AW   = 7'd78,
    S_SUBN    = 7'd79, S_SUBB    = 7'd80;                        // 【自定义字幕】取图号 / 内容
reg  [6:0]  st, ret;                // ret：子流程（S_GET / S_CMP / 查忙）回到哪里
reg  [1:0]  rdw;                    // 读 RAM / ROM 后等两拍
reg  [8:0]  p;                      // 解析位置
reg  [8:0]  llen;                   // 这一条的长度
reg         line_ok;                // 收到一条完整的指令，等解析
reg  [4:0]  idle_ms;
reg  [7:0]  b0, b1, b2;
reg  [1:0]  gi;                     // S_GET 读到第几个
reg  [7:0]  cj;                     // 比较到第几个字节
reg         cmatch;
reg  [6:0]  rsid;                   // 要回复的字符串
reg  [6:0]  kw;                     // 匹配到的关键字
// 【三级应急】
reg  [1:0]  tgt;                    // 正在画的是：通知 / 应急文字 / 【启事】启事页
reg  [9:0]  lc;                     // 应急文字 / 启事页：这一行已经画了几列
reg         abuf;
reg  [9:0]  alen;
reg  [1:0]  plvl;                   // 这条指令要设的等级（画完字才生效）
reg  [2:0]  atype;                  // 0 没写类型，1~4 火灾 地震 治安 故障
reg         sub_off, ntc_on, wbuf, new_tgl, rej_tgl;
reg  [10:0] ntc_len;
reg  [10:0] col;                    // 渲染到第几列
reg         trunc;
reg  [15:0] cp;
reg  [2:0]  ub;                     // 这个字占几个字节
reg  [15:0] gid;
reg         half;
reg  [7:0]  ghi;
reg  [5:0]  gcnt;                   // 字形里收到第几个字节
reg         font_ok;
// 装字库 / 校验
reg  [3:0]  blk;
reg  [11:0] op_ms;
reg  [15:0] rx_ms;
reg         fmode;                  // 1 = 正在收字库文件
reg         frst;                   // 还没收到第一个字节
reg [19:0]  fcnt;                   // 文件里收到第几个字节
reg  [1:0]  pg_pend;                // 两个半区：收满等编程
reg [11:0]  pg_num0, pg_num1;       // 各半区是第几页
reg         tr_done;                // 标记页收齐
reg         tr_half;
reg [31:0]  crc_rx;                 // 收的时候算的 CRC
reg [31:0]  tr_crc;                 // 标记页里写的 CRC
reg         tr_bad;
reg  [4:0]  tj;
reg         in_install;             // 校验完以后回复“安装完成 / 失败”
reg         poll_busy;
reg  [6:0]  reply_ret;              // 回复发出去以后去哪
wire [1:0]  eff_lvl = sw1 ? 2'd1 : alarm_lvl;   // 实际等级（sw1 现在接 0）
reg  [1:0]  lvl_d;                  // 【按键改造】上一拍的等级（变了就取消消音）
// 【启事】
reg         lfree;                  // 这条指令的行缓冲已经提前放掉了（可以收下一条），回复时不要再清
reg  [7:0]  q_tys;                  // 4 条的类别，各 2 位
reg  [35:0] q_lens;                 // 4 条的字节数，各 9 位
reg  [1:0]  qtype;                  // 正在发布的类别
reg  [8:0]  qi;                     // 发布：抄了几个字节
reg         psm;                    // 【自动字号】这一页按小字排
reg  [11:0] qcols;                  // 发布：估算要画多少列（判断会不会显示不全）
reg  [1:0]  qd;                     // 撤销第几条
reg  [3:0]  qclr;                   // 要撤销的几条
reg  [1:0]  qk;
reg  [6:0]  q_rsp;                  // 存完 Flash 以后的回复
reg         qsv;                    // 正在存启事（查忙超时去 S_QSV_FAIL）
reg         rsrc;                   // 渲染的原文从启事 RAM 读（不是 lbuf）
reg  [8:0]  plen;                   // 渲染启事：原文结束位置（启事 RAM 里，从 2 开始）
reg         pr_pend, pq_buf, pgb;   // 有画启事页的请求 / 请求的缓冲 / 正在画的缓冲
reg  [1:0]  pq_slot;
reg  [20:0] pm0, pm1;               // 两块启事页缓冲各画的是什么（见 pv_meta）
reg  [1:0]  lsk;                    // 列表：第几条
reg  [2:0]  lsph;                   // 列表：这一条发到哪一步
reg         lsact;                  // 正在发列表（回复不清行缓冲）
// 【串口照片】
reg         ph;                     // 装 / 校验的是照片（0 = 字库）
reg  [1:0]  phs;                    // 装第几条的照片
reg  [3:0]  q_ph;                   // 哪几条启事带照片
reg         pph;                    // 正在画的启事页带照片
reg         ph_ab;                  // 这次照片不画了（来了新指令 / 超时）：剩下的写黑，页面按没照片显示
reg         ph_fin_seen;
reg  [8:0]  ph_row;                 // 写到第几行（0 = 照片最下面一行）
reg  [9:0]  ph_x;                   // 这一行写到第几个像素（0~640）
reg  [2:0]  ph_pc;                  // 6 拍写一个像素
reg  [23:0] ph_a;                   // 这一行在 Flash 里的地址
reg  [1:0]  ph_ch, ph_k;            // 收到的是像素的高 / 低字节、2×2 里第几个像素
reg  [7:0]  ph_hi;                  // 像素高字节 RRRRRGGG
reg  [9:0]  ph_sr, ph_sg, ph_sb;    // 4 个像素的和
reg  [23:0] px_r;                   // 算好的一个像素
reg         px_rdy;
// 【自定义字幕】
reg  [3:0]  s_mask;                 // 哪几张图有自定义字幕
reg  [3:0]  s_f;                    // 上电读回：[0] 字节 = 1
reg  [31:0] s_lens;                 // 各自的字节数（各 8 位）
reg         cs_ok;                  // 通知 RAM 显示的那块里是第 cs_slot 张图的自定义字幕（列数在 ntc_len）
reg  [1:0]  cs_slot;
reg         csr;                    // 正在画自定义字幕
reg         cs_want;                // 要画（【时序】打一拍）
reg  [3:0]  si1, si2, si3;          // v_shown 同步过来，连续两拍相同才用
reg  [1:0]  s_img;                  // 正在显示的图 0~3
reg         s_img_ok;
wire [7:0]  s_len_i = s_lens[{s_img, 3'b000} +: 8];
wire [19:0] d_bytes = ph ? PH_BYTES : DATA_BYTES;
wire [19:0] f_bytes = ph ? PH_FILE  : FILE_BYTES;
wire [11:0] mk_pg   = ph ? PH_MKPG  : FT_MKPG;
wire [3:0]  f_hi    = ph ? (4'd2 + {2'd0, phs}) : 4'd0;            // Flash 地址最高 4 位：字库 0，照片 2~5（每张 1MB）
wire [9:0]  lw      = (tgt != T_PAGE) ? LINE_W[9:0] :                   // 自动换行的行宽（【自动字号】小字是大字的 2 倍）
                      pph ? (psm ? 10'd224 : {1'b0, PH_LW}) : (psm ? 10'd576 : LINE_W[9:0]);
assign ph_pbuf = pgb;
wire [8:0]  cur_len  = rsrc ? plen : llen;
wire [7:0]  cur_q    = rsrc ? q_q  : lb_q;
wire [1:0]  q_free   = !q_mask[0] ? 2'd0 : !q_mask[1] ? 2'd1 : !q_mask[2] ? 2'd2 : 2'd3;
wire [3:0]  q_below  = (q_slot == 2'd0) ? 4'b0000 : (q_slot == 2'd1) ? 4'b0001 : (q_slot == 2'd2) ? 4'b0011 : 4'b0111;
wire [3:0]  q_bm     = q_mask & q_below;
wire [2:0]  q_idx    = {2'b0, q_bm[0]} + {2'b0, q_bm[1]} + {2'b0, q_bm[2]} + 3'd1;            // 这一条是第几条
wire [2:0]  q_tot    = {2'b0, q_mask[0]} + {2'b0, q_mask[1]} + {2'b0, q_mask[2]} + {2'b0, q_mask[3]};
wire [1:0]  q_ty_s   = q_tys[{q_slot, 1'b0} +: 2];
wire [8:0]  q_len_s  = q_lens[q_slot * 9 +: 9];

// 【时序 t5】空格 / 冒号判断每拍算好打一拍（原来 b0~b2 的 24 位比较直接进状态机，差 0.19ns）：
//   b0~b2 读完（S_GET_W 最后一拍）后多等一拍再进下一个状态（rdw = 1），所以用的时候已经是这次读的结果
reg         sp_ascii, sp_full, colon, colon_f;
reg  [7:0]  s_len_q;                // 【时序 t5】s_len 打一拍：csid 改了以后至少隔 3 拍才比长度（S_CMP 要等 rdw）
// 【时序】p 和长度的比较每拍算好打一拍（原来 11 位选择 + 比较直接扇出到几十个状态，差 0.3ns）：
//   p / 长度改了以后至少隔一拍才用（S_GET 要等 rdw；S_R_DEC / S_R_IDX 改完 p 后各多等一拍）
reg         p_lt0, p_lt1, p_lt2;    // p / p+1 / p+2 < 当前长度
wire        at_end   = !p_lt0;
reg  [15:0] gx;                     // 【时序】gidx(cp) 打一拍
reg         op_to;                  // 【时序】op_ms >= BUSY_MS 打一拍

task reply;
    input [6:0] r;
    begin
        rsid      <= r;
        reply_ret <= S_IDLE;
        st        <= S_REPLY;
    end
endtask
task spi;                            // 发起一次 Flash 传输
    input [7:0]  c;
    input [23:0] a;
    input        has_a;
    input [19:0] n;
    input        wr;
    begin
        e_go    <= 1'b1;
        e_cmd   <= c;
        e_addr  <= a;
        e_has_a <= has_a;
        e_n     <= n;
        e_wr    <= wr;
    end
endtask

// 编程中的半区
reg         prog_half;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        st <= S_BOOT; ret <= S_IDLE; rdw <= 2'd0; p <= 9'd0; llen <= 9'd0; line_ok <= 1'b0; idle_ms <= 5'd0;
        b0 <= 8'd0; b1 <= 8'd0; b2 <= 8'd0; gi <= 2'd0; cj <= 8'd0; cmatch <= 1'b0; rsid <= 7'd0; kw <= 7'd0;
        tgt <= T_NTC; lc <= 9'd0; abuf <= 1'b0; alen <= 10'd0; plvl <= 2'd0; atype <= 3'd0; alarm_lvl <= 2'd0;
        sub_off <= 1'b0; ntc_on <= 1'b0; wbuf <= 1'b0; new_tgl <= 1'b0; rej_tgl <= 1'b0; ntc_len <= 11'd0;
        col <= 11'd0; trunc <= 1'b0; cp <= 16'd0; ub <= 2'd0; gid <= 16'd0; half <= 1'b0; ghi <= 8'd0; gcnt <= 6'd0;
        font_ok <= 1'b0; font_status <= 2'd0;
        blk <= 4'd0; op_ms <= 12'd0; rx_ms <= 16'd0; fmode <= 1'b0; frst <= 1'b0; fcnt <= 20'd0; pg_pend <= 2'b00;
        pg_num0 <= 12'd0; pg_num1 <= 12'd0; tr_done <= 1'b0; tr_half <= 1'b0; crc_rx <= 32'd0; tr_crc <= 32'd0;
        tr_bad <= 1'b0; tj <= 5'd0; in_install <= 1'b0; poll_busy <= 1'b0; reply_ret <= S_IDLE; prog_half <= 1'b0;
        fl_req <= 1'b0; csid <= K_PIN; ra_a <= 12'd0; p_ra <= 9'd0; reply_go <= 1'b0; reply_at <= 12'd0;
        lb_we <= 1'b0; lb_wa <= 9'd0; lb_wd <= 8'd0; n_we <= 1'b0; n_wa <= 13'd0; n_wd <= 16'd0;
        e_go <= 1'b0; e_cmd <= 8'h00; e_addr <= 24'd0; e_has_a <= 1'b0; e_n <= 20'd0; e_wr <= 1'b0; e_half <= 1'b0;
        crc <= 32'hFFFFFFFF; c_sh <= 8'd0; c_n <= 4'd0;
        p_lt0 <= 1'b0; p_lt1 <= 1'b0; p_lt2 <= 1'b0; gx <= 16'd0; op_to <= 1'b0;
        sp_ascii <= 1'b0; sp_full <= 1'b0; colon <= 1'b0; colon_f <= 1'b0; s_len_q <= 8'd0;
        music_play <= 1'b0; music_stop <= 1'b0; img_next <= 1'b0; img_prev <= 1'b0;
        osd_set <= 1'b0; osd_clr <= 1'b0; auto_set <= 1'b0; auto_clr <= 1'b0; muted <= 1'b0; lvl_d <= 2'd0;   // 【按键改造】
        wave_set <= 1'b0; wave_clr <= 1'b0; res_set <= 1'b0; res_clr <= 1'b0;
        // 【启事】
        q_mask <= 4'd0; q_new <= 1'b0; q_new_slot <= 2'd0; pg_done <= 1'b0; q_we <= 1'b0; q_wa <= 10'd0; q_wd <= 8'd0;
        q_slot <= 2'd0; e_q <= 1'b0; q_pg <= 3'd0; qtx_go <= 1'b0; qtx_slot <= 2'd0; qtx_len <= 9'd0;
        lfree <= 1'b0; q_tys <= 8'd0; q_lens <= 36'd0; qtype <= 2'd0; qi <= 9'd0; psm <= 1'b0; qcols <= 12'd0; qd <= 2'd0; qclr <= 4'd0;
        qk <= 2'd0; q_rsp <= R_OK_QDEL; qsv <= 1'b0; rsrc <= 1'b0; plen <= 9'd0; pr_pend <= 1'b0; pq_buf <= 1'b0; pgb <= 1'b0;
        pq_slot <= 2'd0; pm0 <= 21'd0; pm1 <= 21'd0; lsk <= 2'd0; lsph <= 3'd0; lsact <= 1'b0;
        ph <= 1'b0; phs <= 2'd0; q_ph <= 4'd0; pph <= 1'b0; ph_ab <= 1'b0; ph_fin_seen <= 1'b0;     // 【串口照片】
        ph_need <= 1'b0; ph_wreq <= 1'b0; ph_we <= 1'b0; ph_px <= 24'd0; ph_row <= 9'd0; ph_x <= 10'd0; ph_pc <= 3'd0;
        ph_a <= 24'd0; ph_ch <= 2'd0; ph_k <= 2'd0; ph_hi <= 8'd0; ph_sr <= 10'd0; ph_sg <= 10'd0; ph_sb <= 10'd0; px_r <= 24'd0; px_rdy <= 1'b0;
        qb <= 1'b0; s_mask <= 4'd0; s_f <= 4'd0; s_lens <= 32'd0; cs_ok <= 1'b0; cs_slot <= 2'd0; csr <= 1'b0;   // 【自定义字幕】
        cs_want <= 1'b0; si1 <= 4'd0; si2 <= 4'd0; si3 <= 4'd0; s_img <= 2'd0; s_img_ok <= 1'b0;
    end else begin
        lb_we      <= 1'b0;
        n_we       <= 1'b0;
        e_go       <= 1'b0;
        reply_go   <= 1'b0;
        music_play <= 1'b0;
        music_stop <= 1'b0;
        img_next   <= 1'b0;
        img_prev   <= 1'b0;
        osd_set    <= 1'b0;
        osd_clr    <= 1'b0;
        auto_set   <= 1'b0;
        auto_clr   <= 1'b0;
        wave_set   <= 1'b0;
        wave_clr   <= 1'b0;
        res_set    <= 1'b0;
        res_clr    <= 1'b0;
        q_new      <= 1'b0;
        pg_done    <= 1'b0;
        q_we       <= 1'b0;
        qtx_go     <= 1'b0;
        ph_we      <= 1'b0;
        if (ph_wfin) ph_fin_seen <= 1'b1;                // 【串口照片】
        if (pg_req) begin pr_pend <= 1'b1; pq_slot <= pg_slot; pq_buf <= pg_buf; end   // 【启事】画启事页的请求，空闲时处理
        if (rdw != 2'd0) rdw <= rdw - 2'd1;
        p_lt0 <= (p < cur_len);
        p_lt1 <= (p + 9'd1 < cur_len);
        p_lt2 <= (p + 9'd2 < cur_len);
        gx    <= gidx(cp);
        op_to <= (op_ms >= BUSY_MS);
        sp_ascii <= (b0 == 8'h20);
        sp_full  <= (b0 == 8'hE3) && (b1 == 8'h80) && (b2 == 8'h80);
        colon    <= (b0 == 8'h3A);
        colon_f  <= (b0 == 8'hEF) && (b1 == 8'hBC) && (b2 == 8'h9A);
        s_len_q  <= s_len;
        // 【自定义字幕】正在显示第几张图；这张图有自定义字幕、没有通知、通知 RAM 里还不是它 → 要画
        si1 <= v_shown; si2 <= si1; si3 <= si2;
        if (si2 == si3) begin s_img_ok <= (si3 != 4'd0); s_img <= si3[1:0] - 2'd1; end
        cs_want <= s_img_ok && s_mask[s_img] && !ntc_on && font_ok && !fl_off && !(cs_ok && (cs_slot == s_img));
        if (ms_tick && (op_ms != 12'hFFF)) op_ms <= op_ms + 12'd1;
        if (ms_tick && (rx_ms != 16'hFFFF)) rx_ms <= rx_ms + 16'd1;

        // CRC 串行（字库数据：收文件时、读回校验时）
        if (c_n != 4'd0) begin
            crc  <= crc_nx;
            c_sh <= {c_sh[6:0], 1'b0};
            c_n  <= c_n - 4'd1;
        end

        // ---------------- 收字节 ----------------
        if (rx_valid) begin
            if (fmode) begin
                // 字库文件：两个半区轮流收；数据页算 CRC，最后一页是标记页
                rx_ms <= 16'd0;
                frst  <= 1'b0;
                lb_we <= 1'b1;
                lb_wa <= {fcnt[8], fcnt[7:0]};
                lb_wd <= rx_byte;
                fcnt  <= fcnt + 20'd1;
                if (fcnt < d_bytes) begin
                    c_sh <= rx_byte; c_n <= 4'd8;
                end
                if (fcnt[7:0] == 8'hFF) begin
                    if (fcnt + 20'd1 >= f_bytes) begin
                        tr_done <= 1'b1;
                        tr_half <= fcnt[8];
                    end else if (pg_pend[fcnt[8]]) begin
                        tr_bad  <= 1'b1;                     // 上一页还没编完（不会发生：编一页 < 3ms，收一页 22ms）
                    end else begin
                        pg_pend[fcnt[8]] <= 1'b1;
                        if (fcnt[8]) pg_num1 <= fcnt[19:8]; else pg_num0 <= fcnt[19:8];
                    end
                end
            end else if (!line_ok) begin                     // 【启事】状态机在忙（画启事页、存 Flash）也照收
                idle_ms <= 5'd0;
                if (rx_byte == 8'h0D || rx_byte == 8'h0A) begin
                    if (llen != 9'd0) line_ok <= 1'b1;
                end else if (llen != 9'd511) begin
                    lb_we <= 1'b1;
                    lb_wa <= llen;
                    lb_wd <= rx_byte;
                    llen  <= llen + 9'd1;
                end
            end
        end else if (!line_ok && !fmode && (llen != 9'd0) && ms_tick) begin
            if (idle_ms >= IDLE_MS - 1) line_ok <= 1'b1;
            else                        idle_ms <= idle_ms + 5'd1;
        end

        if (rdw == 2'd0) case (st)
            // ---------------- 上电：校验字库 ----------------
            S_BOOT: begin in_install <= 1'b0; qb <= 1'b0; st <= S_QL_REQ; end   // 【启事】先读回启事（【自定义字幕】和字幕），再校验字库

            S_IDLE: if (line_ok) begin
                lfree <= 1'b0;
                qb  <= 1'b0;
                p <= 9'd0;
                ret <= S_PIN_D;                              // 跳完空格比口令
                st  <= S_GET;
            end else if (pr_pend) begin                      // 【启事】没有指令要处理时画启事页
                pr_pend <= 1'b0;
                qb      <= 1'b0;
                q_slot  <= pq_slot;
                pgb     <= pq_buf;
                st      <= S_PG;
            end else if (cs_want) begin                      // 【自定义字幕】把正在显示的这张图的字幕画进通知 RAM
                qb      <= 1'b1;
                q_slot  <= s_img;
                cs_slot <= s_img;
                cs_ok   <= 1'b0;                         // 画的时候显示的那块还是旧的：先不用（字幕条暂时用默认字幕）
                csr     <= 1'b1;
                rsrc    <= 1'b1; p <= 9'd2; plen <= {1'b0, s_len_i} + 9'd2;
                col <= 11'd0; trunc <= 1'b0; lc <= 9'd0; tgt <= T_NTC; fl_req <= 1'b1;
                st <= S_R_REQ;
            end

            S_REPLY: if (!tx_run && !reply_go) begin
                csid <= rsid;
                if (csid == rsid) begin                      // csid 改完一拍后 s_start 才对
                    reply_at <= s_start;
                    reply_go <= 1'b1;
                    if (!lfree) begin                        // 这一条处理完了，可以收下一条（【启事】提前放掉的不用再清）
                        line_ok <= 1'b0;
                        llen    <= 9'd0;
                        idle_ms <= 5'd0;
                    end
                    st       <= reply_ret;
                end
            end

            // ---------------- 读 3 个字节 b0 b1 b2（超出长度读成 0） ----------------
            S_GET: begin p_ra <= p; gi <= 2'd0; rdw <= 2'd2; st <= S_GET_W; end
            S_GET_W: begin
                case (gi)
                    2'd0: b0 <= p_lt0 ? cur_q : 8'h00;
                    2'd1: b1 <= p_lt1 ? cur_q : 8'h00;
                    default: b2 <= p_lt2 ? cur_q : 8'h00;
                endcase
                if (gi == 2'd2) begin
                    st  <= ((ret == S_R_DEC) || (ret == S_PIN_SP)) ? ret : S_WS;   // 通知正文里的空格要画出来；口令后面要看是不是空格
                    rdw <= 2'd1;                                 // 【时序 t5】等空格 / 冒号标志跟上
                end
                else begin gi <= gi + 2'd1; p_ra <= p + {7'd0, gi} + 9'd1; rdw <= 2'd2; end
            end
            // 跳空格：ret = S_PIN_D / S_KW / S_TAIL / S_SEP 决定跳完以后做什么
            S_WS: begin
                if (sp_ascii && !at_end)       begin p <= p + 9'd1; st <= S_GET; end
                else if (sp_full && !at_end)   begin p <= p + 9'd3; st <= S_GET; end
                else if (((ret == S_SEP) || (ret == S_ATYPE) || (ret == S_ABODY) || (ret == S_QPUB) || (ret == S_SUBB)) && !at_end && (colon || colon_f)) begin
                    p <= p + (colon ? 9'd1 : 9'd3); st <= S_GET;                 // 通知 / 应急 / 启事 / 【自定义字幕】后面的冒号也跳过
                end else if (ret == S_PIN_D)   begin csid <= K_PIN; cj <= 8'd0; cmatch <= 1'b1; st <= S_CMP; end
                else if (ret == S_KW)          begin csid <= K_NOTICE; cj <= 8'd0; cmatch <= 1'b1; st <= S_CMP; end
                else                           st <= ret;
            end

            // ---------------- 和 ROM 第 csid 条比（从 p 开始），结果 cmatch ----------------
            S_CMP: begin
                ra_a <= s_start + {4'd0, cj};
                p_ra <= p + {1'b0, cj};
                rdw  <= 2'd2;
                st   <= S_CMP_W;
            end
            S_CMP_W: begin
                if ((rom_q != lb_q) || (p + {1'b0, cj} >= llen)) cmatch <= 1'b0;
                if ((cj + 8'd1 >= s_len_q) || (rom_q != lb_q) || (p + {1'b0, cj} >= llen))
                    st <= S_CMP_D;
                else begin
                    cj <= cj + 8'd1;
                    st <= S_CMP;
                end
            end
            S_CMP_D: begin
                if (ret == S_PIN_D) begin
                    if (cmatch) begin
                        p   <= p + {1'b0, s_len_q};
                        ret <= S_PIN_SP;                     // 口令后面要是空格、结束或中文（“88481”不算对）
                        st  <= S_GET;
                    end else begin
                        rej_tgl <= ~rej_tgl;                 // 口令不对：右上角红框
                        reply(R_ERR_PIN);
                    end
                end else if (ret == S_ATYPE) begin           // 【三级应急】一个个类型试；都不是 = 没写类型，从这里开始就是内容
                    if (cmatch) begin
                        atype <= csid[2:0];                  // 25~28 → 1~4（低 3 位正好是 1~4）
                        p     <= p + {1'b0, s_len_q};
                        ret   <= S_ABODY;
                        st    <= S_GET;
                    end else if (csid == K_TY_FAULT)
                        st <= S_ABODY;
                    else begin
                        csid <= csid + 7'd1; cj <= 8'd0; cmatch <= 1'b1; st <= S_CMP;
                    end
                end else if (ret == S_QK2) begin             // 【启事】“寻人启事 ……”：关键字后面的“启事”两个字跳过
                    if (cmatch) p <= p + {1'b0, s_len_q};
                    ret <= S_QPUB;
                    st  <= S_GET;
                end else begin                               // ret == S_KW：一个个关键字试
                    if (cmatch) begin
                        kw <= csid;
                        p  <= p + {1'b0, s_len_q};
                        qtype <= (csid == K_QP) ? 2'd1 : (csid == K_QT) ? 2'd2 : 2'd3;
                        ret <= (csid == K_NOTICE) ? S_SEP :
                               ((csid == K_ALM1) || (csid == K_ALM2) || (csid == K_ALM3)) ? S_ATYPE :
                               ((csid == K_QP) || (csid == K_QT) || (csid == K_QF) || (csid == K_QF2)) ? S_QK2 :
                               ((csid == K_QDEL) || (csid == K_PHOTO)) ? S_QDEL :   // 【串口照片】照片n 和 撤销n 一样取数字
                               (csid == K_SUB) ? S_SUBN : S_TAIL;                   // 【自定义字幕】字幕n
                        st  <= S_GET;
                    end else if (csid == K_MUTE) begin       // 【串口照片】“照片”在字符串表的最后
                        csid <= K_PHOTO; cj <= 8'd0; cmatch <= 1'b1; st <= S_CMP;
                    end else if (csid == K_PHOTO) begin      // 【自定义字幕】“字幕”最后试（在“字幕开 / 字幕关”后面，不会抢）
                        csid <= K_SUB; cj <= 8'd0; cmatch <= 1'b1; st <= S_CMP;
                    end else if (csid == K_SUB) begin        // 【波形开关】【分辨率显示】最后试 波形开 / 波形关 / 分辨率开 / 分辨率关
                        csid <= K_WAVEON; cj <= 8'd0; cmatch <= 1'b1; st <= S_CMP;
                    end else if (csid == K_RESOFF)
                        reply(R_ERR_UNKNOWN);
                    else begin
                        csid <= csid + 7'd1; cj <= 8'd0; cmatch <= 1'b1; st <= S_CMP;
                    end
                end
            end
            S_PIN_SP: if (sp_ascii || sp_full || at_end || b0[7]) begin   // 直接跟中文关键字（8848音乐开）也行；跟数字字母 = 口令不对
                ret <= S_KW; st <= S_WS;
            end else begin
                rej_tgl <= ~rej_tgl;
                reply(R_ERR_PIN);
            end
            // 除了“通知”，关键字后面只能有空格
            S_TAIL: if (!at_end) reply(R_ERR_UNKNOWN); else st <= S_EXEC;
            S_EXEC: case (kw)
                K_CLEAR:  begin ntc_on <= 1'b0; new_tgl <= ~new_tgl; reply(R_OK_CLEAR); end
                K_SUBON:  begin osd_set <= 1'b1; reply(R_OK_SUBON);  end   // 【按键改造】和 KEY3 长按是同一个开关
                K_SUBOFF: begin osd_clr <= 1'b1; reply(R_OK_SUBOFF); end
                K_AUTOON: begin auto_set <= 1'b1; reply(R_OK_AUTOON);  end
                K_AUTOOFF:begin auto_clr <= 1'b1; reply(R_OK_AUTOOFF); end
                K_WAVEON: begin wave_set <= 1'b1; reply(R_OK_WAVEON);  end   // 【波形开关】和 KEY3 + Key2 组合键是同一个开关
                K_WAVEOFF:begin wave_clr <= 1'b1; reply(R_OK_WAVEOFF); end
                K_RESON:  begin res_set  <= 1'b1; reply(R_OK_RESON);   end   // 【分辨率显示】
                K_RESOFF: begin res_clr  <= 1'b1; reply(R_OK_RESOFF);  end
                K_MUTE:   if (eff_lvl == 2'd0) reply(R_ERR_NOALM); else begin muted <= 1'b1; reply(R_OK_MUTE); end
                K_MUSON:  if (emerg_mode) reply(R_ERR_EMERG); else begin music_play <= 1'b1; reply(R_OK_MUSON);  end
                K_MUSOFF: if (emerg_mode) reply(R_ERR_EMERG); else begin music_stop <= 1'b1; reply(R_OK_MUSOFF); end
                K_NEXT:   if (emerg_mode) reply(R_ERR_EMERG); else begin img_next <= 1'b1; reply(R_OK_NEXT); end
                K_PREV:   if (emerg_mode) reply(R_ERR_EMERG); else begin img_prev <= 1'b1; reply(R_OK_PREV); end
                K_HELP:   reply(R_HELP);
                K_FONT:   if (fl_off) reply(R_ERR_FLASH); else begin ph <= 1'b0; st <= S_I_REQ; end
                K_PHOTO:  if (!q_mask[qd]) reply(R_ERR_QNONE);           // 【串口照片】先要有这一条启事
                          else if (fl_off) reply(R_ERR_FLASH);
                          else begin ph <= 1'b1; phs <= qd; st <= S_I_REQ; end
                K_ALMCLR: begin alarm_lvl <= 2'd0; alen <= 10'd0; reply(sw1 ? R_OK_ALMSW1 : R_OK_ALMCLR); end
                // 【启事】列表：先放掉行缓冲（后面要连发好几段回复）
                K_QLIST:  begin line_ok <= 1'b0; llen <= 9'd0; idle_ms <= 5'd0; lfree <= 1'b1; lsact <= 1'b1;
                                lsk <= 2'd0; lsph <= 3'd0; rsid <= R_LS_HEAD; reply_ret <= S_LS; st <= S_REPLY; end
                K_QDALL:  begin qclr <= 4'hF; qk <= 2'd0; q_rsp <= R_OK_QDALL; st <= S_QCLR; end
                K_QDEL:   if (!q_mask[qd]) reply(R_ERR_QNONE);
                          else begin qclr <= 4'd1 << qd; qk <= 2'd0; q_rsp <= R_OK_QDEL; st <= S_QCLR; end
                default:  reply(R_ERR_UNKNOWN);
            endcase

            // ---------------- 【三级应急】应急1~3 [类型] [内容] ----------------
            S_ATYPE: begin
                plvl  <= kw[1:0] - 2'd2;                     // 11~13 → 1~3
                atype <= 3'd0;
                if (at_end) st <= S_ABODY;
                else begin csid <= K_TY_FIRE; cj <= 8'd0; cmatch <= 1'b1; st <= S_CMP; end
            end
            S_ABODY: begin
                if (fl_off || !font_ok) begin                // 字库不能用：照样切等级，只是不显示文字
                    alen <= 10'd0; alarm_lvl <= plvl; reply(R_OK_ALMNOTXT);
                end else if (!at_end) begin                  // 写了内容：画内容
                    col <= 11'd0; trunc <= 1'b0; lc <= 9'd0; tgt <= T_ALM; fl_req <= 1'b1; st <= S_R_REQ;
                end else if (llen[8]) begin                  // 行太长放不下提示语（实际不会发生）
                    alen <= 10'd0; alarm_lvl <= plvl; reply(R_OK_ALM1 + {5'd0, plvl} - 7'd1);
                end else begin                               // 没写内容：把提示语抄到这一行后面，再照常画
                    csid <= (atype != 3'd0) ? (K_TP_FIRE + {4'd0, atype} - 7'd1) : (K_TP_L1 + {5'd0, plvl} - 7'd1);
                    cj   <= 8'd0;
                    st   <= S_TCP;
                end
            end
            S_TCP: begin ra_a <= s_start + {4'd0, cj}; rdw <= 2'd2; st <= S_TCP_W; end
            S_TCP_W: begin
                lb_we <= 1'b1;
                lb_wa <= llen + {1'b0, cj};
                lb_wd <= rom_q;
                if (cj + 8'd1 >= s_len_q) begin
                    p    <= llen;
                    llen <= llen + {1'b0, s_len_q};
                    col  <= 11'd0; trunc <= 1'b0; lc <= 9'd0; tgt <= T_ALM; fl_req <= 1'b1;
                    st   <= S_R_REQ;
                end else begin
                    cj <= cj + 8'd1;
                    st <= S_TCP;
                end
            end

            // ---------------- 通知：跳过分隔符后逐字渲染 ----------------
            S_SEP: begin
                if (at_end)               reply(R_ERR_EMPTY);
                else if (fl_off)          reply(R_ERR_FLASH);
                else if (!font_ok)        reply(R_ERR_NOFONT);
                else begin col <= 11'd0; trunc <= 1'b0; fl_req <= 1'b1; st <= S_R_REQ; end
            end
            S_R_REQ: if (fl_grant) begin ret <= S_R_DEC; st <= S_R_CHAR; end
            S_R_CHAR: if (at_end) st <= S_R_END; else begin ret <= S_R_DEC; st <= S_GET; end
            S_R_DEC: begin
                // UTF-8 → Unicode（只认到 3 字节，也就是 U+FFFF 以内；4 字节的表情等画成“?”）
                if (b0[7] == 1'b0) begin
                    cp <= {8'd0, b0}; ub <= 3'd1;
                end else if ((b0[7:5] == 3'b110) && (b1[7:6] == 2'b10)) begin
                    cp <= {5'd0, b0[4:0], b1[5:0]}; ub <= 3'd2;
                end else if ((b0[7:4] == 4'b1110) && (b1[7:6] == 2'b10) && (b2[7:6] == 2'b10)) begin
                    cp <= {b0[3:0], b1[5:0], b2[5:0]}; ub <= 3'd3;
                end else if (b0[7:3] == 5'b11110) begin
                    cp <= 16'h003F; ub <= 3'd4;              // 4 字节（表情等）：整个跳过，画一个“?”
                end else begin
                    cp <= 16'h003F; ub <= 3'd1;              // 坏的 UTF-8：这个字节画“?”
                end
                st  <= S_R_IDX;
                rdw <= 2'd1;                                 // 【时序】等 gx 算好
            end
            S_R_IDX: begin
                p <= p + {6'd0, ub};
                if (cp < 16'h0020) begin st <= S_R_CHAR; rdw <= 2'd1; end   // 控制字符（制表符等）不画（【时序】等 at_end 跟上新的 p）
                else if (gx == 16'hFFFF) begin gid <= 16'd31; half <= 1'b1; st <= S_R_READ; end   // 没有的字画“?”
                else begin gid <= gx; half <= (cp <= 16'h007E); st <= S_R_READ; end
            end
            S_R_READ: begin
                if ({1'b0, col} + (half ? 12'd8 : 12'd16) > ((tgt == T_ALM) ? {1'b0, ALM_COLS} :
                    (tgt == T_PAGE) ? (psm ? PS_COLS : pph ? {1'b0, PH_COLS} : {1'b0, PG_COLS}) : 12'd1024)) begin
                    trunc <= 1'b1;
                    st    <= S_R_END;
                end else if ((tgt != T_NTC) && (lc + (half ? 10'd8 : 10'd16) > lw)) begin
                    st    <= S_R_PAD;                        // 【三级应急】【启事】这一行放不下这个字：补空列到下一行
                end else begin
                    spi(8'h03, {3'd0, gid, 5'd0}, 1'b1, half ? 20'd16 : 20'd32, 1'b0);
                    gcnt <= 6'd0;
                    st   <= S_R_WAIT;
                end
            end
            S_R_WAIT: begin
                if (e_rx_v) begin
                    gcnt <= gcnt + 6'd1;
                    if (!gcnt[0]) ghi <= e_rx_b;
                    else begin
                        n_we <= 1'b1;
                        n_wa <= (tgt == T_ALM) ? {2'b01, ~abuf, col[9:0]} : (tgt == T_PAGE) ? {1'b1, pgb, col} : {2'b00, ~wbuf, col[9:0]};
                        n_wd <= {ghi, e_rx_b};
                        col  <= col + 11'd1;
                        lc   <= (lc == lw - 10'd1) ? 10'd0 : (lc + 10'd1);
                    end
                end
                if (!e_busy && !e_go) st <= S_R_CHAR;
            end
            S_R_PAD: begin
                n_we <= 1'b1;
                n_wa <= (tgt == T_PAGE) ? {1'b1, pgb, col} : {2'b01, ~abuf, col[9:0]};
                n_wd <= 16'd0;
                col  <= col + 11'd1;
                if (lc == lw - 10'd1) begin lc <= 10'd0; st <= S_R_READ; end
                else                         lc <= lc + 10'd1;
            end
            S_R_END: begin
                fl_req <= 1'b0;
                if ((tgt == T_PAGE) && trunc && !psm) begin  // 【自动字号】大字放不下：从头按小字重排（还是这块缓冲，没在显示）
                    psm    <= 1'b1;
                    p      <= 9'd2;
                    col    <= 11'd0;
                    trunc  <= 1'b0;
                    lc     <= 10'd0;
                    fl_req <= 1'b1;
                    rdw    <= 2'd2;                     // 等 at_end 跟上新的 p
                    st     <= S_R_CHAR;
                end else if (tgt == T_PAGE) begin            // 【启事】启事页画好了：记下这块画的是什么，告诉调度
                    tgt     <= T_NTC;
                    rsrc    <= 1'b0;
                    if (pph) begin                           // 【串口照片】文字画好了，再把照片写进 SDRAM（col 留到最后记）
                        fl_req <= 1'b1;
                        ph_ab  <= 1'b0;
                        st     <= S_PH_REQ;
                    end else begin
                        if (pgb) pm1 <= {psm, 1'b0, q_ty_s, col, q_idx, q_tot}; else pm0 <= {psm, 1'b0, q_ty_s, col, q_idx, q_tot};
                        pg_done <= 1'b1;
                        st      <= S_IDLE;
                    end
                end else if (tgt == T_ALM) begin             // 【三级应急】文字画好了再切等级（画面一出来就有字）
                    tgt       <= T_NTC;
                    abuf      <= ~abuf;
                    alen      <= col[9:0];
                    alarm_lvl <= plvl;
                    reply(R_OK_ALM1 + {5'd0, plvl} - 7'd1);
                end else if (csr) begin                      // 【自定义字幕】画好了：切到这块，字幕条从右端重新进入（不回复）
                    csr     <= 1'b0;
                    rsrc    <= 1'b0;
                    wbuf    <= ~wbuf;
                    ntc_len <= col;
                    cs_ok   <= 1'b1;
                    new_tgl <= ~new_tgl;
                    rdw     <= 2'd2;                         // 等 cs_want 跟上 cs_ok，免得马上又画一遍
                    st      <= S_IDLE;
                end else if (col == 11'd0)
                    reply(R_ERR_EMPTY);
                else begin
                    cs_ok   <= 1'b0;                         // 【自定义字幕】通知 RAM 让给通知
                    wbuf    <= ~wbuf;
                    ntc_on  <= 1'b1;
                    ntc_len <= col;
                    new_tgl <= ~new_tgl;
                    reply(trunc ? R_OK_TRUNC : R_OK_NOTICE);
                end
            end

            // ---------------- 校验字库：读标记页，再读回全部数据算 CRC ----------------
            S_V_REQ: begin
                if (fl_off) begin
                    font_ok <= 1'b0; font_status <= 2'd3;
                    st <= in_install ? S_I_FAIL : S_IDLE;
                end else begin
                    fl_req <= 1'b1;
                    if (fl_grant) begin
                        spi(8'h03, {f_hi, mk_pg, 8'd0}, 1'b1, 20'd20, 1'b0);
                        tj <= 5'd0; tr_bad <= 1'b0;
                        st <= S_V_MARKW;
                    end
                end
            end
            S_V_MARKW: begin
                if (e_rx_v) begin
                    tj <= tj + 5'd1;
                    if (!tj[4]) begin
                        if (e_rx_b != mk_exp(tj[3:0], ph)) tr_bad <= 1'b1;
                    end else
                        tr_crc <= {tr_crc[23:0], e_rx_b};
                end
                if (!e_busy && !e_go) begin
                    if (tr_bad) st <= S_V_END;
                    else begin
                        crc <= 32'hFFFFFFFF;
                        spi(8'h03, {f_hi, 20'd0}, 1'b1, d_bytes, 1'b0);
                        st <= S_V_DATAW;
                    end
                end
            end
            S_V_DATAW: begin
                if (e_rx_v) begin c_sh <= e_rx_b; c_n <= 4'd8; end
                if (!e_busy && !e_go && (c_n == 4'd0) && !e_rx_v) begin
                    if (crc != tr_crc) tr_bad <= 1'b1;
                    st <= S_V_END;
                end
            end
            S_V_END: begin
                fl_req      <= 1'b0;
                if (ph) begin                                // 【串口照片】读回校验完：记下这一条带照片，存进启事扇区，马上插播
                    ph         <= 1'b0;
                    in_install <= 1'b0;
                    if (tr_bad) reply(R_PH_BAD);
                    else begin
                        q_ph[phs]  <= 1'b1;
                        q_we <= 1'b1; q_wa <= {1'b0, phs, 9'd0}; q_wd <= {2'd0, q_lens[phs * 9 + 8], 1'b1, 2'd0, q_tys[{phs, 1'b0} +: 2]};
                        q_new      <= 1'b1;
                        q_new_slot <= phs;
                        q_rsp      <= R_PH_OK;
                        st         <= S_QSV;
                    end
                end else begin
                    font_ok     <= !tr_bad;
                    font_status <= tr_bad ? 2'd2 : 2'd1;
                    if (in_install) begin
                        in_install <= 1'b0;
                        reply(tr_bad ? R_FONT_BAD : R_FONT_OK);
                    end else
                        st <= S_IDLE;
                end
            end

            // ---------------- 装字库 ----------------
            S_I_REQ: begin
                fl_req <= 1'b1;
                if (ph) q_ph[phs] <= 1'b0;                   // 【串口照片】这一条原来的照片作废
                else begin font_ok <= 1'b0; font_status <= 2'd2; end   // 擦掉以后字库就不能用了
                if (fl_grant) begin blk <= 4'd0; st <= S_I_WREN; end
            end
            S_I_WREN: begin spi(8'h06, 24'd0, 1'b0, 20'd0, 1'b0); st <= S_I_ERASE; end
            S_I_ERASE: if (!e_busy && !e_go) begin
                spi(8'hD8, {f_hi, blk, 16'd0}, 1'b1, 20'd0, 1'b0);   // 【修正】64KB 块地址 = 块号 × 64K（原来误写成 × 1M，只擦到了第 0 块）
                op_ms <= 12'd0;
                ret   <= S_I_ERASE;
                st    <= S_I_POLL;
            end
            // 查忙（05），完了回 ret：擦除 → 下一块 / READY；编程 → 接着收
            S_I_POLL: if (!e_busy && !e_go) begin spi(8'h05, 24'd0, 1'b0, 20'd1, 1'b0); st <= S_I_POLLW; end
            S_I_POLLW: begin
                if (e_rx_v) poll_busy <= e_rx_b[0];
                if (!e_busy && !e_go && !e_rx_v) begin
                    if (poll_busy) begin
                        if (op_to) st <= qsv ? S_QSV_FAIL : S_I_FAIL;   // 【启事】存启事超时不动字库
                        else                  st <= S_I_POLL;
                    end else if (ret == S_I_ERASE) begin
                        if (blk == (ph ? PH_NBLK : NBLK) - 4'd1) begin
                            // 擦完：开始收文件
                            fmode <= 1'b1; frst <= 1'b1; fcnt <= 20'd0; rx_ms <= 16'd0; pg_pend <= 2'b00;
                            tr_done <= 1'b0; tr_bad <= 1'b0; crc <= 32'hFFFFFFFF;
                            rsid <= ph ? R_PH_READY : R_FONT_READY; reply_ret <= S_I_RX; st <= S_REPLY;
                        end else begin
                            blk <= blk + 4'd1;
                            st  <= S_I_WREN;
                        end
                    end else
                        st <= ret;
                end
            end
            S_I_RX: begin
                fl_req <= 1'b1;
                if (tr_bad || (rx_ms >= (frst ? FIRST_MS : BYTE_MS))) begin
                    fmode <= 1'b0;
                    st    <= S_I_FAIL;
                end else if (pg_pend != 2'b00) begin
                    prog_half <= pg_pend[0] ? 1'b0 : 1'b1;
                    st <= S_I_PWREN;
                end else if (tr_done) begin
                    fmode   <= 1'b0;
                    crc_rx  <= crc;
                    tj      <= 5'd0;
                    tr_bad  <= 1'b0;
                    st      <= S_I_TRCHK;
                end
            end
            S_I_PWREN: begin spi(8'h06, 24'd0, 1'b0, 20'd0, 1'b0); st <= S_I_PROG; end
            S_I_PROG: if (!e_busy && !e_go) begin
                e_half <= prog_half;
                spi(8'h02, {f_hi, (prog_half ? pg_num1 : pg_num0), 8'd0}, 1'b1, 20'd256, 1'b1);
                pg_pend[prog_half] <= 1'b0;
                op_ms <= 12'd0;
                ret   <= in_install ? S_V_REQ : S_I_RX;     // 标记页编完：读回校验
                st    <= S_I_POLL;
            end
            // 标记页（在 tr_half 半区）：核对开头 16 字节和 CRC
            S_I_TRCHK: begin
                if (c_n == 4'd0) begin                        // 最后一个数据字节的 CRC 算完
                    crc_rx <= crc;
                    p_ra   <= {tr_half, 3'd0, tj};
                    rdw    <= 2'd2;
                    st     <= S_I_TRCHKW;
                end
            end
            S_I_TRCHKW: begin
                if (!tj[4]) begin
                    if (lb_q != mk_exp(tj[3:0], ph)) tr_bad <= 1'b1;
                end else case (tj[1:0])
                    2'd0: if (lb_q != crc_rx[31:24])       tr_bad <= 1'b1;
                    2'd1: if (lb_q != crc_rx[23:16])       tr_bad <= 1'b1;
                    2'd2: if (lb_q != crc_rx[15:8])        tr_bad <= 1'b1;
                    default: if (lb_q != crc_rx[7:0])      tr_bad <= 1'b1;
                endcase
                if (tj == 5'd19) st <= S_I_TRCHKD;
                else begin tj <= tj + 5'd1; st <= S_I_TRCHK; end
            end
            S_I_TRCHKD: begin
                if (tr_bad) begin
                    fl_req <= 1'b0;
                    ph     <= 1'b0;
                    reply(ph ? R_PH_BAD : R_FONT_BAD);
                end else begin
                    // 标记页写进 Flash，然后按上电时一样读回校验
                    pg_num0 <= mk_pg; pg_num1 <= mk_pg;
                    pg_pend <= 2'b00;
                    prog_half <= tr_half;
                    in_install <= 1'b1;
                    st <= S_I_PWREN;
                    tr_done <= 1'b0;
                end
            end
            S_I_FAIL: begin
                fmode  <= 1'b0;
                fl_req <= 1'b0;
                in_install <= 1'b0;
                ph <= 1'b0;
                if (ph) reply(R_PH_BROKEN);                  // 【串口照片】照片没装好不影响字库
                else begin
                    font_ok <= 1'b0;
                    font_status <= fl_off ? 2'd3 : 2'd2;
                    reply(R_FONT_BROKEN);
                end
            end
            // ======================= 【启事】 =======================
            // ---------------- 上电读回 4 条启事（1024 字节），标记 "QS01" 对才算数 ----------------
            //   【自定义字幕】qb = 1 时读字幕扇区（标记 "SB01"）进 qram 后一半
            S_QL_REQ: begin
                if (fl_off) st <= S_V_REQ;
                else begin
                    fl_req <= 1'b1;
                    if (fl_grant) begin
                        spi(8'h03, qb ? S_ADDR : Q_ADDR, 1'b1, qb ? 20'd1024 : 20'd2048, 1'b0);
                        fcnt <= 20'd0; tr_bad <= 1'b0;
                        st <= S_QL_RD;
                    end
                end
            end
            S_QL_RD: begin
                if (e_rx_v) begin
                    q_we <= 1'b1; q_wa <= qb ? {2'b10, fcnt[9:0]} : {1'b0, fcnt[10:0]}; q_wd <= e_rx_b;
                    fcnt <= fcnt + 20'd1;
                    if ((fcnt[8:0] == 9'd0) && !qb) begin    // 类别字节：低 2 位类别，【串口照片】第 4 位 = 带照片，【自动字号】第 5 位 = 字节数第 8 位
                        q_tys[{fcnt[10:9], 1'b0} +: 2] <= ((e_rx_b & 8'hCC) != 8'd0) ? 2'd0 : e_rx_b[1:0];
                        q_ph[fcnt[10:9]]               <= ((e_rx_b & 8'hCC) == 8'd0) && e_rx_b[4];
                        q_lens[fcnt[10:9] * 9 + 8]     <= e_rx_b[5];
                    end
                    if ((fcnt[8:0] == 9'd1) && !qb) q_lens[fcnt[10:9] * 9 +: 8] <= e_rx_b;
                    if ((fcnt[7:0] == 8'd0) && qb) s_f[fcnt[9:8]] <= (e_rx_b == 8'd1);       // 【自定义字幕】
                    if ((fcnt[7:0] == 8'd1) && qb) s_lens[{fcnt[9:8], 3'b000} +: 8] <= e_rx_b;
                    // 【自动字号】标记在最后 4 个字节：启事 "QS02" 在 2044~2047，字幕 "SB01" 在 1020~1023
                    if (qb ? (fcnt[10:2] == 9'h0FF) : (fcnt[10:2] == 9'h1FF)) case (fcnt[1:0])
                        2'd0: if (e_rx_b != (qb ? "S" : "Q")) tr_bad <= 1'b1;
                        2'd1: if (e_rx_b != (qb ? "B" : "S")) tr_bad <= 1'b1;
                        2'd2: if (e_rx_b != "0") tr_bad <= 1'b1;
                        default: if (e_rx_b != (qb ? "1" : "2")) tr_bad <= 1'b1;
                    endcase
                end
                if (!e_busy && !e_go && !e_rx_v) st <= S_QL_CHK;
            end
            S_QL_CHK: begin                                  // 类别 1~3、字节数 1~Q_MAX 才是有效的一条；标记不对全部作废
                if (!qb) begin
                    q_mask[0] <= !tr_bad && (q_tys[1:0] != 2'd0) && (q_lens[8:0]   != 9'd0) && (q_lens[8:0]   <= Q_MAXN);
                    q_mask[1] <= !tr_bad && (q_tys[3:2] != 2'd0) && (q_lens[17:9]  != 9'd0) && (q_lens[17:9]  <= Q_MAXN);
                    q_mask[2] <= !tr_bad && (q_tys[5:4] != 2'd0) && (q_lens[26:18] != 9'd0) && (q_lens[26:18] <= Q_MAXN);
                    q_mask[3] <= !tr_bad && (q_tys[7:6] != 2'd0) && (q_lens[35:27] != 9'd0) && (q_lens[35:27] <= Q_MAXN);
                    qb <= 1'b1;
                    st <= S_QL_REQ;                          // 【自定义字幕】再读字幕扇区
                end else begin                               // 【自定义字幕】[0] = 1、字节数 1~Q_MAX 才算数
                    s_mask[0] <= !tr_bad && s_f[0] && (s_lens[7:0]   != 8'd0) && (s_lens[7:0]   <= Q_MAX);
                    s_mask[1] <= !tr_bad && s_f[1] && (s_lens[15:8]  != 8'd0) && (s_lens[15:8]  <= Q_MAX);
                    s_mask[2] <= !tr_bad && s_f[2] && (s_lens[23:16] != 8'd0) && (s_lens[23:16] <= Q_MAX);
                    s_mask[3] <= !tr_bad && s_f[3] && (s_lens[31:24] != 8'd0) && (s_lens[31:24] <= Q_MAX);
                    qb <= 1'b0;
                    qk <= 2'd0;
                    st <= S_PM;                              // 【串口照片】核对照片标记，再校验字库
                end
            end

            // ---------------- 发布：寻人 / 寻物 / 招领 [启事] [：] 内容 ----------------
            S_QK2: begin csid <= K_QLIST; cj <= 8'd0; cmatch <= 1'b1; st <= S_CMP; end
            S_QPUB: begin
                if (at_end)                reply(R_ERR_EMPTY);
                else if (fl_off)           reply(R_ERR_FLASH);
                else if (!font_ok)         reply(R_ERR_NOFONT);
                else if (q_mask == 4'hF)   reply(R_ERR_QFULL);
                else begin q_slot <= q_free; qi <= 9'd0; qcols <= 12'd0; st <= S_QCP; end
            end
            // 原文抄进启事 RAM 第 q_slot 条的 [2..]；顺便估一下要画多少列（ASCII 8 列，其余 16 列，换行补的空列不算）
            S_QCP: begin p_ra <= p; rdw <= 2'd2; st <= S_QCP_W; end
            S_QCP_W: begin
                q_we  <= 1'b1;
                q_wa  <= qb ? {2'b10, q_slot, qi[7:0] + 8'd2} : {1'b0, q_slot, qi + 9'd2};
                q_wd  <= lb_q;
                qcols <= qcols + ((lb_q[7] == 1'b0) ? 12'd8 : (lb_q[7:6] == 2'b11) ? 12'd16 : 12'd0);
                qi    <= qi + 9'd1;
                p     <= p + 9'd1;
                if ((p + 9'd1 >= llen) || (qi + 9'd1 >= (qb ? {1'b0, Q_MAX} : Q_MAXN))) st <= S_QHDR;
                else                                            st <= S_QCP;
            end
            S_QHDR: begin q_we <= 1'b1; q_wa <= qb ? {2'b10, q_slot, 8'd0} : {1'b0, q_slot, 9'd0}; q_wd <= qb ? 8'd1 : {2'd0, qi[8], 3'd0, qtype}; st <= S_QHDR2; end
            S_QHDR2: begin
                q_we <= 1'b1; q_wa <= qb ? {2'b10, q_slot, 8'd1} : {1'b0, q_slot, 9'd1}; q_wd <= qi[7:0];
                if (qb) begin                                // 【自定义字幕】这张图的字幕换了：正在显示的话重新画
                    s_lens[{q_slot, 3'b000} +: 8] <= qi[7:0];
                    s_mask[q_slot] <= 1'b1;
                    if (cs_slot == q_slot) cs_ok <= 1'b0;
                    q_rsp <= (qcols > 12'd1024) ? R_SUB_LONG : R_SUB_OK;
                end else begin
                    q_tys[{q_slot, 1'b0} +: 2]    <= qtype;
                    q_lens[q_slot * 9 +: 9] <= qi;
                    q_mask[q_slot] <= 1'b1;
                    q_ph[q_slot]   <= 1'b0;                  // 【串口照片】新启事没有照片
                    q_new      <= 1'b1;                      // 马上插播（调度会再发 pg_req 来画）
                    q_new_slot <= q_slot;
                    q_rsp      <= (qcols > PS_COLS) ? R_OK_QLONG : (R_OK_Q1 + {5'd0, q_slot});   // 【自动字号】小字也放不下才提示
                end
                line_ok <= 1'b0; llen <= 9'd0; idle_ms <= 5'd0; lfree <= 1'b1;   // 原文抄完了，存 Flash 时可以收下一条
                st <= S_QSV;
            end

            // ---------------- 撤销n / 撤销全部 ----------------
            S_QDEL: if (!at_end && (b0 >= "1") && (b0 <= "4")) begin
                qd  <= b0[1:0] - 2'd1;                       // "1"~"4" → 0~3
                p   <= p + 9'd1;
                ret <= S_TAIL;
                st  <= S_GET;
            end else
                reply(R_ERR_QNONE);
            S_QCLR: begin                                    // qclr 里的几条：类别写 0
                if (qclr[qk]) begin
                    q_we <= 1'b1; q_wa <= {1'b0, qk, 9'd0}; q_wd <= 8'd0;
                    q_mask[qk] <= 1'b0;
                    q_tys[{qk, 1'b0} +: 2] <= 2'd0;
                    q_ph[qk] <= 1'b0;
                end
                qk <= qk + 2'd1;
                if (qk == 2'd3) begin
                    line_ok <= 1'b0; llen <= 9'd0; idle_ms <= 5'd0; lfree <= 1'b1;
                    st <= S_QSV;
                end
            end

            // ---------------- 存 Flash：写标记 → 擦扇区 → 编 4 页 → 回复 q_rsp ----------------
            S_QSV: begin qsv <= 1'b1; qk <= 2'd0; st <= S_QSV_MAG; end
            S_QSV_MAG: begin                                 // 【自定义字幕】qb = 1：存字幕扇区，标记 "SB01"
                q_we <= 1'b1;
                q_wa <= qb ? ({2'b10, 10'd1020} + {10'd0, qk}) : (12'd2044 + {10'd0, qk});   // 【自动字号】启事 "QS02"
                q_wd <= (qk == 2'd0) ? (qb ? "S" : "Q") : (qk == 2'd1) ? (qb ? "B" : "S") : (qk == 2'd2) ? "0" : (qb ? "1" : "2");
                qk   <= qk + 2'd1;
                if (qk == 2'd3) st <= S_QSV_REQ;
            end
            S_QSV_REQ: begin
                if (fl_off) st <= S_QSV_FAIL;
                else begin
                    fl_req <= 1'b1;
                    if (fl_grant) st <= S_QSV_WREN;
                end
            end
            S_QSV_WREN: begin spi(8'h06, 24'd0, 1'b0, 20'd0, 1'b0); st <= S_QSV_ER; end
            S_QSV_ER: if (!e_busy && !e_go) begin
                spi(8'h20, qb ? S_ADDR : Q_ADDR, 1'b1, 20'd0, 1'b0);   // 擦 4KB 扇区
                op_ms <= 12'd0;
                q_pg  <= 3'd0;
                ret   <= S_QSV_PWREN;
                st    <= S_I_POLL;
            end
            S_QSV_PWREN: begin spi(8'h06, 24'd0, 1'b0, 20'd0, 1'b0); st <= S_QSV_PROG; end
            S_QSV_PROG: if (!e_busy && !e_go) begin
                e_q   <= 1'b1;
                spi(8'h02, (qb ? S_ADDR : Q_ADDR) + {13'd0, q_pg, 8'd0}, 1'b1, 20'd256, 1'b1);
                op_ms <= 12'd0;
                ret   <= S_QSV_NEXT;
                st    <= S_I_POLL;
            end
            S_QSV_NEXT: begin
                e_q <= 1'b0;
                if (q_pg == (qb ? 3'd3 : 3'd7)) st <= S_QSV_END;        // 【自动字号】启事 8 页，字幕 4 页
                else begin q_pg <= q_pg + 3'd1; st <= S_QSV_PWREN; end
            end
            S_QSV_END:  begin fl_req <= 1'b0; qsv <= 1'b0; reply(q_rsp); end
            S_QSV_FAIL: begin fl_req <= 1'b0; qsv <= 1'b0; e_q <= 1'b0; reply(R_ERR_QSAVE); end

            // ---------------- 列表：每条 “n、” + （类别 + 原文 + 换行 / “（空）”） ----------------
            S_LS: case (lsph)
                3'd0: begin rsid <= R_LS_N1 + {5'd0, lsk}; reply_ret <= S_LS; lsph <= 3'd1; st <= S_REPLY; end
                3'd1: if (q_mask[lsk]) begin
                          rsid <= R_LS_T1 + {5'd0, q_tys[{lsk, 1'b0} +: 2]} - 7'd1; reply_ret <= S_LS; lsph <= 3'd2; st <= S_REPLY;
                      end else begin
                          rsid <= R_LS_EMPTY; reply_ret <= S_LS; lsph <= 3'd5; st <= S_REPLY;
                      end
                3'd2: if (!tx_run && !reply_go) begin        // 上一段发完了，发原文
                          qtx_go   <= 1'b1;
                          qtx_slot <= lsk;
                          qtx_len  <= q_lens[lsk * 9 +: 9];
                          lsph     <= 3'd3;
                      end
                3'd3: lsph <= 3'd4;                          // 等一拍 tx_run 起来
                3'd4: begin rsid <= R_LS_EOL; reply_ret <= S_LS; lsph <= 3'd5; st <= S_REPLY; end   // S_REPLY 会等原文发完
                default: begin
                    lsph <= 3'd0;
                    if (lsk == 2'd3) begin lsact <= 1'b0; st <= S_IDLE; end
                    else lsk <= lsk + 2'd1;
                end
            endcase

            // ---------------- 画启事页：第 q_slot 条画进缓冲 pgb ----------------
            S_PG: begin
                if (fl_off || !font_ok || !q_mask[q_slot]) begin   // 画不了：只有标题、没有正文
                    if (pgb) pm1 <= {2'b00, q_ty_s, 11'd0, q_idx, q_tot}; else pm0 <= {2'b00, q_ty_s, 11'd0, q_idx, q_tot};
                    pg_done <= 1'b1;
                    st      <= S_IDLE;
                end else begin
                    rsrc <= 1'b1; p <= 9'd2; plen <= q_len_s + 9'd2;
                    psm  <= 1'b0;                            // 【自动字号】先按大字排
                    pph  <= q_ph[q_slot];                    // 【串口照片】
                    col <= 11'd0; trunc <= 1'b0; lc <= 9'd0; tgt <= T_PAGE; fl_req <= 1'b1;
                    st <= S_R_REQ;
                end
            end
            // ======================= 【串口照片】 =======================
            // ---------------- 上电：带照片的启事核对照片标记页开头 8 字节（装到一半断电的照片作废） ----------------
            S_PM: begin
                if (q_ph[qk] && q_mask[qk]) begin
                    spi(8'h03, {4'd2 + {2'd0, qk}, PH_MKPG, 8'd0}, 1'b1, 20'd8, 1'b0);
                    tj <= 5'd0; tr_bad <= 1'b0;
                    st <= S_PM_RD;
                end else begin
                    q_ph[qk] <= 1'b0;
                    qk <= qk + 2'd1;
                    if (qk == 2'd3) st <= S_V_REQ;
                end
            end
            S_PM_RD: begin
                if (e_rx_v) begin
                    tj <= tj + 5'd1;
                    if (e_rx_b != mk_exp(tj[3:0], 1'b1)) tr_bad <= 1'b1;
                end
                if (!e_busy && !e_go && !e_rx_v) begin
                    if (tr_bad) q_ph[qk] <= 1'b0;
                    qk <= qk + 2'd1;
                    st <= (qk == 2'd3) ? S_V_REQ : S_PM;
                end
            end
            // ---------------- 启事页带照片：文字画好后，读 Flash 里的照片，2×2 平均缩成 360×320，写进 SDRAM 照片缓冲 pgb ----------------
            //   PHOTO.BIN 按缩小后的像素排：从最下面一行到最上面一行（和 BMP 一样，SDRAM 写口会上下翻过来），每行 360 个，
            //   每个 = 原图 2×2 的 4 个像素（各 RGB565，高字节在前）共 8 字节，所以每行 2880 字节，一行发一次读命令。
            //   565 先扩成 888（高位补到低位）再求 4 个的平均（四舍五入）。
            //   SDRAM 一行写 640 个像素：照片在 PX0 ~ PX0+359，两边补黑（启事页只在照片框里用 SDRAM 的画面），6 拍一个
            S_PH_REQ: begin
                ph_need <= 1'b1;                             // 要用 SDRAM 写口：sd_card_bmp4 没在载图时给
                if (line_ok) begin                           // 等的时候来了新指令：这次先不画照片
                    ph_ab <= 1'b1;
                    st    <= S_PH_END;
                end else if (ph_grant) begin
                    tj    <= 5'd0;
                    op_ms <= 12'd0;
                    st    <= S_PH_GW;
                end
            end
            S_PH_GW: begin                                   // 等写地址 / 长度到 SDRAM 那边稳定下来
                tj <= tj + 5'd1;
                if (tj == 5'd31) begin ph_wreq <= 1'b1; st <= S_PH_ACK; end
            end
            S_PH_ACK: if (ph_wack) begin
                ph_wreq     <= 1'b0;
                ph_fin_seen <= 1'b0;
                ph_row      <= 9'd0;
                ph_a        <= {4'd2 + {2'd0, q_slot}, 20'd0};
                tj          <= 5'd0;
                st          <= S_PH_AW;
            end else if (op_to) begin                        // SDRAM 写口一直不应答（不会发生）：不画照片
                ph_wreq <= 1'b0;
                ph_ab   <= 1'b1;
                st      <= S_PH_END;
            end
            S_PH_AW: begin                                   // 写口应答后 SDRAM 那边要清 FIFO：等一会儿再写第一个像素
                tj <= tj + 5'd1;
                if (tj == 5'd31) st <= S_PH_ROW;
            end
            S_PH_ROW: begin
                if (!ph_ab) spi(8'h03, ph_a, 1'b1, 20'd2880, 1'b0);
                ph_x <= 10'd0; ph_pc <= 3'd0; ph_ch <= 2'd0; ph_k <= 2'd0; px_rdy <= 1'b0;
                ph_sr <= 10'd0; ph_sg <= 10'd0; ph_sb <= 10'd0;
                st <= S_PH_PIX;
            end
            S_PH_PIX: begin
                if (line_ok) ph_ab <= 1'b1;                  // 来了新指令：剩下的都写黑（写够数 SDRAM 那边才结束），这次按没照片显示
                ph_pc <= (ph_pc == 3'd5) ? 3'd0 : (ph_pc + 3'd1);
                if ((ph_x != 10'd640) && (ph_pc == 3'd0)) begin
                    if (ph_ab || (ph_x < PX0) || (ph_x >= PX0 + PXW)) begin
                        ph_we <= 1'b1; ph_px <= 24'd0; ph_x <= ph_x + 10'd1;
                    end else if (px_rdy) begin
                        ph_we <= 1'b1; ph_px <= px_r; px_rdy <= 1'b0; ph_x <= ph_x + 10'd1;
                    end
                end
                if (e_rx_v) begin                            // 4 个 RGB565 像素：扩成 888 分别累加，第 8 个字节到了就出一个平均值
                    ph_ch <= {1'b0, ~ph_ch[0]};
                    if (!ph_ch[0])
                        ph_hi <= e_rx_b;
                    else begin
                        ph_k <= ph_k + 2'd1;
                        if (ph_k == 2'd3) begin
                            px_r   <= {rnd4(ph_sr + {2'd0, c5to8(ph_hi[7:3])}),
                                       rnd4(ph_sg + {2'd0, c6to8({ph_hi[2:0], e_rx_b[7:5]})}),
                                       rnd4(ph_sb + {2'd0, c5to8(e_rx_b[4:0])})};
                            px_rdy <= 1'b1;
                            ph_sr  <= 10'd0; ph_sg <= 10'd0; ph_sb <= 10'd0;
                        end else begin
                            ph_sr  <= ph_sr + {2'd0, c5to8(ph_hi[7:3])};
                            ph_sg  <= ph_sg + {2'd0, c6to8({ph_hi[2:0], e_rx_b[7:5]})};
                            ph_sb  <= ph_sb + {2'd0, c5to8(e_rx_b[4:0])};
                        end
                    end
                end
                if ((ph_x == 10'd640) && !e_busy && !e_go) begin
                    ph_a   <= ph_a + 24'd2880;
                    ph_row <= ph_row + 9'd1;
                    if (ph_row == PH_ROWS - 1) begin op_ms <= 12'd0; rdw <= 2'd2; st <= S_PH_FIN; end   // rdw：等 op_to 跟上清零的 op_ms
                    else st <= S_PH_ROW;
                end
            end
            S_PH_FIN: begin                                  // 等 SDRAM 那边写完（frame_fifo_write 的 write_finish）
                if (ph_fin_seen)  st <= S_PH_END;
                else if (op_to) begin ph_ab <= 1'b1; st <= S_PH_END; end
            end
            S_PH_END: begin
                ph_need <= 1'b0;
                fl_req  <= 1'b0;
                if (pgb) pm1 <= {psm, !ph_ab, q_ty_s, col, q_idx, q_tot}; else pm0 <= {psm, !ph_ab, q_ty_s, col, q_idx, q_tot};
                pg_done <= 1'b1;
                ph_ab   <= 1'b0;
                st      <= S_IDLE;
            end
            // ======================= 【自定义字幕】字幕n [内容] =======================
            S_SUBN: if (!at_end && (b0 >= "1") && (b0 <= "4")) begin
                qd  <= b0[1:0] - 2'd1;                       // "1"~"4" → 0~3
                p   <= p + 9'd1;
                ret <= S_SUBB;
                st  <= S_GET;
            end else
                reply(R_SUB_BADN);
            S_SUBB: begin
                qb <= 1'b1;
                if (at_end) begin                            // 只写图号：恢复默认字幕（[0] 写 0，存 Flash）
                    q_we <= 1'b1; q_wa <= {2'b10, qd, 8'd0}; q_wd <= 8'd0;
                    s_mask[qd] <= 1'b0;
                    if (cs_slot == qd) cs_ok <= 1'b0;
                    line_ok <= 1'b0; llen <= 9'd0; idle_ms <= 5'd0; lfree <= 1'b1;
                    q_rsp <= R_SUB_DEF;
                    st    <= S_QSV;
                end else if (fl_off)  reply(R_ERR_FLASH);
                else if (!font_ok)    reply(R_ERR_NOFONT);
                else begin q_slot <= qd; qi <= 9'd0; qcols <= 12'd0; st <= S_QCP; end   // 和发布启事一样抄进 RAM、存 Flash
            end
            default: st <= S_IDLE;
        endcase

        // ---------------- 【按键改造】按键 / 干接点一级应急、消音（写在状态机后面：同一拍里优先） ----------------
        //   按键 / 干接点进一级时没有文字（alen = 0）：警示页显示英文大字，或者 EMERG.BMP
        if (k_alarm) begin
            alen <= 10'd0;
            alarm_lvl <= (alarm_lvl != 2'd0) ? 2'd0 : 2'd1;
        end else if (x_alarm && (alarm_lvl != 2'd1)) begin
            alen <= 10'd0;
            alarm_lvl <= 2'd1;
        end
        lvl_d <= eff_lvl;
        if (eff_lvl != lvl_d) muted <= 1'b0;             // 等级变了（升级 / 降级 / 解除）：恢复声音
        else if (k_mute && (eff_lvl != 2'd0)) muted <= 1'b1;

    end
end

// ======================= 给显示：打三拍到 video_clk，连续两拍相同才用 =======================
// 通知 RAM 的读口用同步后的 v_wbuf：切换比写完晚几拍，新内容早就写好了
// 【三级应急】实际等级 = SW1 打开就是一级；三级时普通通知暂停显示
// 【自定义字幕】cs_ok（只在没有应急时用：三级时读口可能给应急文字）和 cs_slot 一起同步；
//   v_cs = 通知 RAM 里正好是正在显示的这张图的字幕
wire [32:0] v_src = {cs_ok && (eff_lvl == 2'd0), cs_slot,
                     muted, eff_lvl, alen, abuf, ntc_on && (eff_lvl != 2'd3), ntc_len, wbuf, new_tgl, rej_tgl, sub_off};
reg  [32:0] vs1, vs2, vs3;
reg         v_new_t, v_rej_t;
reg         v_on_r;
reg  [10:0] v_len_r;
reg         v_cs_ok;
reg  [1:0]  v_cs_slot;
wire [1:0]  v_shown_i = v_shown[1:0] - 2'd1;
// 【启事】启事页上不显示底部通知条（读口给启事页用）
// 【应急改版】有应急文字（一 / 二 / 三级）：字幕条滚动应急文字；应急但没有文字：一 / 二级显示固定应急字幕、
//   三级显示图片字幕；普通通知只在没有应急时显示
wire   v_atk = (v_alm != 2'd0) && (v_alen != 10'd0);
assign v_on  = (v_atk || (v_on_r && (v_alm == 2'd0))) && !pv_sel;
assign v_len = v_atk ? {1'b0, v_alen} : v_len_r;
always @(posedge vclk or negedge vrst_n) begin
    if (!vrst_n) begin
        vs1 <= 33'd0; vs2 <= 33'd0; vs3 <= 33'd0; v_mute <= 1'b0; v_alm <= 2'd0; v_alen <= 10'd0; v_abuf <= 1'b0;
        v_on_r <= 1'b0; v_len_r <= 11'd0; v_wbuf <= 1'b0; v_new_t <= 1'b0; v_rej_t <= 1'b0; v_sub_off <= 1'b0;
        v_new <= 1'b0; v_reject <= 1'b0; v_cs_ok <= 1'b0; v_cs_slot <= 2'd0; v_cs <= 1'b0;
    end else begin
        vs1 <= v_src; vs2 <= vs1; vs3 <= vs2;
        v_new    <= 1'b0;
        v_reject <= 1'b0;
        v_cs     <= v_cs_ok && (v_shown != 4'd0) && (v_shown_i == v_cs_slot) && !pv_sel;
        if (vs2 == vs3) begin
            v_cs_ok   <= vs3[32];
            v_cs_slot <= vs3[31:30];
            v_mute    <= vs3[29];
            v_alm     <= vs3[28:27];
            v_alen    <= vs3[26:17];
            v_abuf    <= vs3[16];
            v_on_r    <= vs3[15];
            v_len_r   <= vs3[14:4];
            v_wbuf    <= vs3[3];
            v_new_t   <= vs3[2];
            v_rej_t   <= vs3[1];
            v_sub_off <= vs3[0];
            if (vs3[2] != v_new_t) v_new    <= 1'b1;
            if (vs3[1] != v_rej_t) v_reject <= 1'b1;
            if ((vs3[16] != v_abuf) || (vs3[28:27] != v_alm)) v_new <= 1'b1;   // 【应急改版】应急文字 / 等级变了：字幕条从右端重新进入
        end
    end
end

// 【启事】两块启事页缓冲的内容说明（只在画完时变，那块缓冲那时没在显示）
reg  [41:0] pms1, pms2, pms3, v_pm;
always @(posedge vclk or negedge vrst_n) begin
    if (!vrst_n) begin
        pms1 <= 42'd0; pms2 <= 42'd0; pms3 <= 42'd0; v_pm <= 42'd0;
    end else begin
        pms1 <= {pm1, pm0}; pms2 <= pms1; pms3 <= pms2;
        if (pms2 == pms3) v_pm <= pms3;
    end
end
assign pv_meta = pv_buf ? v_pm[41:21] : v_pm[20:0];

endmodule
