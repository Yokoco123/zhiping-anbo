#!/bin/bash
# param_store 新旧对比：EW=1 / EW=0 各跑新旧两版，场景全过 + 每步 Flash 内容记录完全一样
cd "$(dirname "$0")"
OLDSRC="param_store_pre_lut.v.bak ../flash/config_flash_journal.v ../flash/config_journal.v ../flash/w25q64_record_store.v ../flash/spi_byte_engine.v ../flash/w25q64_preflight_reader.v"
for ew in 1 0; do
  iverilog -g2012 -DOLD -DLOG='"ps_old.log"' -P tb.EW=$ew -o ps_old.out -s tb tb_param_store.v w25q64_model.v $OLDSRC || exit 1
  iverilog -g2012       -DLOG='"ps_new.log"' -P tb.EW=$ew -o ps_new.out -s tb tb_param_store.v w25q64_model.v ../param_store.v || exit 1
  vvp -n ps_old.out | sed 's/^/  [old] /' | grep "RESULT\|FAIL\|TIMEOUT" &
  vvp -n ps_new.out | sed 's/^/  [new] /' | grep -v finish &
  wait
  if cmp -s ps_old.log ps_new.log; then echo "EW=$ew flash log identical ($(wc -l < ps_new.log) snapshots)"; else echo "EW=$ew FLASH LOG DIFFERS"; diff ps_old.log ps_new.log; fi
done
rm -f ps_old.out ps_new.out
