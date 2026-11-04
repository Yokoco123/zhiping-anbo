
module top(
    input                       clk,
    input                       key_k1,         // 板上 Key1：短按下一张 / 菜单下一项，长按 3 秒复位
    input                       key1,           // 板上 Key2：短按上一张 / 菜单上一项，长按进出缩略图
    input                       key2,           // 板上 Key4：缩略图选中 / 菜单减           // 板上 Key4：轮播 / 参数减
    input                       key_k3,         // 板上 KEY3：参数加 / 音乐暂停
    input  [3:0]                sw,             // 拨码 SW1~SW4
    input                       ext_alarm_n,    // 【按键改造】干接点外部告警：J1 第 10 脚，和 J1 第 12 脚（GND）短接 = 一级应急

	output [7:0]                seg_sel,
	output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso,
    // 用户 Flash U33（参数掉电保存）
    output                      flash_cs_n,
    output                      flash_sclk,
    output                      flash_mosi,
    output                      flash_wp_n,
    output                      flash_hold_n,
    input                       flash_miso,
    // 【应急模式】
    output                      buzzer,         // 板载蜂鸣器，低电平响（SW7 是硬件开关）
    output [3:0]                led,            // 丝印 LED1 应急闪烁 LED2 自动轮播 LED3 背景音乐 LED4 参数菜单
    // 【串口通知】板载 CH340（电脑上是 COM 口），115200 8N1
    input                       uart_rx,
    output                      uart_tx
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;
parameter BUF2_ADDR     = FRAME_PIXELS * 2;   // 四 bank
parameter BUF3_ADDR     = FRAME_PIXELS * 3;
parameter BUF4_ADDR     = FRAME_PIXELS * 4;   // 【应急模式】EMERG.BMP
parameter PH_PIXELS     = 24'd204800;         // 【串口照片】照片写 320 行 x 640
parameter PH0_ADDR      = FRAME_PIXELS * 5;   // 【串口照片】两块照片缓冲（按整帧读，照片在第 112~431 行）
parameter PH1_ADDR      = FRAME_PIXELS * 5 + PH_PIXELS;
parameter PH_WOFF       = 24'd30720;          // 【串口照片】写口从 +479 行开始往上写：基地址减 48 行

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire        display_valid;

wire [3:0]  state_code;
wire [3:0]  img_num;
wire [3:0]  err_code;
wire [6:0]  seg_err_code;
wire        auto_on;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;
// 转场
wire [1:0]  show_buf_idx;     // 转场模块管理的"正在显示的 bank"
wire [3:0]  shown_num;        // 正在显示的图片号，给 OSD
wire        switch_auto;
wire        trans_busy;
wire [23:0] trans_rgb;
wire        thumb_mode;       // 按键想看缩略图（sd_card_clk 域）
wire        show_thumb;       // 实际显示缩略图（video_clk 域，只在全黑时变）
wire [3:0]  loaded_mask;
wire        tone_allow;
// 【应急模式】
wire        write_emerg;
wire        write_photo, write_pbuf;   // 【串口照片】
wire        emerg_ok;
wire        show_emerg;
wire        need_builtin;
wire [23:0] emerg_rgb;
wire        emerg_blink;
// 【开机画面】
wire [21:0] boot_info;
// 【串口指令】串口助手发来的通知 / 字幕开关 / 非法口令（serial_cmd 在 sd_card_bmp4 里，这些已同步到 video_clk）
wire        ntc_on, ntc_new, ntc_reject, ntc_sub_off;
wire        ntc_cs;                      // 【自定义字幕】字幕条显示这张图的串口自定义字幕
wire [33:0] v_res;
wire [10:0] ntc_len;
wire [9:0]  ntc_col;
wire [15:0] ntc_bits;
// 【三级应急】实际等级（SW1 = 一级）、应急文字（video_clk 域）；警报音是否在用
wire [1:0]  alm_lvl;
wire [9:0]  alm_len;
wire [9:0]  alm_col;
wire        siren_on;
wire        alm_mute;           // 【按键改造】已消音（video_clk 域）
wire        mute_on;            // 【按键改造】已消音（sd_card_clk 域，给数码管）
// 【启事】启事页：调度（sd_card_clk 域）→ 转场（只在黑屏时切）→ 启事页；读口和内容说明（video_clk 域）
wire        want_page, want_pbuf;
wire        show_page, show_pbuf;
wire [6:0]  page_info;
wire [10:0] pg_col;
wire [20:0] pg_meta;
wire        show_ph = show_page && pg_meta[19];   // 【串口照片】正在显示带照片的启事页
wire [23:0] page_rgb;
wire        boot_done;          // 开机自检完成：开机画面结束、转场开始淡入第一张图
wire [23:0] splash_rgb;
wire        splash_on;
wire signed [15:0] siren_pcm;

// 参数调节
wire        key_rst_req;
wire [3:0]  sw_on;
wire [7:0]  bri_pct, con_pct, vol_pct;
wire        music_pause;
wire [2:0]  period_idx;
wire [1:0]  menu_sel;
wire [3:0]  v_sw;
wire [7:0]  v_bri, v_con, v_vol;
wire        v_pause;
wire [2:0]  v_period;
wire [1:0]  v_menu_sel;
wire [7:0]  wav_volume, tone_volume;

// 背景音乐
wire        music_byte_valid;
wire [7:0]  music_byte;
wire [31:0] music_off;
wire        music_hold;
wire [3:0]  wav_status;
wire        wav_active;
wire signed [15:0] wav_left;
wire signed [15:0] wav_right;
wire               pcm_tap_valid;   // 送进 HDMI 的音频，给波形显示
wire signed [15:0] pcm_tap_left;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 相关
wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 链路
wire sys_pll_lock;
wire video_pll_lock;
wire rst_all;

// Key1 不再直接当复位：按住 3 秒才复位；上电复位照常（等 PLL 锁定 + 20ms）
key_reset_req #(
    .CLK_FREQ_HZ (50_000_000),
    .HOLD_MS     (3000)
) u_key_reset_req (
    .clk     (clk),
    .key_n   (key_k1),
    .rst_req (key_rst_req)
);

reg [19:0] rst_cnt = 20'd0;
reg rst_all_reg = 1'b1;

always @(posedge clk) begin
    if (key_rst_req) begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end else if (!rst_all_reg) begin
        // 一旦复位释放，忽略后续微小的 PLL 抖动，防止系统在使用时随机复位
        rst_all_reg <= 1'b0;
    end else if (sys_pll_lock && video_pll_lock) begin
        // 等待 PLL 连续稳定 20ms @ 50MHz
        if (rst_cnt < 20'd1_000_000) begin
            rst_cnt <= rst_cnt + 1'b1;
            rst_all_reg <= 1'b1;
        end else begin
            rst_all_reg <= 1'b0;
        end
    end else begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end
end

assign rst_all = rst_all_reg;
// 每个时钟域各用一个复位同步器：异步复位、同步释放
// rst_all 是 50MHz 域产生的，直接送进其它时钟域会让各域在不同时刻退出复位
wire rst_n_sd, rst_n_mem, rst_n_vid;
reset_sync u_rst_sync_sd  (.clk(sd_card_clk), .ext_rst_n(~rst_all), .rst_n_sync(rst_n_sd));
reset_sync u_rst_sync_mem (.clk(ext_mem_clk), .ext_rst_n(~rst_all), .rst_n_sync(rst_n_mem));
reset_sync u_rst_sync_vid (.clk(video_clk),   .ext_rst_n(~rst_all), .rst_n_sync(rst_n_vid));
wire rst_sd  = ~rst_n_sd;     // 官方模块是高有效复位
wire rst_mem = ~rst_n_mem;
wire rst_vid = ~rst_n_vid;

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (sys_pll_lock),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (video_pll_lock),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if (rst_mem)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

wire [3:0] ps_status;

// ===================== TF 多图扫描与缓存（双缓冲） =====================
sd_card_bmp4 #(
    .CLK_FREQ_HZ       (75_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_sd),
    .key_next          (key1),
    .key_auto          (key2),
    .key_prev          (key_k1),
    .key_plus          (key_k3),
    .sw                (sw),
    .sw_on             (sw_on),
    .ext_alarm_n       (ext_alarm_n),
    .mute_on           (mute_on),
    .bri_pct           (bri_pct),
    .con_pct           (con_pct),
    .vol_pct           (vol_pct),
    .music_pause       (music_pause),
    .period_idx        (period_idx),
    .menu_sel          (menu_sel),
    .tone_allow        (tone_allow),
    .write_emerg       (write_emerg),
    .write_photo       (write_photo),
    .write_pbuf        (write_pbuf),
    .emerg_ok          (emerg_ok),
    .state_code        (state_code),
    .img_num           (img_num),
    .err_code          (err_code),
    .auto_on           (auto_on),
    .thumb_mode        (thumb_mode),
    .loaded_mask       (loaded_mask),
    .switch_auto       (switch_auto),
    .trans_busy        (trans_busy),
    .music_byte_valid  (music_byte_valid),
    .music_byte        (music_byte),
    .music_off         (music_off),
    .music_hold        (music_hold),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso),
    .FLASH_CS_N        (flash_cs_n),
    .FLASH_SCLK        (flash_sclk),
    .FLASH_MOSI        (flash_mosi),
    .FLASH_WP_N        (flash_wp_n),
    .FLASH_HOLD_N      (flash_hold_n),
    .FLASH_MISO        (flash_miso),
    .param_store_status(ps_status),
    .boot_info         (boot_info),
    .uart_rx           (uart_rx),
    .uart_tx           (uart_tx),
    .vclk              (video_clk),
    .vrst_n            (rst_n_vid),
    .ntc_col           (ntc_col),
    .ntc_bits          (ntc_bits),
    .ntc_on            (ntc_on),
    .ntc_len           (ntc_len),
    .ntc_new           (ntc_new),
    .ntc_reject        (ntc_reject),
    .ntc_sub_off       (ntc_sub_off),
    .v_shown           (shown_num),
    .ntc_cs            (ntc_cs),
    .v_res             (v_res),
    .alm_col           (alm_col),
    .alm_lvl           (alm_lvl),
    .alm_len           (alm_len),
    .alm_mute          (alm_mute),
    .want_page         (want_page),
    .want_pbuf         (want_pbuf),
    .page_info         (page_info),
    .pv_sel            (show_page),
    .pv_buf            (show_pbuf),
    .pv_col            (pg_col),
    .pv_meta           (pg_meta)
);

wire [7:0]  emg_lat;          // 【应急时延实测】拨 SW1 到应急画面出现的时间，0.1ms 一档
wire        emg_lat_ok;

// 【数码管】8 位只显示关键参数：左 4 位节目（P2-4），右 4 位音量 / 菜单里正在调的那一项；应急时 SOS
seg_status u_seg_status(
    .clk               (sd_card_clk),
    .rst               (rst_sd),
    .emerg             (sw_on[0]),
    .menu_on           (sw_on[1]),
    .display_valid     (display_valid),
    .img_num           (img_num),
    .img_total         (boot_info[16:14]),
    .err_code          (err_code),
    .bri_pct           (bri_pct),
    .con_pct           (con_pct),
    .vol_pct           (vol_pct),
    .period_idx        (period_idx),
    .menu_sel          (menu_sel),
    .lat_val           (emg_lat),
    .lat_ok            (emg_lat_ok),
    .page_info         (page_info),
    .muted             (mute_on),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data)
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_vid),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_vid),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// 首图提交前黑屏由 video_transition 负责（它内部已把 display_valid 同步到 video_clk，没图时输出全黑）
// 2026-10-24 时序收敛：这里不再用未同步的 display_valid 直接门控像素
assign vout_data = vout_data_raw;

// 参数同步到 video_clk
ctrl_to_video u_ctrl_to_video (
    .clk         (video_clk),
    .rst_n       (rst_n_vid),
    .sw_on       (sw_on),
    .bri_pct     (bri_pct),
    .con_pct     (con_pct),
    .vol_pct     (vol_pct),
    .music_pause (music_pause),
    .period_idx  (period_idx),
    .menu_sel    (menu_sel),
    .tone_allow  (tone_allow | (wav_status == 4'd6)),   // 没有 MUSIC.WAV 或格式不支持时才放琶音
    .v_sw        (v_sw),
    .v_bri       (v_bri),
    .v_con       (v_con),
    .v_vol       (v_vol),
    .v_pause     (v_pause),
    .v_period    (v_period),
    .v_menu_sel  (v_menu_sel),
    .wav_volume  (wav_volume),
    .tone_volume (tone_volume)
);

// 【启事】启事页：转场切到启事页时（show_page）整屏换成 FPGA 画的启事页，跟图片一样淡入淡出
notice_page u_notice_page (
    .clk           (video_clk),
    .rst_n         (rst_n_vid),
    .vs            (vs),
    .de            (de),
    .rgb_in        (vout_data),
    .sel           (show_page),
    .meta          (pg_meta),
    .col           (pg_col),
    .bits          (ntc_bits),
    .rgb_out       (page_rgb)
);

// 转场：淡入淡出 / Wipe，放在 OSD 前面，状态条和字幕不跟着变暗
video_transition #(
    .FADE_FRAMES   (16),
    .HOLD_FRAMES   (2)
) u_video_transition (
    .clk           (video_clk),
    .rst_n         (rst_n_vid),
    .vs            (vs),
    .de            (de),
    .rgb_in        (page_rgb),
    .rgb_out       (trans_rgb),
    .display_valid (boot_done),
    .want_idx      (disp_buf_idx),
    .want_auto     (switch_auto),
    .want_thumb    (thumb_mode),
    .loaded        (loaded_mask),
    .want_page     (want_page),
    .want_pbuf     (want_pbuf),
    .bri_pct       (v_bri),
    .con_pct       (v_con),
    .want_emerg    (sw_on[0]),
    .emerg_ok      (emerg_ok),
    .show_idx      (show_buf_idx),
    .show_thumb    (show_thumb),
    .show_emerg    (show_emerg),
    .show_page     (show_page),
    .show_pbuf     (show_pbuf),
    .need_builtin  (need_builtin),
    .shown_num     (shown_num),
    .busy          (trans_busy),
    .emg_lat       (emg_lat),
    .emg_lat_ok    (emg_lat_ok)
);

// 【开机画面】第一张图出来之前显示启动页（进度条 + 状态 / 出错原因），在应急层前面
boot_splash u_boot_splash (
    .clk           (video_clk),
    .rst_n         (rst_n_vid),
    .vs            (vs),
    .de            (de),
    .rgb_in        (trans_rgb),
    .display_valid (display_valid),
    .boot_info     (boot_info),
    .err_code      (err_code),
    .alert         (v_sw[0]),
    .reject        (ntc_reject),
    .rgb_out       (splash_rgb),
    .splash_on     (splash_on),
    .boot_done     (boot_done)
);

// 【应急模式】闪烁红框 + 没有 EMERG.BMP 时的内置警示页（在转场后面，不跟着淡入淡出）
emergency_overlay u_emergency_overlay (
    .clk           (video_clk),
    .rst_n         (rst_n_vid),
    .vs            (vs),
    .de            (de),
    .rgb_in        (splash_rgb),
    .emerg_on      (v_sw[0]),
    .builtin_on    (need_builtin),
    .level         (alm_lvl),
    .a_len         (alm_len),
    .a_col         (alm_col),
    .a_bits        (ntc_bits),
    .s_col         (ntc_col),
    .page_on       (show_page),
    .rgb_out       (emerg_rgb),
    .blink         (emerg_blink)
);

// OSD：左上角状态条 + 底部滚动字幕
// 字幕最多 12 个字符，要倒着写（第一个字符放在最右边）。这里是 "ZHIPING ANBO"
wire [23:0] osd_rgb;
osd_layer #(
    .SUBTITLE_Y    (448)
) u_osd_layer (
    .clk           (video_clk),
    .rst_n         (rst_n_vid),
    .vs            (vs),
    .de            (de),
    .rgb_in        (emerg_rgb),
    .img_num       (shown_num),
    .auto_on       (auto_on),
    .err_code      (err_code),
    .subtitle_on   (~ntc_sub_off),          // 【串口指令】字幕关
    .subtitle_text ("OBNA GNIPIHZ"),
    .subtitle_len  (6'd12),
    .wave_on       (~show_thumb),
    .pcm_valid     (pcm_tap_valid),
    .pcm_left      (pcm_tap_left),
    .osd_on        (v_sw[3] && !show_page),
    .menu_on       (v_sw[1]),
    .menu_sel      (v_menu_sel),
    .bri_pct       (v_bri),
    .con_pct       (v_con),
    .vol_pct       (v_vol),
    .period_idx    (v_period),
    .alert         (v_sw[0]),
    .thumb_on      (show_thumb),
    .notice_on     (ntc_on),
    .notice_len    (ntc_len),
    .notice_new    (ntc_new),
    .notice_col    (ntc_col),
    .notice_bits   (ntc_bits),
    .notice_cs     (ntc_cs),
    .res_info      (v_res),
    .alm_level     (alm_lvl),
    .rgb_out       (osd_rgb)
);

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (show_emerg ? BUF4_ADDR : show_ph ? (show_pbuf ? PH1_ADDR : PH0_ADDR) : BUF0_ADDR),   // 【应急模式】【串口照片】
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (BUF2_ADDR),
    .read_addr_3       (BUF3_ADDR),
    .read_addr_index   ((show_emerg || show_ph) ? 2'd0 : show_buf_idx),
    .read_len          (FRAME_PIXELS),
    .thumb_mode        (show_thumb),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (write_photo ? ((write_pbuf ? PH1_ADDR : PH0_ADDR) - PH_WOFF) : write_emerg ? BUF4_ADDR : BUF0_ADDR),  // 【应急模式】【串口照片】
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (BUF2_ADDR),
    .write_addr_3      (BUF3_ADDR),
    .write_addr_index  (write_photo ? 2'd0 : write_buf_idx),
    .write_len         (write_photo ? PH_PIXELS : FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_vid),
    .I_vs          (vs),
    .I_de          (de),
    .I_rgb         (osd_rgb),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_vid),
    .O_pulse (edid_trig)
);

// img_num 来自 sd_card_clk 域：先打拍同步到 video_clk 域，连续两拍一致才采用，
// 防止多位信号跨域时瞬间出现错码
reg [3:0] img_num_s1, img_num_s2, img_num_s3;
reg [1:0] media_id;
always @(posedge video_clk or posedge rst_vid) begin
    if (rst_vid) begin
        img_num_s1 <= 4'd0;
        img_num_s2 <= 4'd0;
        img_num_s3 <= 4'd0;
        media_id   <= 2'd0;
    end else begin
        img_num_s1 <= img_num;
        img_num_s2 <= img_num_s1;
        img_num_s3 <= img_num_s2;
        if ((img_num_s2 == img_num_s3) && (img_num_s3 != 4'd0))
            media_id <= img_num_s3[1:0] - 2'd1;   // 图片 1~4 → 旋律 0~3
    end
end

wire               tone_valid;
wire signed [15:0] tone_left;
wire signed [15:0] tone_right;
wire               acr_valid;
wire [19:0]        acr_cts;
wire [19:0]        acr_n;

// 正弦琶音：每张图一段旋律，切图时先响 100ms 提示音
pcm_media_tone #(
    .CLOCK_HZ     (25_000_000),
    .SAMPLE_HZ    (48_000)
) u_pcm_media_tone (
    .clk          (video_clk),
    .rst_n        (rst_n_vid),
    .media_id     (media_id),
    .volume       (tone_volume),         // 音量 0~255
    .sample_valid (tone_valid),
    .sample_ready (1'b1),            // 官方核随时接收，valid 即单拍采样脉冲
    .sample_left  (tone_left),
    .sample_right (tone_right),
    .overflow     (),
    .blip_active  ()
);

// ACR：根据采样节拍实测 CTS，N=6144（48kHz）
audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_vid),
    .I_audio_valid (tone_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// WAV 背景音乐：sample_tick 用琶音的节拍，ACR 不用改
wav_player #(
    .ADDR_W        (12)
) u_wav_player (
    .wr_clk        (sd_card_clk),
    .wr_rst        (rst_sd),
    .byte_valid    (music_byte_valid),
    .byte_data     (music_byte),
    .byte_off      (music_off),
    .hold          (music_hold),
    .status        (wav_status),
    .rd_clk        (video_clk),
    .rd_rst_n      (rst_n_vid),
    .sample_tick   (tone_valid),
    .volume        (wav_volume),
    .pause         (v_pause),
    .out_left      (wav_left),
    .out_right     (wav_right),
    .active        (wav_active)
);

assign pcm_tap_valid = tone_valid;
// 【应急模式】警笛
alarm_siren u_alarm_siren (
    .clk         (video_clk),
    .rst_n       (rst_n_vid),
    .sample_tick (tone_valid),
    .level       (alm_lvl),
    .volume      (wav_volume),
    .mute        (alm_mute),
    .out         (siren_pcm),
    .active      (siren_on),
    .buzzer_n    (buzzer)
);

assign pcm_tap_left  = siren_on ? siren_pcm : wav_active ? wav_left : tone_left;

// ===================== HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_vid),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (tone_valid),
    .I_audio_left_data  ({pcm_tap_left, 8'd0}),
    .I_audio_right_data ({(siren_on ? siren_pcm : wav_active ? wav_right : tone_right), 8'd0}),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_vid),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

// 【应急模式】板载 LED（高电平亮）
assign led = {v_sw[1], (wav_active & ~v_pause), auto_on, (v_sw[0] & emerg_blink)};

endmodule
