


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

// 【修复】SDRAM 刷新间隔
// 原写法宏没有加括号：64000000/1000000000/125000000/2048，从左往右整除得 0，刷新间隔被算成 0。
// 正在显示的 bank 每帧都被读，行被反复激活，相当于一直在刷新；
// 其余 bank 长时间没人读，数据会慢慢掉位，表现为图片上越来越多的固定彩色小点。
// 改为加括号，并按 4096 次/64ms 计算（每 15.6us 刷新一次，适用于所有 64Mbit SDRAM）：
//   64000000 / 8 / 4096 = 1953 个时钟周期
// 【时序 2026-10-30】ext_mem_clk 125MHz → 100MHz（芯片太满，官方 SDRAM 控制器内部路径差 0.37ns；显示带宽只要约 1/5）
`define	  SDR_CLK_PERIOD				(1000000000/100000000)
`define   SELF_REFRESH_INTERVAL			(64000000/`SDR_CLK_PERIOD/4096)

