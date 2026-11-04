#!/bin/bash
# 串口指令仿真：A 装字库（小字库，快），B 全部指令（完整字库，开机校验要读 690KB，慢）
cd "$(dirname "$0")"
T=../../../../notice_tool
[ -f font_sim.hex ] || powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w $T/gen_font.ps1)" -Hex "$(cygpath -w $PWD)\font_sim.hex" -Preview '' > /dev/null
[ -f cmd_strings.hex ] || powershell.exe -NoProfile -ExecutionPolicy Bypass -File gen_cmd_strings.ps1 > /dev/null
SRC="../serial_cmd.v ../cmd_rom.v ../param_store.v w25q64_model.v"
iverilog -g2012 -DSMALL -o sc_a.out -s tb_cmd tb_serial_cmd.v $SRC || exit 1
iverilog -g2012         -o sc_b.out -s tb_cmd tb_serial_cmd.v $SRC || exit 1
(vvp -n sc_a.out | grep -v finish > sc_a.txt) & (vvp -n sc_b.out | grep -v finish > sc_b.txt) & wait
echo "---- A (install, small font)"; cat sc_a.txt; echo "---- B (commands, full font)"; cat sc_b.txt
rm -f sc_a.out sc_b.out
