`timescale 1ns/1ps
// 参考工程原文件，2026-10-24 为时序收敛改成串行 CRC（输出内容和原版一致，仿真逐条对比通过）：
//   原版在一拍里算完 80 位 CRC16（组合逻辑 10 级以上，100MHz 下 -5.9ns）。
//   现在一拍只移 1 位，80 拍算完一条记录：
//     load_start → 算槽0 CRC → 算槽1 CRC → 比较版本、选槽 → load_done   （约 1.6us）
//     save_start → 锁存记录 → 重新校验两槽定目标槽 → 算记录 CRC → record_ready（约 2.4us）
//   load_done / record_ready 比原版晚，上层 config_flash_journal 本来就是等这两个信号，不用改。
//   两槽数据在这期间不变（上层在 ST_LOAD_WAIT / ST_RECORD_WAIT 里等）。

module config_journal (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load_start,
    input  wire        slot0_present,
    input  wire [31:0] slot0_version,
    input  wire [31:0] slot0_period,
    input  wire [7:0]  slot0_volume,
    input  wire [7:0]  slot0_mode,
    input  wire [15:0] slot0_crc,
    input  wire        slot1_present,
    input  wire [31:0] slot1_version,
    input  wire [31:0] slot1_period,
    input  wire [7:0]  slot1_volume,
    input  wire [7:0]  slot1_mode,
    input  wire [15:0] slot1_crc,
    output reg         load_done,
    output reg         config_valid,
    output reg  [31:0] active_version,
    output reg  [31:0] active_period,
    output reg  [7:0]  active_volume,
    output reg  [7:0]  active_mode,
    input  wire        save_start,
    input  wire [31:0] save_period,
    input  wire [7:0]  save_volume,
    input  wire [7:0]  save_mode,
    output reg         record_ready,
    output reg         target_slot,
    output reg  [31:0] record_version,
    output reg  [31:0] record_period,
    output reg  [7:0]  record_volume,
    output reg  [7:0]  record_mode,
    output reg  [15:0] record_crc
);
    function [15:0] crc16_word;
        input [79:0] payload;
        integer i;
        reg [15:0] crc;
        begin
            crc = 16'hffff;
            for (i = 79; i >= 0; i = i - 1) begin
                if (crc[15] ^ payload[i])
                    crc = {crc[14:0],1'b0} ^ 16'h1021;
                else
                    crc = {crc[14:0],1'b0};
            end
            crc16_word = crc;
        end
    endfunction

    function version_newer;
        input [31:0] candidate;
        input [31:0] reference;
        reg [31:0] delta;
        begin
            delta = candidate - reference;
            version_newer = (candidate != reference) && !delta[31];
        end
    endfunction

    // 【时序收敛】串行 CRC16（多项式 0x1021、初值 FFFF、高位先进，和 crc16_word 逐位循环完全相同）
    localparam [2:0] J_IDLE = 3'd0;
    localparam [2:0] J_CRC0 = 3'd1;     // 校验槽0
    localparam [2:0] J_CRC1 = 3'd2;     // 校验槽1
    localparam [2:0] J_PICK = 3'd3;     // 选槽（读取）或定目标槽（保存）
    localparam [2:0] J_RCRC = 3'd4;     // 算新记录的 CRC

    reg  [2:0]  jst;
    reg         is_save;
    reg  [79:0] sh;                     // 待校验内容，每拍左移 1 位
    reg  [15:0] crc;
    reg  [6:0]  bit_cnt;
    reg         good0, good1, newer1;
    wire [15:0] crc_next  = (crc[15] ^ sh[79]) ? ({crc[14:0],1'b0} ^ 16'h1021) : {crc[14:0],1'b0};
    wire        last_bit  = (bit_cnt == 7'd79);
    wire        use_slot0 = good0 && (!good1 || !newer1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_done<=0; config_valid<=0; active_version<=0; active_period<=0;
            active_volume<=0; active_mode<=0; record_ready<=0; target_slot<=0;
            record_version<=0; record_period<=0; record_volume<=0; record_mode<=0;
            record_crc<=0;
            jst<=J_IDLE; is_save<=0; sh<=0; crc<=16'hffff; bit_cnt<=0;
            good0<=0; good1<=0; newer1<=0;
        end else begin
            load_done<=0;
            record_ready<=0;
            case (jst)
                J_IDLE: begin
                    // 上层不会同时发两个请求；万一同时来，先做读取
                    if (load_start || save_start) begin
                        is_save <= !load_start;
                        if (!load_start) begin
                            record_version <= active_version + 1'b1;
                            record_period  <= save_period;
                            record_volume  <= save_volume;
                            record_mode    <= save_mode;
                        end
                        sh      <= {slot0_version,slot0_period,slot0_volume,slot0_mode};
                        crc     <= 16'hffff;
                        bit_cnt <= 0;
                        jst     <= J_CRC0;
                    end
                end
                J_CRC0: begin
                    crc     <= crc_next;
                    sh      <= {sh[78:0],1'b0};
                    bit_cnt <= bit_cnt + 1'b1;
                    if (last_bit) begin
                        good0   <= slot0_present && (crc_next == slot0_crc);
                        sh      <= {slot1_version,slot1_period,slot1_volume,slot1_mode};
                        crc     <= 16'hffff;
                        bit_cnt <= 0;
                        jst     <= J_CRC1;
                    end
                end
                J_CRC1: begin
                    crc     <= crc_next;
                    sh      <= {sh[78:0],1'b0};
                    bit_cnt <= bit_cnt + 1'b1;
                    if (last_bit) begin
                        good1   <= slot1_present && (crc_next == slot1_crc);
                        newer1  <= version_newer(slot1_version,slot0_version);
                        jst     <= J_PICK;
                    end
                end
                J_PICK: begin
                    if (is_save) begin
                        target_slot <= use_slot0 ? 1'b1 : 1'b0;
                        sh          <= {record_version,record_period,record_volume,record_mode};
                        crc         <= 16'hffff;
                        bit_cnt     <= 0;
                        jst         <= J_RCRC;
                    end else begin
                        load_done <= 1;
                        if (use_slot0) begin
                            config_valid<=1; active_version<=slot0_version; active_period<=slot0_period;
                            active_volume<=slot0_volume; active_mode<=slot0_mode;
                        end else if (good1) begin
                            config_valid<=1; active_version<=slot1_version; active_period<=slot1_period;
                            active_volume<=slot1_volume; active_mode<=slot1_mode;
                        end else begin
                            config_valid<=0; active_version<=0; active_period<=0;
                            active_volume<=0; active_mode<=0;
                        end
                        jst <= J_IDLE;
                    end
                end
                J_RCRC: begin
                    crc     <= crc_next;
                    sh      <= {sh[78:0],1'b0};
                    bit_cnt <= bit_cnt + 1'b1;
                    if (last_bit) begin
                        record_crc   <= crc_next;
                        record_ready <= 1'b1;
                        jst          <= J_IDLE;
                    end
                end
                default: jst <= J_IDLE;
            endcase
        end
    end
endmodule
