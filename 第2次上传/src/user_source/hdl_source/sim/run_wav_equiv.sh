#!/bin/bash
# wav_player 改之前 / 改之后等价性。OLD = 旧版文件（默认第 4 轮省资源前的备份，和新版同样有输入寄存器 → SAMELAT）
cd "$(dirname "$0")"
OLD=${OLD:-bak_lut4/wav_player.v}
DEF=${DEF:--DSAMELAT}
sed 's/^module wav_player #(/module wav_player_old #(/' $OLD > wav_old_tmp.v
iverilog -g2005 $DEF -o wav_eq.out -s tb_wav tb_wav_equiv.v wav_old_tmp.v ../wav_player.v && vvp -n wav_eq.out | grep -v finish
rm -f wav_eq.out wav_old_tmp.v
