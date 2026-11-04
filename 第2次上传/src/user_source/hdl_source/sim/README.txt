仿真测试平台（iverilog 11 以上，在本目录下运行；Windows 下可用 Git Bash）

1. 串口指令（全部指令、装字库、启事、照片、自定义字幕、断电读回）
     bash run_serial_cmd.sh
   第一次运行会自动生成 font_sim.hex（字库）和 cmd_strings.hex（测试用中文字符串），需要 Windows PowerShell。
   A 部分用小字库，约 10 分钟；B 部分用完整字库，约 1 小时。最后一行 RESULT fails=0 PASS 即通过。

2. 启事页（大字 / 小字 / 带照片，导出 page_out/*.bmp 并逐像素核对）
     mkdir -p page_out
     iverilog -g2012 -o np.out tb_notice_page.v ../notice_page.v ../page_rom.v && vvp -n np.out
   带照片的帧需要 page_out/photo_sdram.hex（由 tb_serial_cmd -DSMALL -DPHREAL 用真实 PHOTO.BIN 生成）；没有时照片框为空，其余检查照常。

3. 其他
   tb_emerg_prev.v       三级应急整体画面（emergency_overlay + osd_layer，导出 emg_prev/*.bmp）；
                         背景图 emg_prev/bg_emerg.hex、bg_pic3.hex、bg_page.hex 是 640×480 每行一个 RRGGBB，
                         用自己的图片生成（未随附，图片有版权），文字 emg_prev/strs.hex 每条 512 字节 UTF-8
   tb_strip_emg.v        字幕条：新旧版本逐像素对比 + 应急文字红 / 橙底（需要旧版 subtitle_strip，未随附，第 2 部分可单独看）
   tb_osd_res.v          左上角原图分辨率标签逐像素核对、字幕 / 波形分开开关
   tb_res_bcd.v          原图宽高记录、跨时钟域、转十进制（200 轮随机尺寸）
   tb_res_sw4.v          SW4 控制分辨率显示
   tb_pbar.v             中文参数条（pbar_out/*.bmp）
   tb_emerg_latency.v    应急告警时延
   tb_boot_splash.v      开机自检、无卡安全页、拔卡提示（splash_out/*.bmp）
   tb_hotplug.v          系统级：行为级 TF 卡 + FAT32 镜像，拔卡 / 换卡 / 坏文件；-DSCHED 测启事插播调度
   tb_keyfunc.v          按键、干接点、开关掉电保存（需要 w25q64_model.v）
   tb_bmp_scaler.v       双线性缩放与独立模型逐点比较
   tb_seg_status.v       数码管
   tb_alarm_siren.v      三级警报音
   bmp2png.ps1           把导出的 BMP 转成 PNG 方便查看

名字带 _equiv 的测试平台和 run_*_equiv.sh、run_keys.sh、run_ka0.sh、run_strip_cs.sh、tb_strip_emg.v 第 1 部分是开发过程中
新旧版本等价比对用的（同样的随机输入，逐字节 / 逐像素比较新旧模块输出），所需的旧版本文件未随附。
