# 智屏安播：社区分级信息发布终端 —— 代码说明

基于安路 EG4S20BG256 FPGA（HX4S20C 开发板）的社区信息发布终端。全部功能由 FPGA 硬件逻辑实现，不用处理器和操作系统：

- **日常**：轮播 TF 卡图片，带滚动字幕、音频波形和背景音乐
- **启事**：串口发布寻人、寻物、失物招领启事并立即插播，可附照片，字号随字数自动选择
- **应急**：三级接管（紧急撤离 / 就地避险 / 区域警戒），可由按键、串口、外部干接点触发

---

## 1. 目录结构

```text
README.md                       本文件（代码说明）
下载文件/智屏安播.bit            编译好的比特流，可直接下载到开发板
src/td_project/                 安路 TD 工程（打开 lab_ex5_i2s_v1.0.al）
src/user_source/hdl_source/     Verilog 源码（见第 5 节模块说明）
    IP/                         FIFO、SDRAM、PLL 等 IP（TD IP 工具生成）
    SD/                         TF 卡、FAT32、BMP、缩放、帧缓存、播放调度
    flash/                      早期参数存储模块（已由 param_store.v 取代，保留在工程里但未被顶层使用）
    include/                    官方 SDRAM 控制器（加密）和全局定义
    subtitle/                   文字配置 + 生成脚本：改文字后双击 .bat 重新生成 ROM，TD 重新编译
    sim/                        仿真测试平台（iverilog）
src/user_source/constraints_source/   引脚约束 pin.adc、时序约束 timing.sdc
src/user_source/ip_source/      官方例程 PLL
notice_tool/                    电脑端工具：智屏安播控制台.exe（按钮发启事 / 照片 / 应急 / 开关，双击即用）、字库生成；使用说明.txt（串口指令大全）
```

## 2. 硬件连接

| 接口 | 说明 |
|---|---|
| HDMI_B | 接显示器（HDMI_A 不用） |
| TF 卡座 | 节目图片、应急图、背景音乐 |
| USB 串口（CH340） | 接电脑串口助手：921600 bps，8-1-无校验，UTF-8，文本模式 |
| J1 第 10 脚 / 第 12 脚（GND） | 外部干接点告警输入：短接 3 ms 以上 = 一级应急 |
| Key1～Key4、SW2 | 见下表 |

| 按键 | 短按 | 长按 |
|---|---|---|
| Key1 | 下一张 | 按住 3 s 复位 |
| Key2 | 上一张 | 1 s 进出缩略图 |
| KEY3 | 音乐暂停 / 继续（应急时 = 消音） | 1 s 字幕开关 |
| KEY3 + Key2 同时按 | 音频波形开关 | |
| Key4 | 自动轮播开关（缩略图里 = 选中） | 1 s 一级应急进入 / 解除 |
| SW2 | 拨开 = 参数菜单（亮度、对比度、音量、轮播周期），这时四个键只调参数 | |
| SW4 | 拨开 = 左上角显示原图分辨率（如 1078x1262 -> 640x480） | |

数码管：左边显示 `P2-4`（第 2 张 / 共 4 张），启事页显示 `n2-3`，应急时显示 `SOS`；右边显示音量，应急时显示实测告警时延（ms）。

## 3. TF 卡内容（FAT32，放在根目录）

| 文件 | 要求 | 用途 |
|---|---|---|
| PIC1.BMP ～ PIC4.BMP | 24 位 BMP，任意尺寸（1～4096），FPGA 双线性缩放到 640×480 | 日常轮播画面 |
| EMERG.BMP | 同上，可选 | 一级应急全屏画面（如疏散示意图）；没有就用内置警示页。二级始终用内置“就地避险”页 |
| MUSIC.WAV | 48 kHz、16 位、立体声 PCM，可选 | 背景音乐；没有就播放内置旋律 |

注意 Windows 默认隐藏扩展名，文件名不要变成 `PIC1.BMP.bmp`。不插卡也能开机，会显示内置安全提示页，插卡后自动载入。

## 4. 快速复现

1. 用 TD 打开 `src/td_project/lab_ex5_i2s_v1.0.al`，编译；或直接下载 `下载文件/智屏安播.bit`。
2. 插好 TF 卡、接 HDMI_B，上电：开机自检页逐项出现，随后开始轮播。
3. **第一次使用要装字库**（只装一次，存在板载 Flash，断电不丢）：
   - 双击 `notice_tool/gen_font.bat` 生成 `FONT.BIN`；
   - 串口助手发送 `8848 装字库`，收到 READY 后，用"发送文件"发送 `FONT.BIN`。
4. 演示最方便：双击 `notice_tool/智屏安播控制台.exe`，选 CH340 串口、点“连接”，按按钮操作（启事、照片、应急、通知、字幕、开关）。
   也可以用任意串口助手：发 `8848 帮助` 查看全部指令。常用的：
   ```text
   8848 寻人 张大爷，75岁，身穿蓝色外套……      发布启事并立即插播
   8848 照片1                                  给第 1 条启事加照片（PHOTO.BIN 由 gen_photo.bat 生成）
   8848 字幕1 欢迎回家                          改第 1 张图的字幕（8848 字幕1 不写内容 = 恢复默认）
   8848 应急1 火灾   /   8848 解除              一级应急 / 解除
   ```
   完整说明见 `notice_tool/使用说明.txt`。口令 8848、关键字、回复文字都在 `hdl_source/subtitle/cmd.txt` 里，可以改。

## 5. 主要模块

### 5.1 时钟

| 时钟 | 频率 | 用途 |
|---|---|---|
| sd_card_clk | 75 MHz | TF 卡、FAT32、缩放、串口、Flash、调度 |
| ext_mem_clk | 100 MHz | SDRAM 帧缓存 |
| video_clk | 25 MHz | 640×480 视频流水线 |
| 5× 视频时钟 | 125 MHz | HDMI 串行输出 |

### 5.2 模块清单（自研或大幅改写的）

| 文件 | 功能 |
|---|---|
| top_tf_hdmi_audio.v | 顶层：时钟复位、各模块连线、SDRAM 缓冲地址分配 |
| SD/sd_card_bmp4.v | 播放调度：开机载图、轮播、按键、应急等级合成、启事插播、拔卡恢复、照片写口仲裁 |
| SD/fat32_volume_scanner.v | FAT32 扫描：MBR / DBR / 根目录，边收扇区边解析，按文件名找 PIC1～4、EMERG、MUSIC |
| SD/fat32_file_streamer.v | 按簇链流式读取文件 |
| SD/fat32_bmp_read.v | BMP 头校验、超时跳过坏文件、读音乐、拔卡探测 |
| SD/bmp_scaler.v | 任意尺寸 → 640×480 可分离双线性缩放（加载时流式完成） |
| SD/frame_fifo_read.v / frame_fifo_write.v / frame_read_write.v | 帧缓存读写，修正了官方例程忽略 SDRAM 忙信号的问题；缩略图读法 |
| SD/param_adjust.v | 参数菜单 |
| serial_cmd.v | 串口指令：口令、关键字、UTF-8 解码、Flash 字库渲染、启事 / 字幕 / 照片存储、应急文字、文件安装与 CRC32 校验 |
| param_store.v | 参数掉电保存（Flash 双槽轮换、版本号、CRC、写后读回） |
| video_transition.v | 转场（淡入淡出、擦除）、缩略图、应急硬切、告警时延测量 |
| notice_page.v | 启事页：标题栏、照片框、大字 / 小字两种排版 |
| boot_splash.v | 开机自检页、无卡安全页、拔卡提示框 |
| emergency_overlay.v | 一 / 二级闪烁边框和内置警示页（警示三角 + 中文标题，点阵由 subtitle/gen_etitle.ps1 生成）、三级细边框和“区域警戒”标签 |
| osd_layer.v / subtitle_strip.v | OSD：原图分辨率标签、滚动字幕（默认 / 自定义 / 通知 / 应急）、波形、参数条 |
| alarm_siren.v | 三级警报音、消音 |
| wav_player.v | WAV 解析与播放 |
| seg_status.v | 8 位数码管 |
| *_rom.v | 字幕、启事页标题、开机画面、指令文字的点阵 / 字符 ROM（由 subtitle/ 下的脚本生成，不要手改） |

官方例程提供、本工程未改动或只做少量修改的：HDMI 发送 IP、SDRAM 控制器、sd_card_top / sd_card_cmd / sd_card_sec_read_write / spi_master、video_timing_data、promax_audio_waveform 等。另外 `include/global_def.v` 修正了官方 SDRAM 自刷新间隔宏缺括号（结果为 0、不刷新）的问题。

### 5.3 板载 Flash 分区

| 地址 | 内容 |
|---|---|
| 0x000000～0x0A8FFF | 字库（标记 ZPFONT01 + CRC32） |
| 0x100000 | 4 条启事（标记 QS02） |
| 0x101000 | 4 张图的自定义字幕（标记 SB01） |
| 0x200000～0x5FFFFF | 4 张启事照片，每张 1 MB（标记 ZPPHOT02 + CRC32） |
| 0x7FE000～0x7FFFFF | 参数 |

## 6. 仿真

`src/user_source/hdl_source/sim/` 下是 iverilog 测试平台（iverilog 11 以上，部分需要 `-g2012`）。主要的：

| 测试平台 | 内容 |
|---|---|
| tb_serial_cmd.v（run_serial_cmd.sh） | 串口全部指令、装字库、启事、照片、字幕、断电读回；A 用小字库（约 10 分钟），B 用完整字库（约 1 小时） |
| tb_notice_page.v | 启事页各种版面，导出 BMP 并逐像素核对 |
| tb_emerg_prev.v / tb_strip_emg.v / tb_emerg_latency.v | 三级应急整体画面（导出 BMP）、应急字幕条、告警时延 |
| tb_boot_splash.v | 开机自检、安全页、拔卡提示 |
| tb_hotplug.v | 系统级：行为级 TF 卡 + FAT32 镜像，拔卡 / 换卡 / 坏文件 |
| tb_keyfunc.v | 按键、干接点、开关掉电保存 |
| tb_bmp_scaler.v | 双线性缩放与独立模型逐点比较 |
| tb_osd_res.v / tb_res_bcd.v | 原图分辨率标签（逐像素核对）、宽高跨时钟域与十进制转换、字幕 / 波形分开开关 |

串口测试用的中文字符串由 `gen_cmd_strings.ps1` 生成；字库由 `notice_tool/gen_font.ps1 -Hex` 生成 `font_sim.hex`（`run_serial_cmd.sh` 会自动生成）。名字带 `_equiv` 的是开发中做新旧版本等价比对用的，需要的旧版本文件没有随附。

## 7. 资源占用（EG4S20BG256）

LUT 17960 / 19600（91.6%），REG 9171，BRAM9K 64 / 64，BRAM32K 16 / 16，DSP 19 / 29，PLL 2。
