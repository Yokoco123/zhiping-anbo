module bmp_read(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input                       load_abort,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data,
    output reg                  load_error,     // 加载失败单拍脉冲
    output reg [3:0]            bmp_error       // 最近一次错误码（保持到下次成功）
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;

// 错误码
localparam ERR_NONE      = 4'd0;
localparam ERR_HEADER    = 4'd1;   // 加载时头校验失败
localparam ERR_TIMEOUT   = 4'd2;   // 读扇区超时
localparam ERR_TRUNCATED = 4'd3;   // 像素数不足
// 单个扇区读超时：100MHz 下 50,000,000 周期 = 500ms
localparam [31:0] SECTOR_TIMEOUT_CYCLES = 32'd50_000_000;

reg [2:0]  state;
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;
reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] dib_size;
reg [15:0] planes;
reg [31:0] sec_timeout_cnt;
reg [18:0] pixel_count;

reg [31:0] scan_sector;
reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;
reg [1:0]  bmp_byte_idx;

wire header_match;
wire bmp_data_valid;
wire [31:0] file_sector_count;
wire [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;

assign ready = (state == ST_IDLE);
// 严格校验：在官方 6 项基础上增加 DIB 头、平面数、偏移和文件长度检查
wire [31:0] pixel_bytes = bmp_width * bmp_height * 3;
assign header_match = (header_0 == "B") && (header_1 == "M") &&
                      (dib_size >= 32'd40) &&
                      (width  == {16'd0, bmp_width}) &&
                      (height == {16'd0, bmp_height}) &&
                      (planes == 16'd1) &&
                      (bit_count == 16'd24) &&
                      (compression == 32'd0) &&
                      (pixel_offset >= 32'd54) &&
                      (pixel_offset < file_len) &&
                      (file_len >= pixel_offset + pixel_bytes);
// 像素输出上限卡在 pixel_offset + 640*480*3，多余字节不再写入 FIFO
assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) &&
                        (bmp_len_cnt >= pixel_offset) &&
                        (bmp_len_cnt <  pixel_offset + pixel_bytes);
assign file_sector_count = (file_len == 32'd0) ? 32'd1 : ((file_len + 32'd511) >> 9);
assign next_scan_sector_if_match = scan_sector + file_sector_count;
assign next_scan_sector_if_miss  = scan_sector + 32'd1;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
        dib_size     <= 32'd0;
        planes       <= 16'd0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd14: dib_size[7:0]   <= sd_sec_read_data;
            10'd15: dib_size[15:8]  <= sd_sec_read_data;
            10'd16: dib_size[23:16] <= sd_sec_read_data;
            10'd17: dib_size[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd26: planes[7:0]     <= sd_sec_read_data;
            10'd27: planes[15:8]    <= sd_sec_read_data;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
        bmp_len_cnt <= 32'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid)
            bmp_byte_idx <= (bmp_byte_idx == 2'd2) ? 2'd0 : (bmp_byte_idx + 2'd1);
    end else begin
        bmp_byte_idx <= 2'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid) begin
            case (bmp_byte_idx)
                2'd0: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[7:0]  <= sd_sec_read_data;
                end
                2'd1: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[15:8] <= sd_sec_read_data;
                end
                2'd2: begin
                    bmp_data_wr_en  <= 1'b1;
                    bmp_data[23:16] <= sd_sec_read_data;
                end
                default: begin
                    bmp_data_wr_en <= 1'b0;
                end
            endcase
        end else begin
            bmp_data_wr_en <= 1'b0;
        end
    end else begin
        bmp_data_wr_en <= 1'b0;
    end
end

// 像素计数：每拼好一个像素加 1
always @(posedge clk or posedge rst) begin
    if (rst)
        pixel_count <= 19'd0;
    else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid && (bmp_byte_idx == 2'd2))
            pixel_count <= pixel_count + 19'd1;
    end else
        pixel_count <= 19'd0;
end

// 单扇区读超时：处于读扇区状态时累加，每读完一个扇区清零
always @(posedge clk or posedge rst) begin
    if (rst)
        sec_timeout_cnt <= 32'd0;
    else if (((state == ST_SCAN) || (state == ST_LOAD_HDR) || (state == ST_LOAD_DATA)) && !sd_sec_read_end)
        sec_timeout_cnt <= sec_timeout_cnt + 32'd1;
    else
        sec_timeout_cnt <= 32'd0;
end
wire sec_timeout = (sec_timeout_cnt >= SECTOR_TIMEOUT_CYCLES);

// write_req_ack 来自 ext_mem_clk(125MHz) 域，先打两拍同步到 clk(100MHz) 域再使用
reg write_req_ack_d1;
reg write_req_ack_d2;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        write_req_ack_d1 <= 1'b0;
        write_req_ack_d2 <= 1'b0;
    end else begin
        write_req_ack_d1 <= write_req_ack;
        write_req_ack_d2 <= write_req_ack_d1;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        load_error        <= 1'b0;
        bmp_error         <= 4'd0;
    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        load_error        <= 1'b0;
    end else if (load_abort) begin
        // 上层 1 秒超时中止：只退出这次加载，保留扫描结果，按键才不会失效
        state       <= ST_IDLE;
        sd_sec_read <= 1'b0;
        write_req   <= 1'b0;
        load_error  <= 1'b0;
        bmp_error   <= ERR_TIMEOUT;
    end else begin
        scan_found_valid <= 1'b0;
        load_error       <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done        <= 1'b0;
                    scan_found_total <= 3'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    if (header_match) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 3'd1;

                        if ((scan_found_total + 3'd1 >= scan_target_count) || (next_scan_sector_if_match > scan_max_sector)) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                        end
                        sd_sec_read_addr <= next_scan_sector_if_match;
                        scan_sector      <= next_scan_sector_if_match;
                    end else if (scan_sector >= scan_max_sector) begin
                        scan_done <= 1'b1;
                        state     <= ST_IDLE;
                    end else if ((header_0 == "B") && (header_1 == "M") &&
                                 (file_len >= 32'd54) && (file_len < 32'd67_108_864)) begin
                        // 是 BMP 但不符合要求（尺寸/位深不对）：整文件跳过
                        sd_sec_read_addr <= next_scan_sector_if_match;
                        scan_sector      <= next_scan_sector_if_match;
                    end else begin
                        sd_sec_read_addr <= next_scan_sector_if_miss;
                        scan_sector      <= next_scan_sector_if_miss;
                    end
                end else if (sec_timeout) begin
                    // 扫描时卡死：用已经找到的图结束扫描
                    sd_sec_read <= 1'b0;
                    scan_done   <= 1'b1;
                    bmp_error   <= ERR_TIMEOUT;
                    state       <= ST_IDLE;
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        // 头校验失败：上报错误，不再静默返回
                        load_error <= 1'b1;
                        bmp_error  <= ERR_HEADER;
                        state      <= ST_IDLE;
                    end
                end else if (sec_timeout) begin
                    sd_sec_read <= 1'b0;
                    load_error  <= 1'b1;
                    bmp_error   <= ERR_TIMEOUT;
                    state       <= ST_IDLE;
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack_d2) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (bmp_len_cnt >= file_len) begin
                        state <= ST_IDLE;
                        // 像素完整性校验
                        if (pixel_count < bmp_width * bmp_height) begin
                            load_error <= 1'b1;
                            bmp_error  <= ERR_TRUNCATED;
                        end else begin
                            bmp_error  <= ERR_NONE;
                        end
                    end else begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                    end
                end else if (sec_timeout) begin
                    sd_sec_read <= 1'b0;
                    load_error  <= 1'b1;
                    bmp_error   <= ERR_TIMEOUT;
                    state       <= ST_IDLE;
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule
