#!/bin/bash
# boot_splash 改之前 / 改之后逐像素等价（8 个场景）
cd "$(dirname "$0")"
sed 's/^module boot_splash #(/module boot_splash_old #(/' boot_splash_pre_lut.v.bak > splash_old_tmp.v
mkdir -p splash_out
iverilog -g2005 -DEQUIV -o sp_eq.out -s tb_splash tb_boot_splash.v ../boot_splash.v splash_old_tmp.v ../splash_rom.v && vvp -n sp_eq.out | grep -v "dumped\|finish"
rm -f sp_eq.out splash_old_tmp.v
