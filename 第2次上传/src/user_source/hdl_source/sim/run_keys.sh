#!/bin/bash
# 按键回归：改之前（*_pre_lut.v.bak）和改之后各跑一遍，对比按键事件时刻
cd "$(dirname "$0")"
H=..
COMMON="$H/SD/fat32_volume_scanner.v $H/SD/fat32_file_streamer.v $H/SD/bmp_scaler.v $H/SD/sd_card_bmp.v $H/SD/ax_debounce.v
        $H/SD/sd_card_top.v $H/SD/sd_card_cmd.v $H/SD/sd_card_sec_read_write.v $H/SD/spi_master.v"
iverilog -g2005 -DOLDDUT -DOUTFILE='"keys_old.txt"' -o k_old.out -s tb_keys tb_keys.v sd_card_bmp4_pre_lut.v.bak fat32_bmp_read_pre_lut.v.bak param_adjust_pre_lut.v.bak param_store_pre_lut.v.bak $H/flash/*.v $COMMON 2>&1 | grep -i error
iverilog -g2005 -DOUTFILE='"keys_new.txt"' -o k_new.out -s tb_keys tb_keys.v $H/SD/sd_card_bmp4.v $H/SD/fat32_bmp_read.v $H/SD/param_adjust.v $H/param_store.v $H/serial_cmd.v $H/cmd_rom.v $COMMON 2>&1 | grep -i error
vvp -n k_old.out | grep -v KEYS_DONE & vvp -n k_new.out | grep -v KEYS_DONE & wait
echo "old: $(wc -l < keys_old.txt) events, new: $(wc -l < keys_new.txt) events"
# 名字顺序必须一样，时刻相差不超过 1ms
paste keys_old.txt keys_new.txt | awk '{ d = $2 - $4; if (d < 0) d = -d; if ($1 != $3 || d > 1) { bad++; print "DIFF", $0 } }
    END { print (bad ? "KEYS FAIL" : "KEYS PASS") }'
[ "$(wc -l < keys_old.txt)" = "$(wc -l < keys_new.txt)" ] || echo "KEYS FAIL: event count differs"
rm -f k_old.out k_new.out
