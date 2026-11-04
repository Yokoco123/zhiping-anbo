`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// 四 bank 版播放控制（方案A：复用官方 frame_read_write 的 4 组地址）
// 端口与 sd_card_bmp 完全相同，顶层只需把模块名换成 sd_card_bmp4。
//
// 和双缓冲版的区别：
//   - 图片 k 固定写入 bank k（write_buf_idx = k），上电后后台依次预载全部图片
//   - 第一张载完立即显示，其余图片在后台继续加载，不影响当前画面
//   - 切换只改 disp_buf_idx，零加载延迟；官方读侧在每帧开始时才锁存 index，不撕裂
//   - 还没载完或载入失败的图片，切换时自动跳过
//   - 载入失败：重试 1 次，仍失败则标记该图失败，继续预载下一张
//
// 依赖：按键消抖 key_debounce_ms 在本文件末尾（【省资源】原来用 sd_card_bmp.v 里的 key_press_debounce）；
//       SD 读取模块用 fat32_bmp_read，换回 bmp_read 也能用。
// -----------------------------------------------------------------------------
module sd_card_bmp4 #(
    parameter integer CLK_FREQ_HZ       = 75_000_000,    // 【时序】sd_card_clk：100MHz → 83.33MHz → 75MHz（sys_pll C0；芯片用到 91% 后布局拥挤，留 1.3ns 余量）
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4,
    parameter integer LONG_PRESS_MS     = 1000,
    parameter integer LOAD_TIMEOUT_MS   = 15000,    // 单张图整体加载超时（大图 1920×1080 约 6MB，要读好几秒）
    parameter         SW_INVERT         = 1'b0      // 拨码读到 1 = 打开；上板发现方向反了就改成 1
)(
    input                       clk,
    input                       rst,
    input                       key_next,       // 板上 Key2：短按上一张 / 菜单上一项，长按进出缩略图
    input                       key_auto,       // 板上 Key4
    input                       key_prev,       // 板上 Key1：短按下一张 / 菜单下一项（长按 3 秒复位在顶层处理）；端口名保留旧名，免得改顶层
    input                       key_plus,       // 板上 KEY3：菜单里 +，正常模式 音乐暂停/继续
    input       [3:0]           sw,             // 拨码 SW1~SW4 原始电平（SW2 菜单、SW4 显示原图分辨率，SW1 / SW3 不用）
    output      [3:0]           sw_on,          // 【按键改造】{字幕开, 自动轮播开, SW2 菜单, 应急接管}（顶层原来按 SW1~SW4 用的地方不用改）
    input                       ext_alarm_n,    // 【按键改造】干接点外部告警：扩展口一脚，内部上拉，接地 = 一级应急
    output                      mute_on,        // 【按键改造】已消音（给数码管）
    output      [7:0]           bri_pct,        // 亮度 %
    output      [7:0]           con_pct,        // 对比度 %
    output      [7:0]           vol_pct,        // 音量 %
    output reg                  music_pause,    // 1 = 背景音乐暂停
    output      [2:0]           period_idx,     // 轮播周期档位 0~5 = 1/3/5/10/30/60 秒
    output      [1:0]           menu_sel,       // 菜单当前选中项 0 亮度 1 对比度 2 音量 3 轮播周期
    output reg                  tone_allow,     // 1 = 卡上没有 MUSIC.WAV，可以放琶音代替
    output reg                  write_emerg,    // 【应急模式】1 = 正在写 EMERG.BMP：顶层把 bank0 写地址换成应急 bank
    output                      emerg_ok,       // 【应急模式】EMERG.BMP 已完整载入应急 bank，并且现在是一级应急（二级“就地避险”不能显示疏散图，用内置橙色警示页）
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    output      [3:0]           state_code,
    output      [3:0]           img_num,
    output      [3:0]           err_code,
    output                      auto_on,        // 自动轮播状态（SW3），给 OSD 显示
    output reg                  thumb_mode,     // 1 = 2×2 缩略图浏览（img_idx 此时是焦点）
    output      [3:0]           loaded_mask,    // 哪几个 bank 已经载好
    output reg                  switch_auto,    // 1 = 最近一次切换来自自动轮播（转场用 Wipe）
    input                       trans_busy,     // video_clk 域：转场进行中，暂停轮播计时

    // 背景音乐字节流 → wav_player（同为 sd_card_clk 域）
    output                      music_byte_valid,
    output [7:0]                music_byte,
    output [31:0]               music_off,
    input                       music_hold,

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    output                      write_req,          // 【串口照片】载图和写照片共用（write_photo = 1 时是照片）
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO,

    // 【参数掉电保存】板上用户 Flash U33（W25Q64），和存比特流的配置 Flash 是两颗芯片
    output                      FLASH_CS_N,
    output                      FLASH_SCLK,
    output                      FLASH_MOSI,
    output                      FLASH_WP_N,
    output                      FLASH_HOLD_N,
    input                       FLASH_MISO,
    output      [3:0]           param_store_status,  // 给数码管：1 已载入 2 默认值 3 保存中 5 保存成功 E/F 出错
    output reg  [21:0]          boot_info,           // 【开机画面】开机自检用的状态 + 【拔卡恢复】卡被拔掉 + 【串口指令】字库状态（见文件末尾），boot_splash 同步后使用
    // 【串口指令】板载 CH340 串口（115200）：串口助手直接打字控制，字库在上面那颗 Flash 里（serial_cmd.v）
    input                       uart_rx,
    output                      uart_tx,
    // 通知点阵和状态给显示（video_clk 域，serial_cmd 内部已同步）
    input                       vclk,
    input                       vrst_n,
    input       [9:0]           ntc_col,
    output      [15:0]          ntc_bits,
    output                      ntc_on,
    output      [10:0]          ntc_len,
    output                      ntc_new,
    output                      ntc_reject,
    output                      ntc_sub_off,
    input       [3:0]           v_shown,        // 【自定义字幕】正在显示第几张图（video_transition 的 shown_num）
    output                      ntc_cs,         // 【自定义字幕】字幕条显示通知 RAM 里这张图的自定义字幕
    output      [33:0]          v_res,          // 【分辨率显示】video_clk 域给 OSD：{波形显示, 分辨率显示, 原图宽 BCD 4 位, 原图高 BCD 4 位}
    // 【三级应急】给应急画面（video_clk 域）：实际等级（SW1 打开 = 1）、应急文字（读口和 ntc_bits 共用）
    input       [9:0]           alm_col,
    output      [1:0]           alm_lvl,
    output      [9:0]           alm_len,
    output                      alm_mute,       // 【按键改造】已消音（video_clk 域，给警报声）
    // 【启事】轮播里插启事页：want_page / want_pbuf 给 video_transition（sd_card_clk 域，它自己同步），
    //   page_info = {显示启事页, 第几条 3 位, 共几条 3 位} 给数码管；启事页的读口和内容说明（video_clk 域）
    output reg                  want_page,
    output reg                  want_pbuf,
    output      [6:0]           page_info,
    input                       pv_sel,
    input                       pv_buf,
    input       [10:0]          pv_col,
    output      [20:0]          pv_meta,        // 【自动字号】最高位 = 小字
    // 【串口照片】serial_cmd 把启事照片写进 SDRAM 时借用写口：顶层据此把写地址 / 长度换成照片缓冲
    output reg                  write_photo,
    output                      write_pbuf
);

// 【省资源】按键长按、加载超时、拔卡恢复这些毫秒级的定时都数下面的 ms_tick（不再各用一个 32 位计数器数时钟拍）
// 轮播周期 6 档，在菜单里调，上电默认 3 秒
// 60 秒 = 60 亿拍，32 位放不下，所以轮播计时按毫秒数
localparam integer MS_CYCLES = CLK_FREQ_HZ / 1000;
reg [15:0] auto_play_ms;
always @(*) begin
    case (period_idx)
        3'd0:    auto_play_ms = 16'd1000;
        3'd1:    auto_play_ms = 16'd3000;
        3'd2:    auto_play_ms = 16'd5000;
        3'd3:    auto_play_ms = 16'd10000;
        3'd4:    auto_play_ms = 16'd30000;
        default: auto_play_ms = 16'd60000;
    endcase
end

// 1 毫秒节拍（按键消抖、长按、超时、巡检共用；fat32_bmp_read 和 param_adjust 也用它）
reg [16:0] ms_div;                  // 100MHz / 1000 = 100000 < 2^17
reg        ms_tick;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        ms_div  <= 17'd0;
        ms_tick <= 1'b0;
    end else if (ms_div >= MS_CYCLES - 1) begin
        ms_div  <= 17'd0;
        ms_tick <= 1'b1;
    end else begin
        ms_div  <= ms_div + 17'd1;
        ms_tick <= 1'b0;
    end
end

// ---------------------------------------------------------------------------
// 【按键改造】2026-10-28 拨码只留 SW2 菜单，其余都改成按键（和串口改同一个开关，谁后操作听谁的）：
//   Key1 短按下一张；按住 3 秒复位（顶层）          Key2 短按上一张；长按进出缩略图
//   KEY3 短按背景音乐暂停 / 继续（应急接管时 = 消音）；长按 1 秒 字幕和波形 开 / 关
//   Key4 短按自动轮播 开 / 关（缩略图里 = 选中）；长按 1 秒 一级应急 进入 / 解除
//   SW2 菜单打开时四个键照旧调参数（长按不触发上面的功能）
//   自动轮播、字幕、波形三个开关掉电保存（param_store）；KEY3 + Key2 同时按 = 波形开关，第一次用默认都开
//   干接点：ext_alarm_n 接地持续 3ms 以上 = 一级应急（锁住，断开也不自动解除，要按键或串口解除）
// 下面是原来的说明（拨码部分已经不用）：
// 拨码与按键（）：
//   SW1 应急模式  SW2 参数菜单  SW3 自动轮播  SW4 显示 OSD（拨开才显示状态条/字幕/波形）
//   上电默认：音乐暂停（KEY3 开始放），四个拨码全关 = 纯画面、手动翻页
//   正常模式：
//     Key1(key_prev) 短按下一张（缩略图里焦点往后移）
//     Key2(key_next) 短按上一张（缩略图里焦点往前移）、长按进出缩略图
//     KEY3(key_plus) 短按背景音乐暂停/继续
//     Key4(key_auto) 缩略图里短按“选中”；正常显示时暂时没有功能（留给以后的频谱切换）
//   菜单打开（SW2）：Key1 下一项，Key2 上一项，KEY3 加，Key4 减，翻页和缩略图暂停
//   统一规则：Key1 向前，Key2 向后（端口名 key_prev/key_next 是历史名字，没改）
// ---------------------------------------------------------------------------

// 拨码是滑动开关，电平不会悬空也不需要消抖，打两拍同步即可
reg [3:0] sw_s1, sw_s2;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        sw_s1 <= 4'd0;
        sw_s2 <= 4'd0;
    end else begin
        sw_s1 <= sw ^ {4{SW_INVERT}};
        sw_s2 <= sw_s1;
    end
end
wire       param_mode = sw_s2[1];      // SW2：参数菜单打开
reg        auto_st, osd_st;            // 【按键改造】自动轮播开、字幕开（在下面按键那一段更新）
reg        wave_st;                    // 【波形开关】音频波形开（KEY3 + Key2 同时按 / 串口 波形开关，掉电保存）
reg        res_on;                     // 【分辨率显示】拨码 SW4（拨开 = 显示）；串口 分辨率开 / 分辨率关 也能改，以最后一次操作为准，不保存
wire       auto_sw    = auto_st;       // 【按键改造】原来是 SW3
// 【应急模式】应急接管：画面锁定在应急页，翻页 / 轮播 / 缩略图 / 音乐按键都不响应，
// 亮度对比度音量仍可调（现场昼夜适配）；轮播计时冻结，退出后接着轮播
// 【三级应急】接管 = SW1（一级，硬件）或串口一级 / 二级；三级只在画面上加警示条，节目照常。
//   sw_on[0] 送出去的是“接管”而不是 SW1 本身，顶层原来接 SW1 的地方（转场、红框、警笛、按键锁定）都跟着接管走
wire [1:0] sc_alm;                     // serial_cmd 设的等级（声明在前面，下面要用）
// 【按键改造】一级应急的来源都并到 serial_cmd 的等级里了（按键 / 干接点 / 串口）
wire       emerg_mode = (sc_alm == 2'd1) || (sc_alm == 2'd2);
wire       emerg_l1   = (sc_alm == 2'd1);
assign sw_on    = {osd_st, auto_st, sw_s2[1], emerg_mode};
reg        emerg_ld;                   // EMERG.BMP 已完整载入
assign emerg_ok = emerg_ld && emerg_l1;     // 一级用 EMERG.BMP（疏散图），没有就用内置警示页；二级始终用内置“就地避险”页
wire key_next_level;
wire key_plus_press;                   // KEY3（声明提前：下面的组合键要用）
wire key_plus_level;
// 【波形开关】组合键：KEY3 和 Key2 同时按住 = 波形开 / 关。按住期间把两个键都标成“长按已处理”，
// 这样松手时不会再触发它们各自的短按 / 长按（音乐暂停、翻页、字幕开关、缩略图）。菜单里不用组合键。
wire key_combo = !key_plus_level && !key_next_level && !param_mode;
wire key_auto_press;
wire key_auto_level;

key_debounce_ms #(
    .DEBOUNCE_MS (50)
) u_key_next (
    .clk         (clk),
    .rst         (rst),
    .ms_tick     (ms_tick),
    .button_in   (key_next),
    .press_pulse (),
    .button_level(key_next_level)
);

key_debounce_ms #(
    .DEBOUNCE_MS (50)
) u_key_auto (
    .clk         (clk),
    .rst         (rst),
    .ms_tick     (ms_tick),
    .button_in   (key_auto),
    .press_pulse (key_auto_press),
    .button_level(key_auto_level)
);

reg        key_auto_level_d;
reg [11:0] key_auto_hold_cnt;   // 按住了几毫秒
reg        key_auto_long_done;
reg        key_auto_short;
reg        key_auto_long;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        key_auto_level_d   <= 1'b1;
        key_auto_hold_cnt  <= 12'd0;
        key_auto_long_done <= 1'b0;
        key_auto_short     <= 1'b0;
        key_auto_long      <= 1'b0;
    end else begin
        key_auto_level_d <= key_auto_level;
        key_auto_short   <= 1'b0;
        key_auto_long    <= 1'b0;
        if (!key_auto_level) begin
            if (key_auto_hold_cnt < LONG_PRESS_MS - 1) begin
                if (ms_tick)
                    key_auto_hold_cnt <= key_auto_hold_cnt + 12'd1;
            end else if (!key_auto_long_done) begin
                key_auto_long_done <= 1'b1;
                key_auto_long      <= 1'b1;
            end
        end else begin
            if (!key_auto_level_d && !key_auto_long_done)
                key_auto_short <= 1'b1;
            key_auto_hold_cnt  <= 12'd0;
            key_auto_long_done <= 1'b0;
        end
    end
end

// Key2 也分短按 / 长按：短按 = 下一张（缩略图里是焦点下移），长按 = 进出缩略图
// 短按在松手时触发（为了和长按区分），长按按满 LONG_PRESS_MS 时触发
reg        key_next_level_d;
reg [11:0] key_next_hold_cnt;   // 按住了几毫秒
reg        key_next_long_done;
reg        key_next_short;
reg        key_next_long;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        key_next_level_d   <= 1'b1;
        key_next_hold_cnt  <= 12'd0;
        key_next_long_done <= 1'b0;
        key_next_short     <= 1'b0;
        key_next_long      <= 1'b0;
    end else begin
        key_next_level_d <= key_next_level;
        key_next_short   <= 1'b0;
        key_next_long    <= 1'b0;
        if (!key_next_level) begin
            if (key_next_hold_cnt < LONG_PRESS_MS - 1) begin
                if (ms_tick)
                    key_next_hold_cnt <= key_next_hold_cnt + 12'd1;
            end else if (!key_next_long_done) begin
                key_next_long_done <= 1'b1;
                key_next_long      <= 1'b1;
            end
        end else begin
            if (!key_next_level_d && !key_next_long_done)
                key_next_short <= 1'b1;
            key_next_hold_cnt  <= 12'd0;
            key_next_long_done <= 1'b0;
        end
        if (key_combo)
            key_next_long_done <= 1'b1;   // 【波形开关】组合键按着：这次按键不再算短按 / 长按
    end
end

// Key1：短按（1 秒内松手）= 上一张；按住超过 1 秒不算短按，
// 按满 3 秒由顶层 key_reset_req 复位整个系统
wire key_prev_level;
key_debounce_ms #(
    .DEBOUNCE_MS (50)
) u_key_prev (
    .clk         (clk),
    .rst         (rst),
    .ms_tick     (ms_tick),
    .button_in   (key_prev),
    .press_pulse (),
    .button_level(key_prev_level)
);

reg        key_prev_level_d;
reg [11:0] key_prev_hold_cnt;   // 按住了几毫秒
reg        key_prev_short;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        key_prev_level_d  <= 1'b1;
        key_prev_hold_cnt <= 12'd0;
        key_prev_short    <= 1'b0;
    end else begin
        key_prev_level_d <= key_prev_level;
        key_prev_short   <= 1'b0;
        if (!key_prev_level) begin
            if ((key_prev_hold_cnt < LONG_PRESS_MS) && ms_tick)
                key_prev_hold_cnt <= key_prev_hold_cnt + 12'd1;
        end else begin
            if (!key_prev_level_d && (key_prev_hold_cnt < LONG_PRESS_MS))
                key_prev_short <= 1'b1;
            key_prev_hold_cnt <= 12'd0;
        end
    end
end

// KEY3：按下即触发（它没有长按功能，参数模式的连发在 param_adjust 里做）
key_debounce_ms #(
    .DEBOUNCE_MS (50)
) u_key_plus (
    .clk         (clk),
    .rst         (rst),
    .ms_tick     (ms_tick),
    .button_in   (key_plus),
    .press_pulse (key_plus_press),
    .button_level(key_plus_level)
);
// 【按键改造】KEY3 也分短按（1 秒内松手，松手时触发）/ 长按（按满 1 秒触发）
reg        key_plus_level_d;
reg [11:0] key_plus_hold_cnt;
reg        key_plus_long_done;
reg        key_plus_short;
reg        key_plus_long;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        key_plus_level_d   <= 1'b1;
        key_plus_hold_cnt  <= 12'd0;
        key_plus_long_done <= 1'b0;
        key_plus_short     <= 1'b0;
        key_plus_long      <= 1'b0;
    end else begin
        key_plus_level_d <= key_plus_level;
        key_plus_short   <= 1'b0;
        key_plus_long    <= 1'b0;
        if (!key_plus_level) begin
            if (key_plus_hold_cnt < LONG_PRESS_MS - 1) begin
                if (ms_tick)
                    key_plus_hold_cnt <= key_plus_hold_cnt + 12'd1;
            end else if (!key_plus_long_done) begin
                key_plus_long_done <= 1'b1;
                key_plus_long      <= 1'b1;
            end
        end else begin
            if (!key_plus_level_d && !key_plus_long_done)
                key_plus_short <= 1'b1;
            key_plus_hold_cnt  <= 12'd0;
            key_plus_long_done <= 1'b0;
        end
        if (key_combo)
            key_plus_long_done <= 1'b1;   // 【波形开关】组合键按着：这次按键不再算短按 / 长按
    end
end

// 【参数掉电保存】param_store → param_adjust 的上电载入值
wire       ps_load_valid;
wire [7:0] ps_bri, ps_con, ps_vol;
wire [2:0] ps_period;
wire [2:0] ps_flags;                   // 【按键改造】{波形关, 字幕关, 自动轮播关}

// 参数菜单：亮度 / 对比度 / 音量 / 轮播周期，只有 SW2 打开时按键才有效
param_adjust #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ)
) u_param_adjust (
    .clk         (clk),
    .rst         (rst),
    .ms_tick     (ms_tick),
    .menu_on     (param_mode),
    .item_prev   (key_next_short),      // Key2 = 上一项
    .item_next   (key_prev_short),      // Key1 = 下一项
    .plus_level  (key_plus_level),
    .minus_level (key_auto_level),
    .sel         (menu_sel),
    .bri_pct     (bri_pct),
    .con_pct     (con_pct),
    .vol_pct     (vol_pct),
    .period_idx  (period_idx),
    .load_valid  (ps_load_valid),
    .ld_bri      (ps_bri),
    .ld_con      (ps_con),
    .ld_vol      (ps_vol),
    .ld_period   (ps_period)
);

// 【参数掉电保存】上电载入上次的参数，SW2 菜单关闭时有改动就保存
wire       sc_fl_req, sc_fl_grant, sc_fl_off, sc_cs_n, sc_sclk, sc_mosi;   // 【串口指令】Flash 共用
wire       sc_music_play, sc_music_stop, sc_next, sc_prev;
wire       sc_osd_set, sc_osd_clr, sc_auto_set, sc_auto_clr;   // 【按键改造】
wire       sc_wave_set, sc_wave_clr, sc_res_set, sc_res_clr;   // 【波形开关】【分辨率显示】
reg        k_alarm, k_mute, x_alarm;
wire [1:0] font_status;
// 【启事】serial_cmd 和轮播调度之间
wire [3:0] q_mask;
wire       q_new;
wire [1:0] q_new_slot;
reg        pg_req;
reg  [1:0] pg_slot;
reg        pg_buf;
wire       pg_done;

param_store #(
    .CLK_FREQ_HZ  (CLK_FREQ_HZ),
    .ENABLE_WRITE (1'b1)                // 2026-10-24 上板已确认能认出 U33（数码管显示 2），打开写功能
) u_param_store (
    .clk          (clk),
    .rst          (rst),
    .ms_tick      (ms_tick),
    .menu_on      (param_mode),
    .bri_pct      (bri_pct),
    .con_pct      (con_pct),
    .vol_pct      (vol_pct),
    .period_idx   (period_idx),
    .flags        ({~wave_st, ~osd_st, ~auto_st}),
    .load_valid   (ps_load_valid),
    .ld_bri       (ps_bri),
    .ld_con       (ps_con),
    .ld_vol       (ps_vol),
    .ld_period    (ps_period),
    .ld_flags     (ps_flags),
    .status       (param_store_status),
    .flash_cs_n   (FLASH_CS_N),
    .flash_sclk   (FLASH_SCLK),
    .flash_mosi   (FLASH_MOSI),
    .flash_wp_n   (FLASH_WP_N),
    .flash_hold_n (FLASH_HOLD_N),
    .flash_miso   (FLASH_MISO),
    .ext_req      (sc_fl_req),
    .ext_grant    (sc_fl_grant),
    .ext_cs_n     (sc_cs_n),
    .ext_sclk     (sc_sclk),
    .ext_mosi     (sc_mosi),
    .chip_off     (sc_fl_off)
);

// 【串口指令】串口助手打字控制：通知 / 撤销通知 / 字幕开关 / 音乐开关 / 翻页 / 装字库（口令和文字在 subtitle/cmd.txt）
// Flash 和参数存储共用：serial_cmd 申请（sc_fl_req），param_store 空闲时让出引脚（信号在 param_store 前面声明）
// 【时序】串口模块自己再同步一次复位（立即进入复位、晚 2 拍退出）：总复位网扇出 1700 多，
//   到这个模块的复位恢复时间只剩 0.1ns；它退出复位晚 2 拍对功能没有影响（param_store 上电先等 100us）
reg [1:0] sc_rst_q;
always @(posedge clk or posedge rst) begin
    if (rst) sc_rst_q <= 2'b11;
    else     sc_rst_q <= {sc_rst_q[0], 1'b0};
end
// 【串口照片】serial_cmd 写照片用的信号（写口选择在后面）
wire             bmp_wreq;
wire             sc_ph_need, sc_ph_wreq, sc_ph_we;
wire [23:0]      sc_ph_px;
wire             ph_wack, ph_wfin;

serial_cmd #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ)
) u_serial_cmd (
    .clk         (clk),
    .rst         (sc_rst_q[1]),
    .ms_tick     (ms_tick),
    .uart_rx     (uart_rx),
    .uart_tx     (uart_tx),
    .emerg_mode  (emerg_mode),
    .sw1         (1'b0),                // 【按键改造】SW1 不用了
    .k_alarm     (k_alarm),
    .x_alarm     (x_alarm),
    .k_mute      (k_mute),
    .alarm_lvl   (sc_alm),
    .fl_req      (sc_fl_req),
    .fl_grant    (sc_fl_grant),
    .fl_off      (sc_fl_off),
    .fl_cs_n     (sc_cs_n),
    .fl_sclk     (sc_sclk),
    .fl_mosi     (sc_mosi),
    .fl_miso     (FLASH_MISO),
    .music_play  (sc_music_play),
    .music_stop  (sc_music_stop),
    .img_next    (sc_next),
    .img_prev    (sc_prev),
    .osd_set     (sc_osd_set),
    .osd_clr     (sc_osd_clr),
    .auto_set    (sc_auto_set),
    .auto_clr    (sc_auto_clr),
    .wave_set    (sc_wave_set),
    .wave_clr    (sc_wave_clr),
    .res_set     (sc_res_set),
    .res_clr     (sc_res_clr),
    .muted       (mute_on),
    .font_status (font_status),
    .vclk        (vclk),
    .vrst_n      (vrst_n),
    .rd_col      (ntc_col),
    .rd_bits     (ntc_bits),
    .v_on        (ntc_on),
    .v_len       (ntc_len),
    .v_new       (ntc_new),
    .v_reject    (ntc_reject),
    .v_sub_off   (ntc_sub_off),
    .v_shown     (v_shown),
    .v_cs        (ntc_cs),
    .a_col       (alm_col),
    .v_alm       (alm_lvl),
    .v_alen      (alm_len),
    .v_mute      (alm_mute),
    .q_mask      (q_mask),
    .q_new       (q_new),
    .q_new_slot  (q_new_slot),
    .pg_req      (pg_req),
    .pg_slot     (pg_slot),
    .pg_buf      (pg_buf),
    .pg_done     (pg_done),
    .pv_sel      (pv_sel),
    .pv_buf      (pv_buf),
    .pv_col      (pv_col),
    .pv_meta     (pv_meta),
    .ph_need     (sc_ph_need),
    .ph_grant    (write_photo),
    .ph_wreq     (sc_ph_wreq),
    .ph_wack     (ph_wack),
    .ph_wfin     (ph_wfin),
    .ph_we       (sc_ph_we),
    .ph_px       (sc_ph_px),
    .ph_pbuf     (write_pbuf)
);

// ---------------- 【按键改造】两个开关、按键应急 / 消音、干接点 ----------------
reg [1:0] xa_s;                        // 干接点同步
reg [1:0] xa_cnt;                      // 接地持续了几个毫秒节拍
reg       xa_on;                       // 这次闭合已经报过了
reg       combo_d;                     // 【波形开关】
reg       sw4_d;                       // 【分辨率显示】SW4 上一拍（复位后第一次同步过来就算一次拨动：上电时跟着开关位置）
always @(posedge clk or posedge rst) begin
    if (rst) begin
        auto_st <= 1'b1;
        osd_st  <= 1'b1;
        wave_st <= 1'b1;
        res_on  <= 1'b0;
        combo_d <= 1'b0;
        sw4_d   <= 1'b0;
        k_alarm <= 1'b0;
        k_mute  <= 1'b0;
        x_alarm <= 1'b0;
        xa_s    <= 2'b11;
        xa_cnt  <= 2'd0;
        xa_on   <= 1'b0;
    end else begin
        k_alarm <= key_auto_long && !param_mode;                 // Key4 长按：一级应急 进入 / 解除
        k_mute  <= key_plus_short && !param_mode && emerg_mode;  // 应急接管时 KEY3 短按 = 消音
        x_alarm <= 1'b0;
        combo_d <= key_combo;
        sw4_d   <= sw_s2[3];
        if (sw_s2[3] != sw4_d)                                   // 【分辨率显示】SW4 拨动：跟着开关
            res_on <= sw_s2[3];
        else if (sc_res_set || sc_res_clr)                       //               串口指令
            res_on <= sc_res_set;
        if (ps_load_valid) begin                                 // 上电读回上次的开关
            auto_st <= !ps_flags[0];
            osd_st  <= !ps_flags[1];
            wave_st <= !ps_flags[2];
        end else begin
            if ((key_combo && !combo_d) || sc_wave_set || sc_wave_clr)   // 【波形开关】组合键按下的那一刻
                wave_st <= sc_wave_set ? 1'b1 : sc_wave_clr ? 1'b0 : !wave_st;
            if ((key_auto_short && !param_mode && !thumb_mode) || sc_auto_set || sc_auto_clr)
                auto_st <= sc_auto_set ? 1'b1 : sc_auto_clr ? 1'b0 : !auto_st;
            if ((key_plus_long && !param_mode) || sc_osd_set || sc_osd_clr)
                osd_st  <= sc_osd_set ? 1'b1 : sc_osd_clr ? 1'b0 : !osd_st;
        end
        // 干接点：接地持续 2~3ms（滤掉毛刺）报一次；断开以后才能再报
        xa_s <= {xa_s[0], ext_alarm_n};
        if (xa_s[1]) begin
            xa_cnt <= 2'd0;
            xa_on  <= 1'b0;
        end else if (xa_cnt != 2'd3) begin
            if (ms_tick) xa_cnt <= xa_cnt + 2'd1;
        end else if (!xa_on) begin
            xa_on   <= 1'b1;
            x_alarm <= 1'b1;
        end
    end
end

// ---------------------------------------------------------------------------
// SD / BMP 读取
// ---------------------------------------------------------------------------
wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             bmp_ready;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire             bmp_load_error;
wire [3:0]       bmp_err_raw;     // bmp_read 的“最近一次”错误码，后续图片加载成功会清零

wire             music_found;
wire             emerg_found;     // 【应急模式】
reg              music_start_pulse;

reg              scan_start_pulse;
reg              load_start_pulse;
reg  [31:0]      load_sector;
reg              load_abort;

// 【拔卡恢复】
wire             card_lost;       // fat32_bmp_read：读扇区超时（单拍）
wire [31:0]      fs_sig;          // 卡指纹
wire [25:0]      src_dims;        // 【分辨率显示】刚读到的 BMP 宽高
reg              probe_start;     // 空闲巡检（单拍）
reg              sd_soft_rst;     // 只复位 SD 读卡模块，重新初始化卡（SDRAM 里的图、显示都不动）
reg              card_missing;    // 1 = 卡被拔掉了，正在等插回（给开机画面模块画提示）

// 【串口照片】写口：write_photo = 1 时给 serial_cmd 写照片，否则给 SD 卡载图（两者由下面的许可错开，不会同时用）
assign write_req  = write_photo ? sc_ph_wreq : bmp_wreq;
assign write_en   = write_photo ? sc_ph_we   : bmp_data_wr_en;
assign write_data = write_photo ? {sc_ph_px, 8'b0} : {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};

fat32_bmp_read #(
    .CLK_FREQ_HZ            (CLK_FREQ_HZ)
) bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ms_tick                (ms_tick),
    .ready                  (bmp_ready),
    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (),
    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),
    .sd_init_done           (sd_init_done),
    .state_code             (state_code),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (bmp_wreq),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    .load_error             (bmp_load_error),
    .bmp_error              (bmp_err_raw),
    .music_start            (music_start_pulse),
    .music_found            (music_found),
    .emerg_found            (emerg_found),
    .music_byte_valid       (music_byte_valid),
    .music_byte             (music_byte),
    .music_off              (music_off),
    .music_hold             (music_hold),
    .probe_start            (probe_start),
    .card_lost              (card_lost),
    .fs_sig                 (fs_sig),
    .src_dims               (src_dims)
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst | sd_soft_rst),     // 【拔卡恢复】拔卡后单独复位、重新初始化
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

// ---------------------------------------------------------------------------
// 图片表与选择函数
// ---------------------------------------------------------------------------
reg [2:0]  img_found_count;
reg [31:0] img_sector0, img_sector1, img_sector2, img_sector3;
reg [3:0]  loaded;      // 该 bank 已完整写入
reg [3:0]  failed;      // 该图两次加载都失败
reg [1:0]  img_idx;     // 当前显示的图片 = 当前显示的 bank
reg [1:0]  saved_idx;   // 进缩略图前看的那张，长按退出时回到它
assign loaded_mask = loaded;

// ---------------- 【分辨率显示】每张图的原图宽高 → video_clk 域 ----------------
// 某张图刚载好（loaded 那一位刚变 1）时，fat32_bmp_read 里的宽高还是这张图的，记下来，同时翻转 rs_tgl；
// video_clk 域看到翻转再整体抄过去（数据比翻转早稳定，抄的时候不会变）。
reg  [3:0]   ld_d;
reg  [103:0] rs_dims;                  // 4 张图 × {高 13 位, 宽 13 位}
reg          rs_tgl;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        ld_d    <= 4'd0;
        rs_dims <= 104'd0;
        rs_tgl  <= 1'b0;
    end else begin
        ld_d <= loaded;
        if (loaded[0] && !ld_d[0]) rs_dims[25:0]   <= src_dims;
        if (loaded[1] && !ld_d[1]) rs_dims[51:26]  <= src_dims;
        if (loaded[2] && !ld_d[2]) rs_dims[77:52]  <= src_dims;
        if (loaded[3] && !ld_d[3]) rs_dims[103:78] <= src_dims;
        if (|(loaded & ~ld_d))
            rs_tgl <= ~rs_tgl;
    end
end

reg  [2:0]   vr_t;                     // rs_tgl 打拍
reg  [103:0] vr_dims;
reg  [1:0]   vw_s, vo_s;               // wave_st / res_on 两拍同步（单个开关位）
always @(posedge vclk or negedge vrst_n) begin
    if (!vrst_n) begin
        vr_t    <= 3'd0;
        vr_dims <= 104'd0;
        vw_s    <= 2'b11;
        vo_s    <= 2'b00;
    end else begin
        vr_t <= {vr_t[1:0], rs_tgl};
        if (vr_t[2] ^ vr_t[1])
            vr_dims <= rs_dims;
        vw_s <= {vw_s[0], wave_st};
        vo_s <= {vo_s[0], res_on};
    end
end

// 正在显示的那张图的宽高转十进制：移位加 3（double dabble），13 拍算完一次，一直循环算
reg  [25:0]  vr_sel;
always @(*) begin
    case (v_shown[1:0])
        2'd1:    vr_sel = vr_dims[25:0];
        2'd2:    vr_sel = vr_dims[51:26];
        2'd3:    vr_sel = vr_dims[77:52];
        default: vr_sel = vr_dims[103:78];
    endcase
end
function [15:0] dd_add3;               // 每个十进制位 ≥ 5 就加 3
    input [15:0] d;
    begin
        dd_add3[3:0]   = (d[3:0]   >= 4'd5) ? d[3:0]   + 4'd3 : d[3:0];
        dd_add3[7:4]   = (d[7:4]   >= 4'd5) ? d[7:4]   + 4'd3 : d[7:4];
        dd_add3[11:8]  = (d[11:8]  >= 4'd5) ? d[11:8]  + 4'd3 : d[11:8];
        dd_add3[15:12] = (d[15:12] >= 4'd5) ? d[15:12] + 4'd3 : d[15:12];
    end
endfunction
reg  [12:0]  bw_sh, bh_sh;             // 还没移进去的二进制位
reg  [15:0]  dw_sh, dh_sh;             // 正在拼的十进制
reg  [3:0]   dd_n;                     // 0 = 装数，1~13 = 第几位
reg  [15:0]  w_bcd, h_bcd;
wire [15:0]  dw_a = dd_add3(dw_sh);
wire [15:0]  dh_a = dd_add3(dh_sh);
always @(posedge vclk or negedge vrst_n) begin
    if (!vrst_n) begin
        bw_sh <= 13'd0; bh_sh <= 13'd0; dw_sh <= 16'd0; dh_sh <= 16'd0;
        dd_n  <= 4'd0;  w_bcd <= 16'd0; h_bcd <= 16'd0;
    end else if (dd_n == 4'd0) begin
        bw_sh <= vr_sel[12:0];
        bh_sh <= vr_sel[25:13];
        dw_sh <= 16'd0;
        dh_sh <= 16'd0;
        dd_n  <= 4'd1;
    end else begin
        bw_sh <= {bw_sh[11:0], 1'b0};
        bh_sh <= {bh_sh[11:0], 1'b0};
        dw_sh <= {dw_a[14:0], bw_sh[12]};
        dh_sh <= {dh_a[14:0], bh_sh[12]};
        if (dd_n == 4'd13) begin
            w_bcd <= {dw_a[14:0], bw_sh[12]};
            h_bcd <= {dh_a[14:0], bh_sh[12]};
            dd_n  <= 4'd0;
        end else begin
            dd_n  <= dd_n + 4'd1;
        end
    end
end
// 波形：开关开、不在启事页；分辨率：串口打开、已经出图、不在启事页（应急、缩略图、菜单在 OSD 里再挡）
assign v_res = {vw_s[1] && !pv_sel, vo_s[1] && (v_shown != 4'd0) && !pv_sel, w_bcd, h_bcd};
reg [3:0]  fail_code;   // 第一次放弃某张图时的错误码

// 有图片被放弃时一直显示它的错误码（数码管和 OSD 变红），否则显示最近一次错误
assign err_code = (failed != 4'd0) ? fail_code : bmp_err_raw;

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0:    sector_lut = img_sector0;
            2'd1:    sector_lut = img_sector1;
            2'd2:    sector_lut = img_sector2;
            default: sector_lut = img_sector3;
        endcase
    end
endfunction

// 从 cur 出发按方向找下一张已加载的图，返回 {找到, 编号}
// 【时序】图片张数不直接参与比较：last = 张数 - 1、cz = 张数为 0 预先算好打一拍（原来要做加法和比较，11 级逻辑）
function [2:0] find_loaded;
    input [1:0] cur;
    input [3:0] ok;
    input [2:0] last;
    input       cz;
    input       backward;
    integer     k;
    reg   [1:0] c;
    reg         hit;
    begin
        c           = cur;
        hit         = 1'b0;
        find_loaded = {1'b0, cur};
        for (k = 0; k < 3; k = k + 1) begin
            if (backward)
                c = (c == 2'd0) ? last[1:0] : (c - 2'd1);
            else
                c = (cz || ({1'b0, c} >= last)) ? 2'd0 : (c + 2'd1);
            if (!hit && ok[c]) begin
                hit         = 1'b1;
                find_loaded = {1'b1, c};
            end
        end
    end
endfunction

// 找编号最小的待加载图片，返回 {有, 编号}
function [2:0] first_todo;
    input [3:0] done_mask;
    input [2:0] cnt;
    reg   [2:0] k;
    reg         hit;
    begin
        hit        = 1'b0;
        first_todo = 3'd0;
        for (k = 3'd0; k < 3'd4; k = k + 3'd1) begin
            if (!hit && (k < cnt) && !done_mask[k[1:0]]) begin
                hit        = 1'b1;
                first_todo = {1'b1, k[1:0]};
            end
        end
    end
endfunction

// 【时序修复】查找结果先打一拍再用，原来组合路径在 100MHz 下差约 1.7ns
// 按键间隔远大于 1 拍，晚一拍更新没有影响
reg [2:0] next_pick;
reg [2:0] prev_pick;
reg [2:0] todo_pick;
reg [2:0] cnt_last;
reg       cnt_zero;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        cnt_last  <= 3'd7;
        cnt_zero  <= 1'b1;
        next_pick <= 3'd0;
        prev_pick <= 3'd0;
        todo_pick <= 3'd0;
    end else begin
        cnt_last  <= img_found_count - 3'd1;
        cnt_zero  <= (img_found_count == 3'd0);
        next_pick <= find_loaded(img_idx, loaded, cnt_last, cnt_zero, 1'b0);
        prev_pick <= find_loaded(img_idx, loaded, cnt_last, cnt_zero, 1'b1);
        todo_pick <= first_todo(loaded | failed, img_found_count);
    end
end

assign img_num = display_valid ? ({2'b00, img_idx} + 4'd1) : 4'd0;

// ---------------------------------------------------------------------------
// 写完成同步：mem_clk 域的 toggle → 本域单拍
// ---------------------------------------------------------------------------
reg [2:0] wrfin_tgl_sync;
wire      write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];

// ---------------------------------------------------------------------------
// 主控制
// ---------------------------------------------------------------------------
reg        scan_kicked;
reg        load_busy;
reg        load_busy_d;     // 晚一拍的 load_busy：等 todo_pick 用上最新的 loaded/failed 再发起下一张
always @(posedge clk or posedge rst) begin
    if (rst)
        load_busy_d <= 1'b0;
    else
        load_busy_d <= load_busy;
end

// 【串口照片】写口许可 + 写请求应答同步（write_req_ack 来自 ext_mem_clk 域）
reg [1:0] ph_ack_s;
assign    ph_wack = ph_ack_s[1];
assign    ph_wfin = write_finish_pulse;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        write_photo <= 1'b0;
        ph_ack_s    <= 2'b00;
    end else begin
        ph_ack_s    <= {ph_ack_s[0], write_req_ack};
        write_photo <= sc_ph_need && (write_photo || (!load_busy && !load_busy_d && !load_start_pulse));
    end
end
reg [1:0]  load_idx;
reg        retry_done;
reg        src_started;     // 本次加载 bmp_read 已离开空闲
reg        source_done_seen;
reg        write_done_seen;
reg [15:0] load_timeout_cnt;   // 这张图载了几毫秒
reg [15:0] auto_cnt;        // 轮播计时，单位毫秒
// 轮播由 SW3 决定：上电就按拨码位置来，断电重启照样轮播
assign auto_on = auto_sw;
// 缩略图里、应急模式下暂停（display_valid 段里处理），退出后继续
wire       auto_run = auto_sw && !thumb_mode;

// 转场忙信号跨时钟域
reg trans_busy_s1, trans_busy_s2;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        trans_busy_s1 <= 1'b0;
        trans_busy_s2 <= 1'b0;
    end else begin
        trans_busy_s1 <= trans_busy;
        trans_busy_s2 <= trans_busy_s1;
    end
end

// 【启事】轮播里插启事页：
//   新发布的一条马上插播（ins_pend）；之后每张图放完一个周期，依次放全部启事（每条一个周期），再放下一张图
//   SW3 关（手动）时只有新发布的那条会插播一次，放完回到原来的图
//   三级应急时启事暂停（正在放的回到图）；一级 / 二级接管时这一段不执行，解除后接着放
//   要放第几条：先请 serial_cmd 画进“没在显示”的那块缓冲（pg_req → pg_done），画好了再让转场切过去；
//   pg_out = 有一次画页没回来，期间不发新请求（不会画到正在显示的那块）
reg        pg_wait;         // 等这次画页的结果（按键打断时清掉，结果就不用了）
reg        pg_out;          // serial_cmd 还在画
reg  [1:0] pg_cur;          // 正在放第几条
reg  [1:0] pg_rq_slot;
reg        pg_rq_auto;
reg        ins_pend;        // 有新发布的要插播
reg  [1:0] ins_slot;
wire       l3_on   = 1'b0;          // 【应急改版】三级区域警戒不再暂停启事（原来 = (sc_alm == 2'd3)）
wire [2:0] q_first = q_mask[0] ? 3'b100 : q_mask[1] ? 3'b101 : q_mask[2] ? 3'b110 : q_mask[3] ? 3'b111 : 3'b000;
wire [2:0] q_after = ((pg_cur == 2'd0) && q_mask[1]) ? 3'b101 :                           // pg_cur 后面的下一条（不回绕）
                     ((pg_cur <= 2'd1) && q_mask[2]) ? 3'b110 :
                     ((pg_cur <= 2'd2) && q_mask[3]) ? 3'b111 : 3'b000;
// 数码管：第几条 / 共几条
wire [3:0] pi_bm   = q_mask & ((pg_cur == 2'd0) ? 4'b0000 : (pg_cur == 2'd1) ? 4'b0001 : (pg_cur == 2'd2) ? 4'b0011 : 4'b0111);
assign page_info   = {want_page, {2'b0, pi_bm[0]} + {2'b0, pi_bm[1]} + {2'b0, pi_bm[2]} + 3'd1,
                      {2'b0, q_mask[0]} + {2'b0, q_mask[1]} + {2'b0, q_mask[2]} + {2'b0, q_mask[3]}};

wire load_fail = load_busy && !(source_done_seen && write_done_seen) &&
                 (bmp_load_error || (load_timeout_cnt >= LOAD_TIMEOUT_MS));

// 【应急模式】EMERG.BMP 排在 4 张图之后、背景音乐之前预载，写进第 5 个 bank
reg  load_emerg;        // 本次加载的是 EMERG.BMP
reg  emerg_failed;      // 两次都没载成功，放弃（应急模式改用内置警示页）
wire emerg_todo = scan_done && emerg_found && !emerg_ld && !emerg_failed;

// ---------------- 【拔卡恢复】 ----------------
// 读扇区超时（card_lost）= 卡被拔掉：图片早已在 SDRAM 里，显示照常；
//   1. 只复位 SD 读卡模块（sd_soft_rst），每 2 秒重新初始化一次，等卡插回来
//   2. 初始化成功后重新扫描目录，比对卡指纹（各文件的起始簇、大小、修改时间）：
//        同一张卡：什么都不重载，背景音乐从头接着放（画面不中断）
//        换了卡  ：清掉已载入的图，重新走一遍开机自检、载入新卡的节目（不用按 Key1）
// 平时不读卡（没有背景音乐、图都载完了）时每秒巡检读一次卡（probe_start）；音乐暂停时 fat32_bmp_read 自己巡检
localparam [2:0]  CS_OK = 3'd0, CS_RESET = 3'd1, CS_INIT = 3'd2, CS_SCAN = 3'd3, CS_CHECK = 3'd4;
localparam [11:0] SDRST_MS = 12'd2;                       // 复位保持 1~2ms（数 2 个毫秒节拍）
localparam [11:0] INIT_MS  = 12'd2000;                    // 2 秒内没初始化完就再复位一次（没插卡就一直这样等）
localparam [10:0] PROBE_MS = 11'd1000;                    // 空闲 1 秒巡检一次
reg [2:0]  cs;
reg [11:0] cs_cnt;          // 毫秒
reg [10:0] probe_cnt;       // 毫秒
reg [2:0]  probe_guard;     // 发巡检后几拍内不发别的请求（fat32_bmp_read 还没离开空闲）
reg [31:0] fs_sig_saved;
reg        fs_sig_ok;
reg        scan_done_q;
reg        lost_strike;     // 上次拔卡时正在载的那张（同一张卡插回后又在同一张上超时 = 卡坏了，放弃这张）
reg [2:0]  lost_res;        // {是应急页, 图号}
wire       cs_ok = (cs == CS_OK);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync   <= 3'b000;
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;
        load_sector      <= 32'd0;
        scan_kicked      <= 1'b0;
        img_found_count  <= 3'd0;
        img_sector0      <= 32'd0;
        img_sector1      <= 32'd0;
        img_sector2      <= 32'd0;
        img_sector3      <= 32'd0;
        loaded           <= 4'd0;
        failed           <= 4'd0;
        fail_code        <= 4'd0;
        img_idx          <= 2'd0;
        disp_buf_idx     <= 2'd0;
        write_buf_idx    <= 2'd0;
        display_valid    <= 1'b0;
        load_busy        <= 1'b0;
        load_idx         <= 2'd0;
        retry_done       <= 1'b0;
        src_started      <= 1'b0;
        source_done_seen <= 1'b0;
        write_done_seen  <= 1'b0;
        load_timeout_cnt <= 16'd0;
        auto_cnt         <= 16'd0;
        switch_auto      <= 1'b0;
        thumb_mode       <= 1'b0;
        saved_idx        <= 2'd0;
        music_pause      <= 1'b1;          // 上电默认静音，按 KEY3 才放（避开上电后等音乐的那 2 秒）
        load_emerg       <= 1'b0;
        write_emerg      <= 1'b0;
        emerg_ld         <= 1'b0;
        emerg_failed     <= 1'b0;
        cs               <= CS_OK;
        cs_cnt           <= 12'd0;
        sd_soft_rst      <= 1'b0;
        card_missing     <= 1'b0;
        probe_start      <= 1'b0;
        probe_cnt        <= 11'd0;
        probe_guard      <= 3'd0;
        fs_sig_saved     <= 32'd0;
        fs_sig_ok        <= 1'b0;
        scan_done_q      <= 1'b0;
        lost_strike      <= 1'b0;
        lost_res         <= 3'd0;
        want_page        <= 1'b0;
        want_pbuf        <= 1'b0;
        pg_req           <= 1'b0;
        pg_slot          <= 2'd0;
        pg_buf           <= 1'b0;
        pg_wait          <= 1'b0;
        pg_out           <= 1'b0;
        pg_cur           <= 2'd0;
        pg_rq_slot       <= 2'd0;
        pg_rq_auto       <= 1'b0;
        ins_pend         <= 1'b0;
        ins_slot         <= 2'd0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;
        pg_req           <= 1'b0;
        if (pg_done) pg_out <= 1'b0;

        if (!sd_init_done && cs_ok) begin
            // 上电还没初始化好（拔卡恢复时 SD 也会暂时没初始化，那时不清，见文件末尾）
            scan_kicked      <= 1'b0;
            img_found_count  <= 3'd0;
            loaded           <= 4'd0;
            failed           <= 4'd0;
            display_valid    <= 1'b0;
            load_busy        <= 1'b0;
            retry_done       <= 1'b0;
            auto_cnt         <= 16'd0;
            load_timeout_cnt <= 16'd0;
            thumb_mode       <= 1'b0;
            emerg_ld         <= 1'b0;
            emerg_failed     <= 1'b0;
            want_page        <= 1'b0;
            pg_wait          <= 1'b0;
        end else begin
            // ---------------- 扫描：记录找到的图片 ----------------
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse <= 1'b1;
                scan_kicked      <= 1'b1;
                img_found_count  <= 3'd0;
                loaded           <= 4'd0;
                failed           <= 4'd0;
                emerg_ld         <= 1'b0;
                emerg_failed     <= 1'b0;
            end

            if (scan_found_valid && (img_found_count < 3'd4)) begin
                case (img_found_count[1:0])
                    2'd0: img_sector0 <= scan_found_sector;
                    2'd1: img_sector1 <= scan_found_sector;
                    2'd2: img_sector2 <= scan_found_sector;
                    2'd3: img_sector3 <= scan_found_sector;
                endcase
                img_found_count <= img_found_count + 3'd1;
            end

            // ---------------- 后台预载：图片 k 写入 bank k ----------------
            if (load_busy) begin
                if (!bmp_ready)
                    src_started <= 1'b1;
                if (src_started && bmp_ready)
                    source_done_seen <= 1'b1;
                if (write_finish_pulse)
                    write_done_seen <= 1'b1;
                if (ms_tick)
                    load_timeout_cnt <= load_timeout_cnt + 16'd1;
            end

            if (load_busy && source_done_seen && write_done_seen) begin
                // 加载成功
                load_busy               <= 1'b0;
                retry_done              <= 1'b0;
                lost_strike             <= 1'b0;
                if (load_emerg)
                    emerg_ld            <= 1'b1;
                else
                    loaded[load_idx]    <= 1'b1;
                if (!display_valid && !load_emerg) begin
                    // 第一张载好的图立即显示
                    img_idx       <= load_idx;
                    disp_buf_idx  <= load_idx;
                    display_valid <= 1'b1;
                end
            end else if (load_fail) begin
                load_busy  <= 1'b0;
                load_abort <= (load_timeout_cnt >= LOAD_TIMEOUT_MS);
                if (!retry_done) begin
                    retry_done <= 1'b1;            // 下一轮仍选到同一张，即重试一次
                end else begin
                    retry_done       <= 1'b0;
                    if (load_emerg)
                        emerg_failed     <= 1'b1;  // 应急页载不进来：应急模式用内置警示页
                    else
                        failed[load_idx] <= 1'b1;  // 放弃这张，继续预载后面的
                    fail_code        <= bmp_err_raw;
                end
            end else if (!load_busy && !load_busy_d && scan_done && bmp_ready && todo_pick[2] && !load_start_pulse &&
                         cs_ok && (probe_guard == 3'd0) && !sc_ph_need && !write_photo) begin   // 【串口照片】写照片时不载图
                load_idx         <= todo_pick[1:0];
                load_sector      <= sector_lut(todo_pick[1:0]);
                write_buf_idx    <= todo_pick[1:0];
                load_emerg       <= 1'b0;
                write_emerg      <= 1'b0;
                load_start_pulse <= 1'b1;
                load_busy        <= 1'b1;
                src_started      <= 1'b0;
                source_done_seen <= 1'b0;
                write_done_seen  <= 1'b0;
                load_timeout_cnt <= 16'd0;
            end else if (!load_busy && !load_busy_d && bmp_ready && !todo_pick[2] && emerg_todo && !load_start_pulse &&
                         cs_ok && (probe_guard == 3'd0) && !sc_ph_need && !write_photo) begin   // 【串口照片】写照片时不载图
                // 【应急模式】4 张图都处理完，再载 EMERG.BMP：资源号第 2 位置 1，
                // 写侧用 bank0 的通道，顶层看 write_emerg 把地址换成应急 bank
                load_idx         <= 2'd0;
                load_sector      <= 32'd4;
                write_buf_idx    <= 2'd0;
                load_emerg       <= 1'b1;
                write_emerg      <= 1'b1;
                load_start_pulse <= 1'b1;
                load_busy        <= 1'b1;
                src_started      <= 1'b0;
                source_done_seen <= 1'b0;
                write_done_seen  <= 1'b0;
                load_timeout_cnt <= 16'd0;
            end

            // ---------------- KEY3 暂停音乐（菜单、应急模式下不响应） ----------------
            if (key_plus_short && !param_mode && !emerg_mode)   // 【按键改造】松手时触发（要和长按区分）
                music_pause <= ~music_pause;
            else if (sc_music_play)                // 【串口指令】音乐开 / 音乐关（应急模式下 serial_cmd 不发）
                music_pause <= 1'b0;
            else if (sc_music_stop)
                music_pause <= 1'b1;

            // ---------------- 显示切换：只改 bank 编号 ----------------
            // 缩略图模式下 img_idx 当焦点用：Key2 短按/Key1 短按只移动焦点，
            // 转场模块看到 thumb_mode=1 就不会因为 disp_buf_idx 变化而切画面
            // 菜单打开时 Key1/Key2 用来选项，这里的按键动作全部不响应，轮播照常
            // 【应急模式】整段不执行：按键无效、轮播计时冻结
            if (display_valid && !emerg_mode) begin
                if (key_next_long && !param_mode) begin
                    // 长按 Key2：进入缩略图（记住当前图）/ 退出缩略图（回到原来那张）
                    // 缩略图里轮播暂停（auto_run=0），退出后接着计时
                    switch_auto  <= 1'b0;
                    want_page    <= 1'b0;          // 【启事】
                    pg_wait      <= 1'b0;
                    if (!thumb_mode) begin
                        thumb_mode <= 1'b1;
                        saved_idx  <= img_idx;
                    end else begin
                        thumb_mode   <= 1'b0;
                        img_idx      <= saved_idx;
                        disp_buf_idx <= saved_idx;
                    end
                end else if (thumb_mode && key_auto_short && !param_mode) begin
                    // 缩略图里短按 Key4：选中焦点那张，全屏显示
                    thumb_mode   <= 1'b0;
                    switch_auto  <= 1'b0;
                end else if ((key_prev_short || sc_next) && next_pick[2] && !param_mode) begin
                    // 短按 Key1 / 【串口指令】下一张：下一张（【启事】正在放启事也直接回到图）
                    img_idx      <= next_pick[1:0];
                    disp_buf_idx <= next_pick[1:0];
                    switch_auto  <= 1'b0;
                    auto_cnt     <= 16'd0;
                    want_page    <= 1'b0;
                    pg_wait      <= 1'b0;
                end else if ((key_next_short || sc_prev) && prev_pick[2] && !param_mode) begin
                    // 短按 Key2 / 【串口指令】上一张：上一张
                    img_idx      <= prev_pick[1:0];
                    disp_buf_idx <= prev_pick[1:0];
                    switch_auto  <= 1'b0;
                    auto_cnt     <= 16'd0;
                    want_page    <= 1'b0;
                    pg_wait      <= 1'b0;
                end else if (pg_wait) begin
                    // 【启事】等启事页画好（一般 2ms 内），轮播计时停着
                    if (!pg_out) begin                    // 画完了（用 pg_out 不用单拍的 pg_done：应急接管期间画完也不会漏）
                        pg_wait <= 1'b0;
                        if (!l3_on && !thumb_mode && q_mask[pg_rq_slot]) begin
                            want_page   <= 1'b1;
                            want_pbuf   <= pg_buf;
                            pg_cur      <= pg_rq_slot;
                            switch_auto <= pg_rq_auto;
                            auto_cnt    <= 16'd0;
                        end
                    end
                end else if (ins_pend && !l3_on && !thumb_mode && !trans_busy_s2 && !pg_out) begin
                    // 【启事】刚发布的一条：马上插播（画到没在显示的那块缓冲）
                    ins_pend <= 1'b0;
                    if (q_mask[ins_slot]) begin
                        pg_req <= 1'b1; pg_slot <= ins_slot; pg_buf <= ~want_pbuf; pg_out <= 1'b1;
                        pg_wait <= 1'b1; pg_rq_slot <= ins_slot; pg_rq_auto <= 1'b0;
                    end
                end else if (want_page) begin
                    // 【启事】正在放启事：三级应急 / 这条被撤销了就回到图；放满一个周期放下一条，没有了放下一张图
                    if (l3_on || !q_mask[pg_cur]) begin
                        want_page   <= 1'b0;
                        switch_auto <= 1'b0;
                        auto_cnt    <= 16'd0;
                    end else if (trans_busy_s2) begin
                        auto_cnt <= 16'd0;
                    end else if (auto_cnt >= auto_play_ms) begin
                        auto_cnt <= 16'd0;
                        if (q_after[2] && !pg_out) begin
                            pg_req <= 1'b1; pg_slot <= q_after[1:0]; pg_buf <= ~want_pbuf; pg_out <= 1'b1;
                            pg_wait <= 1'b1; pg_rq_slot <= q_after[1:0]; pg_rq_auto <= 1'b1;
                        end else begin
                            want_page   <= 1'b0;
                            switch_auto <= auto_run;
                            if (auto_run && next_pick[2]) begin
                                img_idx      <= next_pick[1:0];
                                disp_buf_idx <= next_pick[1:0];
                            end
                        end
                    end else if (ms_tick) begin
                        auto_cnt <= auto_cnt + 16'd1;
                    end
                end else if (!auto_sw) begin
                    auto_cnt <= 16'd0;             // SW3 关：手动；再打开时从头计一个完整周期
                end else if (!auto_run) begin
                    ;                              // 缩略图里：计时冻结
                end else if (trans_busy_s2) begin
                    auto_cnt <= 16'd0;             // 转场完成后才开始计时，每张图完整显示一个周期
                end else if (auto_cnt >= auto_play_ms) begin
                    auto_cnt <= 16'd0;
                    if (q_first[2] && !l3_on && !pg_out) begin
                        // 【启事】这张图放完了，先放全部启事
                        pg_req <= 1'b1; pg_slot <= q_first[1:0]; pg_buf <= ~want_pbuf; pg_out <= 1'b1;
                        pg_wait <= 1'b1; pg_rq_slot <= q_first[1:0]; pg_rq_auto <= 1'b1;
                    end else if (next_pick[2]) begin
                        img_idx      <= next_pick[1:0];
                        disp_buf_idx <= next_pick[1:0];
                        switch_auto  <= 1'b1;
                    end
                end else if (ms_tick) begin
                    auto_cnt <= auto_cnt + 16'd1;
                end
            end
        end

        // 【启事】新发布的一条记下来，等能插播时再放
        if (q_new) begin
            ins_pend <= 1'b1;
            ins_slot <= q_new_slot;
        end

        // ---------------- 【拔卡恢复】（放在最后：同一拍里覆盖上面的赋值） ----------------
        probe_start <= 1'b0;
        scan_done_q <= scan_done;
        if (probe_guard != 3'd0)
            probe_guard <= probe_guard - 3'd1;
        case (cs)
            CS_OK: begin
                // 上电扫描完成：记下卡指纹
                if (scan_done && !scan_done_q) begin
                    fs_sig_saved <= fs_sig;
                    fs_sig_ok    <= 1'b1;
                end
                // 空闲巡检：没在读卡、也没有要载的图时，每秒读一次卡
                if (sd_init_done && scan_done && bmp_ready && !load_busy && !load_busy_d && !load_start_pulse &&
                    !todo_pick[2] && !emerg_todo && (probe_guard == 3'd0)) begin
                    if (probe_cnt >= PROBE_MS) begin
                        probe_cnt   <= 11'd0;
                        probe_start <= 1'b1;
                        probe_guard <= 3'd4;
                    end else if (ms_tick) begin
                        probe_cnt <= probe_cnt + 11'd1;
                    end
                end else begin
                    probe_cnt <= 11'd0;
                end
            end
            CS_RESET: begin
                // 复位 SD 读卡模块 1ms
                if (cs_cnt >= SDRST_MS) begin
                    sd_soft_rst <= 1'b0;
                    cs_cnt      <= 12'd0;
                    cs          <= CS_INIT;
                end else if (ms_tick) begin
                    cs_cnt <= cs_cnt + 12'd1;
                end
            end
            CS_INIT: begin
                // 等卡初始化完（插回来了），重新扫描目录；2 秒没好就再复位一次
                if (sd_init_done && bmp_ready) begin
                    scan_start_pulse <= 1'b1;
                    img_found_count  <= 3'd0;
                    cs               <= CS_SCAN;
                end else if (cs_cnt >= INIT_MS) begin
                    sd_soft_rst <= 1'b1;
                    cs_cnt      <= 12'd0;
                    cs          <= CS_RESET;
                end else if (ms_tick) begin
                    cs_cnt <= cs_cnt + 12'd1;
                end
            end
            CS_SCAN: begin
                // 扫描完那一拍最后一张图还没计进 img_found_count，下一拍再比
                if (scan_done && !scan_start_pulse)
                    cs <= CS_CHECK;
            end
            default: begin   // CS_CHECK
                if (!(fs_sig_ok && (fs_sig == fs_sig_saved))) begin
                    // 换了一张卡：清掉旧节目，重新走开机自检、载入新卡（扫描结果已经有了，不用再扫）
                    loaded           <= 4'd0;
                    failed           <= 4'd0;
                    fail_code        <= 4'd0;
                    display_valid    <= 1'b0;
                    img_idx          <= 2'd0;
                    disp_buf_idx     <= 2'd0;
                    retry_done       <= 1'b0;
                    auto_cnt         <= 16'd0;
                    thumb_mode       <= 1'b0;
                    emerg_ld         <= 1'b0;
                    emerg_failed     <= 1'b0;
                    lost_strike      <= 1'b0;
                    want_page        <= 1'b0;
                    pg_wait          <= 1'b0;
                end
                // 同一张卡：什么都不动，没载完的图接着载，背景音乐从头放
                fs_sig_saved <= fs_sig;
                fs_sig_ok    <= 1'b1;
                card_missing <= 1'b0;
                cs           <= CS_OK;
            end
        endcase

        if (card_lost) begin
            // 读卡超时：取消正在载的图（不算一次失败），复位 SD 读卡模块，等卡插回
            if (load_busy) begin
                load_busy  <= 1'b0;
                retry_done <= retry_done;
                failed     <= failed;
                fail_code  <= fail_code;
                emerg_failed <= emerg_failed;
                if (lost_strike && (lost_res == {load_emerg, load_idx})) begin
                    // 同一张图连续两次读到一半超时：卡插着也读不出来，放弃这张
                    lost_strike <= 1'b0;
                    fail_code   <= 4'd2;
                    if (load_emerg)
                        emerg_failed     <= 1'b1;
                    else
                        failed[load_idx] <= 1'b1;
                end else begin
                    lost_strike <= 1'b1;
                    lost_res    <= {load_emerg, load_idx};
                end
            end
            load_start_pulse <= 1'b0;
            scan_start_pulse <= 1'b0;
            probe_start      <= 1'b0;
            probe_cnt        <= 11'd0;
            sd_soft_rst      <= 1'b1;
            cs_cnt           <= 12'd0;
            cs               <= CS_RESET;
            card_missing     <= 1'b1;
        end
    end
end

// ---------------------------------------------------------------------------
// 背景音乐启动：扫描完成、每张图都已载入或放弃、SD 空闲，
// 条件连续保持 32 拍再发（todo_pick 等是打过拍的，留够余量），只发一次。
// 之后 fat32_bmp_read 一直循环读 MUSIC.WAV，不再接受新的图片加载。
// ---------------------------------------------------------------------------
reg       music_kicked;
reg [4:0] music_settle;
wire      music_can_start = scan_done && bmp_ready && !load_busy && !load_busy_d &&
                            !todo_pick[2] && !emerg_todo && music_found &&
                            cs_ok && (probe_guard == 3'd0);         // 【拔卡恢复】恢复中、刚发巡检时不开始

// WAV 要等全部图片预载完才开始（SD 卡只有一个读口），之前不放琶音占位：
// 扫描完确认卡上没有 MUSIC.WAV，才允许琶音当背景音
always @(posedge clk or posedge rst) begin
    if (rst)
        tone_allow <= 1'b0;
    else
        tone_allow <= scan_done && !music_found;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        music_start_pulse <= 1'b0;
        music_kicked      <= 1'b0;
        music_settle      <= 5'd0;
    end else begin
        music_start_pulse <= 1'b0;
        if (!sd_init_done) begin
            music_kicked <= 1'b0;
            music_settle <= 5'd0;
        end else if (!music_kicked) begin
            if (!music_can_start)
                music_settle <= 5'd0;
            else if (music_settle != 5'd31)
                music_settle <= music_settle + 5'd1;
            else begin
                music_start_pulse <= 1'b1;
                music_kicked      <= 1'b1;
            end
        end
    end
end

// ---------------- 【开机画面】开机自检用的状态 ----------------
// boot_info = {【串口指令】字库状态 2 位（0 检查中 1 已安装 2 未安装 3 Flash 不可用）, 【拔卡恢复】卡被拔掉, TF 卡初始化完, 目录扫描完, 找到几张图, 载好几张, 处理完几张（载好或放弃）,
//              有 MUSIC.WAV, 有 EMERG.BMP, 应急页已载好, 应急页放弃, 参数存储状态}
// 只是把现有状态打包，判断“正常 / 警告 / 失败”和逐行显示的节奏都在 boot_splash 里（video_clk 域）
// 扫描完成那一拍最后一张图还没计进 img_found_count，所以“扫描完”晚一拍再报
wire [3:0] boot_mask = loaded | failed;
wire [2:0] boot_ld   = {2'b0, loaded[0]} + {2'b0, loaded[1]} + {2'b0, loaded[2]} + {2'b0, loaded[3]};
wire [2:0] boot_pr   = {2'b0, boot_mask[0]} + {2'b0, boot_mask[1]} + {2'b0, boot_mask[2]} + {2'b0, boot_mask[3]};
reg        boot_scan_d;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        boot_scan_d <= 1'b0;
        boot_info   <= 22'd0;
    end else begin
        boot_scan_d <= scan_done;
        boot_info   <= {font_status, card_missing, sd_init_done, boot_scan_d && scan_done, img_found_count, boot_ld, boot_pr,
                        music_found, emerg_found, emerg_ld, emerg_failed, param_store_status};
    end
end

endmodule

// -----------------------------------------------------------------------------
// 【省资源】按键消抖：和 sd_card_bmp.v 里的 key_press_debounce 行为一样（电平连续 DEBOUNCE_MS 不变才认），
// 但数的是上层共用的 1ms 节拍（节拍相位随机，所以实际门限是 DEBOUNCE_MS-1 ~ DEBOUNCE_MS 毫秒），计数器只要 6 位（原来每个按键一个 32 位计数器数时钟拍）
// -----------------------------------------------------------------------------
module key_debounce_ms #(
    parameter integer DEBOUNCE_MS = 20          // 1~63
)(
    input  wire clk,
    input  wire rst,
    input  wire ms_tick,                        // 1ms 一拍
    input  wire button_in,                      // 默认：松开=1，按下=0
    output reg  press_pulse,
    output wire button_level
);

reg       button_sync0;
reg       button_sync1;
reg       button_stable;
reg [5:0] cnt;
assign button_level = button_stable;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 6'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 6'd0;
        end else if (cnt >= DEBOUNCE_MS) begin   // 数满 DEBOUNCE_MS 个节拍 = 变化后保持了 DEBOUNCE_MS-1 ~ DEBOUNCE_MS 毫秒
            if (button_stable && !button_sync1)
                press_pulse <= 1'b1;
            button_stable <= button_sync1;
            cnt           <= 6'd0;
        end else if (ms_tick) begin
            cnt <= cnt + 6'd1;
        end
    end
end

endmodule
