#!/bin/bash
# fat32_file_streamer 改之前 / 改之后等价性
cd "$(dirname "$0")"
sed 's/^module fat32_file_streamer #(/module fat32_file_streamer_old #(/' fat32_file_streamer_pre_t2.v.bak > strm_old_tmp.v
iverilog -g2005 -o strm_eq.out -s tb_strm tb_streamer_equiv.v strm_old_tmp.v ${1:-../SD/fat32_file_streamer.v} && vvp -n strm_eq.out | grep -v finish
rm -f strm_eq.out strm_old_tmp.v
