#!/bin/bash
# 拉伸铺满模式（KEEP_ASPECT=0）仿真，用法：在 sim 目录下 ./run_ka0.sh
cd "$(dirname "$0")"
run() { n="ka0_$1_$2"; iverilog -g2005 -o t_$n.out -P tb.SW=$1 -P tb.SH=$2 -P tb.KA=0 tb_bmp_scaler.v ../SD/bmp_scaler.v && vvp -n t_$n.out | grep -E "RESULT|MISMATCH" > r_$n.txt; }
run 640 480 & run 1 1 & run 1000 50 & run 3 480 & run 480 640 &
wait
run 1920 1080 & run 7 5 &
wait
cat r_ka0_*.txt; rm -f t_ka0_*.out; echo KA0DONE
