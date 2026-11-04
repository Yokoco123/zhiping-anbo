`timescale 1ns/1ps

module fat32_volume_scanner (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scan_start,
    output wire        scan_busy,
    output reg         scan_done,
    output reg  [7:0]  fs_error,
    output reg  [31:0] partition_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [31:0] fat_start_lba,
    output reg  [31:0] data_start_lba,
    output reg  [31:0] max_cluster,
    output reg  [3:0]  resource_valid,
    output reg  [31:0] resource0_cluster,
    output reg  [31:0] resource1_cluster,
    output reg  [31:0] resource2_cluster,
    output reg  [31:0] resource3_cluster,
    output reg  [31:0] resource0_size,
    output reg  [31:0] resource1_size,
    output reg  [31:0] resource2_size,
    output reg  [31:0] resource3_size,
    // 根目录里的 MUSIC.WAV（背景音乐）
    output reg         music_valid,
    output reg  [31:0] music_cluster,
    output reg  [31:0] music_size,
    // 【应急模式】根目录里的 EMERG.BMP（应急页）
    output reg         emerg_valid,
    output reg  [31:0] emerg_cluster,
    output reg  [31:0] emerg_size,
    // 【拔卡恢复】卡指纹：PIC1~4 / EMERG / MUSIC 的起始簇、大小、修改时间混在一起，插回卡后比对是不是同一张卡
    output reg  [31:0] dir_signature,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);

    localparam ERR_NONE            = 8'h00;
    localparam ERR_SECTOR          = 8'h10;
    localparam ERR_BOOT_SIGNATURE  = 8'h20;
    localparam ERR_UNSUPPORTED_BPB = 8'h21;
    localparam ERR_RESOURCE_MISSING= 8'h22;

    localparam ST_IDLE       = 4'd0;
    localparam ST_READ0_REQ  = 4'd1;
    localparam ST_READ0_WAIT = 4'd2;
    localparam ST_BOOT_PARSE = 4'd3;
    localparam ST_BOOT_REQ   = 4'd4;
    localparam ST_BOOT_WAIT  = 4'd5;
    localparam ST_ROOT_REQ   = 4'd6;
    localparam ST_ROOT_WAIT  = 4'd7;
    localparam ST_DIR_SCAN   = 4'd8;
    localparam ST_FINISH     = 4'd9;
    localparam ST_BOOT_LAYOUT= 4'd10;
    localparam ST_BOOT_ROOT  = 4'd11;

    // 【省资源 第4轮】原来先把整个扇区存进 512 字节的 sector_buffer 再按偏移取字段；
    // 现在边收边取：只留下要用的字段，单字节的判断收到时就算成 1 位标志，多字节字段直接写进要用它的寄存器。
    // 目录项的文件名也不再存 11 个字节，收到一个比一个（3 个匹配标志）。结果和原来逐位相同（sim/run_scan_equiv.sh）
    reg [3:0] state;
    reg [31:0] root_cluster;         // 引导扇区 44~47 直接收进来；BOOT_LAYOUT 后变成 (根目录簇 - 2)，BOOT_ROOT 里逐位左移
    reg [31:0] fat_sectors;          // 引导扇区 36~39
    reg [31:0] data_sector_count;    // 引导扇区 32~35（总扇区）；再减保留、减 FAT，BOOT_ROOT 里逐位右移
    reg [15:0] rsv_sectors;          // 引导扇区 14~15
    reg [7:0]  spc_byte;             // 引导扇区 13
    reg        b0_jmp;               // 第 0 字节是 EB / E9（本身就是引导扇区）
    reg        b450_fat32;           // 分区表第一项类型 0B / 0C
    reg        b510_55, b511_aa;     // 结束签名
    reg        b11_00, b12_02;       // 每扇区 512 字节
    reg        b16_ok, b16_two;      // FAT 个数 1 / 2，是不是 2
    reg        b17_0, b18_0, b22_0, b23_0;
    reg [2:0] sectors_per_cluster_shift;
    reg [2:0] shift_left;            // 【省资源】还要移几位
    reg       nm_music, nm_emerg, nm_pic;   // 目录项文件名到目前为止还和 MUSIC.WAV / EMERG.BMP / PICn.BMP 对得上
    reg [1:0] nm_idx;                // PICn 的 n - 1
    reg       dir_entry_match;
    reg       dir_music_match;       // 当前目录项是 MUSIC.WAV
    reg       dir_emerg_match;       // 【应急模式】当前目录项是 EMERG.BMP
    reg [1:0] dir_resource_index;
    reg [15:0] dir_cluster_high;
    reg [15:0] dir_cluster_low;
    reg [31:0] dir_file_size;
    reg [31:0] dir_wtime;            // 【拔卡恢复】目录项第 22~25 字节：修改时间 + 日期

    assign scan_busy = (state != ST_IDLE);

    wire       sig_ok  = b510_55 && b511_aa;
    // 【时序 t5】BPB 合不合格、每簇扇区位数每拍算好打一拍（原来 BOOT_PARSE 一拍里判断完直接控制 32 位减法的写入，差 0.05ns）。
    //   进 BOOT_PARSE 时这些字段早就收完了（之后还有十几个字节和 sector_done），打一拍的值已经是这一扇区的
    reg        bpb_bad;
    reg [2:0]  spc_sh_q;
    wire [7:0] b       = sector_byte;
    wire [31:0] fat_span = b16_two ? {fat_sectors[30:0], 1'b0} : fat_sectors;

    function valid_spc;
        input [7:0] value;
        begin
            valid_spc = value != 0 && ((value & (value - 1'b1)) == 0);
        end
    endfunction

    function [2:0] spc_shift;
        input [7:0] value;
        begin
            case (value)
                8'd2:   spc_shift = 3'd1;
                8'd4:   spc_shift = 3'd2;
                8'd8:   spc_shift = 3'd3;
                8'd16:  spc_shift = 3'd4;
                8'd32:  spc_shift = 3'd5;
                8'd64:  spc_shift = 3'd6;
                8'd128: spc_shift = 3'd7;
                default: spc_shift = 3'd0;
            endcase
        end
    endfunction

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            scan_done <= 1'b0;
            fs_error <= ERR_NONE;
            partition_lba <= 32'd0;
            sectors_per_cluster <= 8'd0;
            fat_start_lba <= 32'd0;
            data_start_lba <= 32'd0;
            max_cluster <= 32'd0;
            resource_valid <= 4'd0;
            resource0_cluster <= 32'd0;
            resource1_cluster <= 32'd0;
            resource2_cluster <= 32'd0;
            resource3_cluster <= 32'd0;
            resource0_size <= 32'd0;
            resource1_size <= 32'd0;
            resource2_size <= 32'd0;
            resource3_size <= 32'd0;
            music_valid <= 1'b0;
            music_cluster <= 32'd0;
            music_size <= 32'd0;
            emerg_valid <= 1'b0;
            emerg_cluster <= 32'd0;
            emerg_size <= 32'd0;
            dir_emerg_match <= 1'b0;
            dir_music_match <= 1'b0;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            root_cluster <= 32'd0;
            fat_sectors <= 32'd0;
            data_sector_count <= 32'd0;
            rsv_sectors <= 16'd0;
            spc_byte <= 8'd0;
            {b0_jmp, b450_fat32, b510_55, b511_aa, b11_00, b12_02, b16_ok, b16_two} <= 8'd0;
            {b17_0, b18_0, b22_0, b23_0} <= 4'd0;
            sectors_per_cluster_shift <= 3'd0;
            shift_left <= 3'd0;
            {nm_music, nm_emerg, nm_pic} <= 3'd0;
            nm_idx <= 2'd0;
            dir_entry_match <= 1'b0;
            dir_resource_index <= 2'd3;
            dir_cluster_high <= 16'd0;
            dir_cluster_low <= 16'd0;
            dir_file_size <= 32'd0;
            bpb_bad <= 1'b1;
            spc_sh_q <= 3'd0;
        end else begin
            scan_done <= 1'b0;
            sector_req <= 1'b0;
            bpb_bad  <= !(b11_00 && b12_02) || !valid_spc(spc_byte) ||
                        rsv_sectors == 16'd0 || !b16_ok ||
                        !(b17_0 && b18_0) || !(b22_0 && b23_0) || data_sector_count == 32'd0 ||
                        fat_sectors == 32'd0 || root_cluster[31:1] == 31'd0;
            spc_sh_q <= spc_shift(spc_byte);

            // ---------------- 分区表 / 引导扇区：边收边取字段 ----------------
            if (sector_valid && state != ST_ROOT_WAIT) begin
                case (sector_byte_index)
                    9'd0:   b0_jmp     <= (b == 8'heb) || (b == 8'he9);
                    9'd11:  b11_00     <= (b == 8'h00);
                    9'd12:  b12_02     <= (b == 8'h02);
                    9'd13:  spc_byte   <= b;
                    9'd14:  rsv_sectors[7:0]  <= b;
                    9'd15:  rsv_sectors[15:8] <= b;
                    9'd16:  begin b16_ok <= (b == 8'd1) || (b == 8'd2); b16_two <= (b == 8'd2); end
                    9'd17:  b17_0      <= (b == 8'h00);
                    9'd18:  b18_0      <= (b == 8'h00);
                    9'd22:  b22_0      <= (b == 8'h00);
                    9'd23:  b23_0      <= (b == 8'h00);
                    9'd32:  data_sector_count[7:0]   <= b;
                    9'd33:  data_sector_count[15:8]  <= b;
                    9'd34:  data_sector_count[23:16] <= b;
                    9'd35:  data_sector_count[31:24] <= b;
                    9'd36:  fat_sectors[7:0]   <= b;
                    9'd37:  fat_sectors[15:8]  <= b;
                    9'd38:  fat_sectors[23:16] <= b;
                    9'd39:  fat_sectors[31:24] <= b;
                    9'd44:  root_cluster[7:0]   <= b;
                    9'd45:  root_cluster[15:8]  <= b;
                    9'd46:  root_cluster[23:16] <= b;
                    9'd47:  root_cluster[31:24] <= b;
                    9'd450: b450_fat32 <= (b == 8'h0b) || (b == 8'h0c);
                    9'd510: b510_55    <= (b == 8'h55);
                    9'd511: b511_aa    <= (b == 8'haa);
                    default: ;
                endcase
                // 分区起点只在读第 0 扇区时收（读引导扇区时 454~457 是别的内容）
                if (state == ST_READ0_WAIT)
                    case (sector_byte_index)
                        9'd454: partition_lba[7:0]   <= b;
                        9'd455: partition_lba[15:8]  <= b;
                        9'd456: partition_lba[23:16] <= b;
                        9'd457: partition_lba[31:24] <= b;
                        default: ;
                    endcase
            end

            // ---------------- 根目录：每 32 字节一个目录项 ----------------
            if (sector_valid && state == ST_ROOT_WAIT) begin
                case (sector_byte_index[4:0])
                    5'd0: begin
                        nm_music <= (b == "M");
                        nm_emerg <= (b == "E");
                        nm_pic   <= (b == "P");
                        dir_entry_match <= 1'b0;
                        dir_emerg_match <= 1'b0;
                        dir_music_match <= 1'b0;
                    end
                    5'd1:  begin nm_music <= nm_music && (b == "U"); nm_emerg <= nm_emerg && (b == "M"); nm_pic <= nm_pic && (b == "I"); end
                    5'd2:  begin nm_music <= nm_music && (b == "S"); nm_emerg <= nm_emerg && (b == "E"); nm_pic <= nm_pic && (b == "C"); end
                    5'd3:  begin nm_music <= nm_music && (b == "I"); nm_emerg <= nm_emerg && (b == "R");
                                 nm_pic <= nm_pic && (b >= "1") && (b <= "4"); nm_idx <= b[1:0] - 2'd1; end
                    5'd4:  begin nm_music <= nm_music && (b == "C"); nm_emerg <= nm_emerg && (b == "G"); nm_pic <= nm_pic && (b == " "); end
                    5'd5, 5'd6, 5'd7:
                           begin nm_music <= nm_music && (b == " "); nm_emerg <= nm_emerg && (b == " "); nm_pic <= nm_pic && (b == " "); end
                    5'd8:  begin nm_music <= nm_music && (b == "W"); nm_emerg <= nm_emerg && (b == "B"); nm_pic <= nm_pic && (b == "B"); end
                    5'd9:  begin nm_music <= nm_music && (b == "A"); nm_emerg <= nm_emerg && (b == "M"); nm_pic <= nm_pic && (b == "M"); end
                    5'd10: begin nm_music <= nm_music && (b == "V"); nm_emerg <= nm_emerg && (b == "P"); nm_pic <= nm_pic && (b == "P"); end
                    5'd11: begin
                        if (b == 8'h20 && nm_music)
                            dir_music_match <= 1'b1;
                        if (b == 8'h20 && nm_emerg)
                            dir_emerg_match <= 1'b1;
                        if (b == 8'h20 && nm_pic) begin
                            dir_entry_match <= 1'b1;
                            dir_resource_index <= nm_idx;
                        end
                    end
                    5'd22: dir_wtime[7:0]   <= b;
                    5'd23: dir_wtime[15:8]  <= b;
                    5'd24: dir_wtime[23:16] <= b;
                    5'd25: dir_wtime[31:24] <= b;
                    5'd20: dir_cluster_high[7:0] <= b;
                    5'd21: dir_cluster_high[15:8] <= b;
                    5'd26: dir_cluster_low[7:0] <= b;
                    5'd27: dir_cluster_low[15:8] <= b;
                    5'd28: dir_file_size[7:0] <= b;
                    5'd29: dir_file_size[15:8] <= b;
                    5'd30: dir_file_size[23:16] <= b;
                    5'd31: begin
                        dir_file_size[31:24] <= b;
                        if (dir_music_match || dir_emerg_match || dir_entry_match)
                            dir_signature <= {dir_signature[26:0], dir_signature[31:27]}
                                           ^ {dir_cluster_high, dir_cluster_low} ^ {b, dir_file_size[23:0]} ^ dir_wtime
                                           ^ {29'd0, dir_music_match, dir_emerg_match, 1'b0} ^ {30'd0, dir_resource_index};
                        if (dir_music_match) begin
                            music_cluster <= {dir_cluster_high, dir_cluster_low};
                            music_size <= {b, dir_file_size[23:0]};
                            music_valid <= 1'b1;
                        end
                        if (dir_emerg_match) begin
                            emerg_cluster <= {dir_cluster_high, dir_cluster_low};
                            emerg_size <= {b, dir_file_size[23:0]};
                            emerg_valid <= 1'b1;
                        end
                        if (dir_entry_match) begin
                            case (dir_resource_index)
                                2'd0: begin
                                    resource0_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource0_size <= {b, dir_file_size[23:0]};
                                    resource_valid[0] <= 1'b1;
                                end
                                2'd1: begin
                                    resource1_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource1_size <= {b, dir_file_size[23:0]};
                                    resource_valid[1] <= 1'b1;
                                end
                                2'd2: begin
                                    resource2_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource2_size <= {b, dir_file_size[23:0]};
                                    resource_valid[2] <= 1'b1;
                                end
                                default: begin
                                    resource3_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource3_size <= {b, dir_file_size[23:0]};
                                    resource_valid[3] <= 1'b1;
                                end
                            endcase
                        end
                    end
                    default: begin end
                endcase
            end

            case (state)
                ST_IDLE: if (scan_start) begin
                    fs_error <= ERR_NONE;
                    partition_lba <= 32'd0;
                    resource_valid <= 4'd0;
                    emerg_valid <= 1'b0;
                    music_valid <= 1'b0;
                    state <= ST_READ0_REQ;
                end
                ST_READ0_REQ: if (!sector_busy) begin
                    sector_lba <= 32'd0;
                    sector_req <= 1'b1;
                    state <= ST_READ0_WAIT;
                end
                ST_READ0_WAIT: if (sector_done) begin
                    // 分区起点收的时候就写进了 partition_lba；不是“分区表 → FAT32 分区”这条路时清回 0（和原来一样）
                    if (sector_error != 0 || !sig_ok || b0_jmp || !b450_fat32)
                        partition_lba <= 32'd0;
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (!sig_ok)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else if (b0_jmp)
                        state <= ST_BOOT_PARSE;
                    else if (b450_fat32) begin
                        sector_lba <= partition_lba;
                        state <= ST_BOOT_REQ;
                    end else begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end
                end
                ST_BOOT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_BOOT_WAIT;
                end
                ST_BOOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (!sig_ok)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else
                        state <= ST_BOOT_PARSE;
                end
                ST_BOOT_PARSE: begin
                    if (bpb_bad) begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end else begin
                        sectors_per_cluster <= spc_byte;
                        data_sector_count <= data_sector_count - rsv_sectors;   // 总扇区 - 保留扇区
                        sectors_per_cluster_shift <= spc_sh_q;
                        fat_start_lba <= partition_lba + rsv_sectors;
                        state <= ST_BOOT_LAYOUT;
                    end
                end
                // 【省资源】原来是一拍算完：三输入加减 + 两个 32 位桶形移位器。开机只算一次，改成两输入加减、
                // 每拍移一位（最多 7 拍），结果和原来逐位相同：
                //   data_start  = 分区起点 + 保留 + FAT 区        （fat_start_lba 已经是 分区起点 + 保留）
                //   max_cluster = ((总扇区 - 保留 - FAT 区) >> 每簇扇区位数) + 1
                //   根目录扇区  = data_start + ((根目录簇 - 2) << 每簇扇区位数)
                ST_BOOT_LAYOUT: begin
                    data_start_lba <= fat_start_lba + fat_span;
                    data_sector_count <= data_sector_count - fat_span;
                    root_cluster <= root_cluster - 32'd2;
                    shift_left <= sectors_per_cluster_shift;
                    state <= ST_BOOT_ROOT;
                end
                ST_BOOT_ROOT: begin
                    if (shift_left != 3'd0) begin
                        data_sector_count <= data_sector_count >> 1;
                        root_cluster <= root_cluster << 1;
                        shift_left <= shift_left - 3'd1;
                    end else begin
                        max_cluster <= data_sector_count + 1'b1;
                        sector_lba <= data_start_lba + root_cluster;
                        state <= ST_ROOT_REQ;
                    end
                end
                ST_ROOT_REQ: if (!sector_busy) begin
                    resource_valid <= 4'd0;
                    dir_signature <= 32'h5A5A_0001;
                    dir_entry_match <= 1'b0;
                    music_valid <= 1'b0;
                    emerg_valid <= 1'b0;
                    dir_emerg_match <= 1'b0;
                    dir_music_match <= 1'b0;
                    sector_req <= 1'b1;
                    state <= ST_ROOT_WAIT;
                end
                ST_ROOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else
                        state <= ST_DIR_SCAN;
                end
                ST_DIR_SCAN: begin
                    if (resource_valid == 4'hf)
                        state <= ST_FINISH;
                    else
                        finish_with_error(ERR_RESOURCE_MISSING);
                end
                ST_FINISH: begin
                    scan_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
