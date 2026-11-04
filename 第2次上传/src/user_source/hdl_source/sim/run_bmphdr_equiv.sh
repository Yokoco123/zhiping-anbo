#!/bin/bash
# fat32_bmp_read 改之前 / 改之后：BMP 文件头校验等价性（OLD = 旧版文件）
cd "$(dirname "$0")"
OLD=${OLD:-bak_lut4/fat32_bmp_read.v}
sed 's/^module fat32_bmp_read #(/module fat32_bmp_read_old #(/' $OLD > bmph_old_tmp.v
iverilog -g2005 $DEF -o bmph_eq.out -s tb_bmphdr tb_bmphdr_equiv.v bmph_old_tmp.v ${NEW:-../SD/fat32_bmp_read.v} ../SD/fat32_volume_scanner.v ../SD/fat32_file_streamer.v ../SD/bmp_scaler.v && vvp -n bmph_eq.out | grep -v finish
rm -f bmph_eq.out bmph_old_tmp.v
