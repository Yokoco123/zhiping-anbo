#!/bin/bash
# fat32_volume_scanner 改之前 / 改之后等价性
cd "$(dirname "$0")"
sed 's/^module fat32_volume_scanner (/module fat32_volume_scanner_old (/' ${OLD:-fat32_volume_scanner_pre_lut.v.bak} > scan_old_tmp.v
iverilog -g2005 -o scan_eq.out -s tb_scan tb_scan_equiv.v scan_old_tmp.v ../SD/fat32_volume_scanner.v && vvp -n scan_eq.out | grep -v finish
rm -f scan_eq.out scan_old_tmp.v
