`timescale 1ns/1ps
module frame_fifo_read
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter FIFO_DEPTH             = 512,
	parameter BURST_SIZE             = 128
)               
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
    input							 Sdr_rd_en,
	input							 App_wr_busy,
    output							 O_rd_busy,
	/*
    output reg                       rd_burst_req,               // to external memory controller,send out a burst read request  
	output reg[BURST_BITS - 1:0]     rd_burst_len,               // to external memory controller,data length of the burst read request, not bytes 
	output reg[ADDR_BITS - 1:0]      rd_burst_addr,              // to external memory controller,base address of the burst read request
	input                            rd_burst_data_valid,        // from external memory controller,read request data valid    
	input                            rd_burst_finish,            // from external memory controller,burst read finish
	*/
	output 							 App_rd_en,
	output  [ADDR_BITS - 1:0]		 App_rd_addr,
	
	input                            read_req,                   // data read module read request,keep '1' until read_req_ack = '1'
	output reg                       read_req_ack,               // data read module read request response
	output                           read_finish,                // data read module read request finish
	input[ADDR_BITS - 1:0]           read_addr_0,                // data read module read request base address 0, used when read_addr_index = 0
	input[ADDR_BITS - 1:0]           read_addr_1,                // data read module read request base address 1, used when read_addr_index = 1
	input[ADDR_BITS - 1:0]           read_addr_2,                // data read module read request base address 1, used when read_addr_index = 2
	input[ADDR_BITS - 1:0]           read_addr_3,                // data read module read request base address 1, used when read_addr_index = 3
	input[1:0]                       read_addr_index,            // select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
	input[ADDR_BITS - 1:0]           read_len,                   // data read module read request data length
	output reg                       fifo_aclr,                  // to fifo asynchronous clear
	input[9:0]                      wrusedw,                    // from fifo write used words
	// 缩略图模式：2×2 网格，每格是对应 bank 的图缩小一半
	input                            thumb_mode,                 // 异步输入，和 read_addr_index 一样在帧头锁存
	output reg                       thumb_active                // 本帧是缩略图帧（给 FIFO 写入隔点丢弃用）
);
// 缩略图读法：屏幕第 L 行 = 左半 bank{h,0} 的第 2l 行 + 右半 bank{h,1} 的第 2l 行
// （h = L>=240，l = L%240）。每段 640 字分 5 次 128 字突发，FIFO 只收偶数字，640 → 320 像素。
// 一帧读 2 倍数据（614400 字），SDRAM 带宽足够。
localparam THUMB_BURST               = 128;
localparam FRAME_W                   = 640;
localparam ONE                       = 256'd1;                   //256 bit '1'   you can use ONE[n-1:0] for n bit '1'
localparam ZERO                      = 256'd0;                   //256 bit '0'
//read state machine code
localparam S_IDLE                    = 0;                        //idle state,waiting for frame read
localparam S_ACK                     = 1;                        //read request response
localparam S_CHECK_FIFO              = 2;                        //check the FIFO status, ensure that there is enough space to burst read
localparam S_READ_BURST              = 3;                        //begin a burst read
localparam S_READ_BURST_END          = 4;                        //a burst read complete
localparam S_END                     = 5;                        //a frame of data is read to complete

reg                                  read_req_d0;                //asynchronous read request, synchronize to 'mem_clk' clock domain,first beat
reg                                  read_req_d1;                //second
reg                                  read_req_d2;                //third,Why do you need 3 ? Here's the design habit
reg[ADDR_BITS - 1:0]                 read_len_d0;                //asynchronous read_len(read data length), synchronize to 'mem_clk' clock domain first
reg[ADDR_BITS - 1:0]                 read_len_d1;                //second
reg[ADDR_BITS - 1:0]                 read_len_latch;             //lock read data length
reg[ADDR_BITS - 1:0]                 read_cnt;                   //read data counter
reg[3:0]                             state;                      //state machine
reg[1:0]                             read_addr_index_d0;         //synchronize to 'mem_clk' clock domain first
reg[1:0]                             read_addr_index_d1;         //synchronize to 'mem_clk' clock domain second
reg [ADDR_BITS - 1:0]	 App_rd_addr_r;

reg [BURST_BITS - 1:0]				burst_cnt;
wire								rd_burst_finish;
reg App_rd_en_r;
reg App_rd_en_d0;


wire rd_vld;
reg [3:0] rd_delay;

// 缩略图模式的突发长度和地址
reg                                  thumb_d0, thumb_d1;
wire [BURST_BITS:0]                  burst_len = thumb_active ? THUMB_BURST : BURST_SIZE;
reg  [2:0]                           t_chunk;        // 一段里的第几次突发 0~4
reg                                  t_seg;          // 0 = 左半屏，1 = 右半屏
reg                                  t_half;         // 0 = 上半屏，1 = 下半屏
reg  [7:0]                           t_line;         // 半屏内的行 0~239
reg  [ADDR_BITS - 1:0]               t_row_off;      // 源图行偏移 = 2*t_line*640
reg  [ADDR_BITS - 1:0]               thumb_addr;     // 下一次突发的起始地址（寄存，时序友好）

assign App_rd_addr = {App_rd_addr_r[ADDR_BITS - 1:0]};
// 【时序】和常数比，按 thumb_active 选结果（原来先选突发长度再做 10 位比较，ext_mem_clk 差 0.13ns），结果完全相同
assign rd_vld = (state == S_READ_BURST) && (thumb_active ? (burst_cnt >= THUMB_BURST) : (burst_cnt >= BURST_SIZE));

assign O_rd_busy = (state == S_READ_BURST);//读指令期间
//burst_cnt代表发送的读指令
//但rd_burst_finish需要在发送完十个时钟后拉高，此时数据全部读出
assign rd_burst_finish = (rd_vld && rd_delay == 4'd10);
assign read_finish = (state == S_END) ? 1'b1 : 1'b0;             //read finish at state 'S_END'
assign App_rd_en = App_rd_en_d0;
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		read_req_d0    <=  1'b0;
		read_req_d1    <=  1'b0;
		read_req_d2    <=  1'b0;
		read_len_d0    <=  ZERO[ADDR_BITS - 1:0];               //equivalent to read_len_d0 <= 0;
		read_len_d1    <=  ZERO[ADDR_BITS - 1:0];               //equivalent to read_len_d1 <= 0;
		read_addr_index_d0 <= 2'b00;
		read_addr_index_d1 <= 2'b00;
		thumb_d0       <=  1'b0;
		thumb_d1       <=  1'b0;
	end
	else
	begin
		read_req_d0    <=  read_req;
		read_req_d1    <=  read_req_d0;
		read_req_d2    <=  read_req_d1;
		read_len_d0    <=  read_len;
		read_len_d1    <=  read_len_d0;
		read_addr_index_d0 <= read_addr_index;
		read_addr_index_d1 <= read_addr_index_d0;
		thumb_d0       <=  thumb_mode;
		thumb_d1       <=  thumb_d0;

	end
end

// 缩略图地址发生器：每次突发结束推进一格，下一次突发前地址已经算好
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		t_chunk    <= 3'd0;
		t_seg      <= 1'b0;
		t_half     <= 1'b0;
		t_line     <= 8'd0;
		t_row_off  <= ZERO[ADDR_BITS - 1:0];
		thumb_addr <= ZERO[ADDR_BITS - 1:0];
	end
	else
	begin
		if(state == S_ACK)
		begin
			t_chunk   <= 3'd0;
			t_seg     <= 1'b0;
			t_half    <= 1'b0;
			t_line    <= 8'd0;
			t_row_off <= ZERO[ADDR_BITS - 1:0];
		end
		else if(rd_burst_finish && thumb_active)
		begin
			if(t_chunk != 3'd4)
				t_chunk <= t_chunk + 3'd1;
			else
			begin
				t_chunk <= 3'd0;
				t_seg   <= ~t_seg;
				if(t_seg)
				begin
					// 左右两段都读完：下一屏幕行，源图跳两行
					if(t_line == 8'd239)
					begin
						t_line    <= 8'd0;
						t_half    <= 1'b1;
						t_row_off <= ZERO[ADDR_BITS - 1:0];
					end
					else
					begin
						t_line    <= t_line + 8'd1;
						t_row_off <= t_row_off + FRAME_W * 2;
					end
				end
			end
		end

		case({t_half, t_seg})
			2'd0:    thumb_addr <= read_addr_0 + t_row_off + {t_chunk, 7'd0};
			2'd1:    thumb_addr <= read_addr_1 + t_row_off + {t_chunk, 7'd0};
			2'd2:    thumb_addr <= read_addr_2 + t_row_off + {t_chunk, 7'd0};
			default: thumb_addr <= read_addr_3 + t_row_off + {t_chunk, 7'd0};
		endcase
	end
end

always @(posedge mem_clk or posedge rst)
begin
	if(rst || App_rd_en)begin
        rd_delay <= 4'd0;
    end
    else if(rd_delay < 4'd10)begin
    	rd_delay <= rd_delay + 1'b1;
    end
end
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		burst_cnt <= ZERO[BURST_BITS - 1:0];
		App_rd_addr_r <= ZERO[ADDR_BITS - 1:0];
		App_rd_en_d0 <= 1'b0;
	end
	else begin
	
		if(state == S_CHECK_FIFO)
			burst_cnt <= ZERO[BURST_BITS - 1:0];
		else if(App_rd_en)
			burst_cnt <= burst_cnt + 1'b1;
		else
			burst_cnt <= burst_cnt;
		//
		if(state == S_ACK)
			begin
				if(read_addr_index_d1 == 2'd0)
					App_rd_addr_r <= read_addr_0;
				else if(read_addr_index_d1 == 2'd1)
					App_rd_addr_r <= read_addr_1;
				else if(read_addr_index_d1 == 2'd2)
					App_rd_addr_r <= read_addr_2;
				else if(read_addr_index_d1 == 2'd3)
					App_rd_addr_r <= read_addr_3;
			end
		else if(App_rd_en)
			App_rd_addr_r <= App_rd_addr_r + 1'b1;
		else if(thumb_active && state == S_CHECK_FIFO)
			App_rd_addr_r <= thumb_addr;            // 缩略图：每次突发重新定位
		else
			App_rd_addr_r <= App_rd_addr_r;
		//
		if(App_rd_en_r && (thumb_active ? ({1'b0, burst_cnt} + App_rd_en < THUMB_BURST) : ({1'b0, burst_cnt} + App_rd_en < BURST_SIZE)))
			App_rd_en_d0 <= 1'b1;
		else
			App_rd_en_d0 <= 1'b0;
	
	end		
end
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		read_len_latch <= ZERO[ADDR_BITS - 1:0];
		
		//rd_burst_addr <= ZERO[ADDR_BITS - 1:0];
		//rd_burst_req <= 1'b0;
		App_rd_en_r <= 1'b0;
		
		read_cnt <= ZERO[ADDR_BITS - 1:0];
		fifo_aclr <= 1'b0;
		//rd_burst_len <= ZERO[BURST_BITS - 1:0];
		read_req_ack <= 1'b0;
		thumb_active <= 1'b0;
	end
	else
		case(state)
			//idle state,waiting for read, read_req_d2 == '1' goto the 'S_ACK'
			S_IDLE:
			begin
				if(read_req_d2 == 1'b1 && Sdr_init_done)
				begin
					state <= S_ACK;
				end
				read_req_ack <= 1'b0;
			end
			//'S_ACK' state completes the read request response, the FIFO reset, the address latch, and the data length latch
			S_ACK:
			begin
				if(read_req_d2 == 1'b0)
				begin
					state <= S_CHECK_FIFO;
					fifo_aclr <= 1'b0;
					read_req_ack <= 1'b0;
				end
				else
				begin
					//read request response
					read_req_ack <= 1'b1;
					//FIFO reset
					fifo_aclr <= 1'b1;
					//select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
					/*
					if(read_addr_index_d1 == 2'd0)
						App_rd_addr <= read_addr_0;
					else if(read_addr_index_d1 == 2'd1)
						App_rd_addr <= read_addr_1;
					else if(read_addr_index_d1 == 2'd2)
						App_rd_addr <= read_addr_2;
					else if(read_addr_index_d1 == 2'd3)
						App_rd_addr <= read_addr_3;
					*/
					//latch data length
					// 缩略图帧在这里锁存，一帧内不变；缩略图一帧要读 2 倍数据
					thumb_active   <= thumb_d1;
					read_len_latch <= thumb_d1 ? {read_len_d1[ADDR_BITS - 2:0], 1'b0} : read_len_d1;
				end
				//read data counter reset, read_cnt <= 0;
				read_cnt <= ZERO[ADDR_BITS - 1:0];
			end
			S_CHECK_FIFO:
			begin
				//if there is a read request at this time, enter the 'S_ACK' state
				if(read_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the FIFO space is a burst read request, goto burst read state
				// SDRAM 正在刷新（Sdr_busy=1）时不发起新的突发读，
				// 否则读到的是刷新期间悬空的数据线（全 1），屏幕上表现为一段白线
				else if(wrusedw < (FIFO_DEPTH - BURST_SIZE) && ~App_wr_busy && ~Sdr_busy)
				begin
					state <= S_READ_BURST;
					//rd_burst_len <= BURST_SIZE[BURST_BITS - 1:0];
					//rd_burst_req <= 1'b1;
					App_rd_en_r <= 1'b1;
				end
			end
			
			S_READ_BURST:
			begin
				//burst finish  
				if(rd_burst_finish == 1'b1)
				begin
					App_rd_en_r <= 1'b0;
					state <= S_READ_BURST_END;
					//read counter + burst length
					read_cnt <= read_cnt + burst_len;
					//the next burst read address is generated
					//rd_burst_addr <= rd_burst_addr + BURST_SIZE[ADDR_BITS - 1:0];
				end     
			end
			S_READ_BURST_END:
			begin
				//if there is a read request at this time, enter the 'S_ACK' state
				if(read_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the read counter value is less than the frame length, continue read,
				//otherwise the read is complete
				else if(read_cnt < read_len_latch)
				begin
					state <= S_CHECK_FIFO;
				end
				else
				begin
					state <= S_END;
				end
			end
			S_END:
			begin
				state <= S_IDLE;
			end
			default:
				state <= S_IDLE;
		endcase
end
endmodule
