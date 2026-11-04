#!/bin/bash
# 【自定义字幕】subtitle_strip：custom = 0 时和改之前（bak_sub/subtitle_strip.v）逐像素比较，再测 custom = 1
cd "$(dirname "$0")"
sed 's/^module subtitle_strip #(/module subtitle_strip_prev #(/' bak_sub/subtitle_strip.v > strip_prev_tmp.v
iverilog -g2005 -o strip_cs.out -s tb_strip_cs tb_strip_cs.v ../subtitle_strip.v strip_prev_tmp.v ../subtitle_rom.v && vvp -n strip_cs.out | grep -v finish
rm -f strip_cs.out strip_prev_tmp.v
