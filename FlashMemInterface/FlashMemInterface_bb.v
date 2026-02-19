
module FlashMemInterface (
	clk_clk,
	flash_csr_address,
	flash_csr_read,
	flash_csr_readdata,
	flash_csr_write,
	flash_csr_writedata,
	flash_csr_waitrequest,
	flash_csr_readdatavalid,
	flash_mem_write,
	flash_mem_burstcount,
	flash_mem_waitrequest,
	flash_mem_read,
	flash_mem_address,
	flash_mem_writedata,
	flash_mem_readdata,
	flash_mem_readdatavalid,
	flash_mem_byteenable,
	reset_reset_n);	

	input		clk_clk;
	input	[5:0]	flash_csr_address;
	input		flash_csr_read;
	output	[31:0]	flash_csr_readdata;
	input		flash_csr_write;
	input	[31:0]	flash_csr_writedata;
	output		flash_csr_waitrequest;
	output		flash_csr_readdatavalid;
	input		flash_mem_write;
	input	[6:0]	flash_mem_burstcount;
	output		flash_mem_waitrequest;
	input		flash_mem_read;
	input	[22:0]	flash_mem_address;
	input	[31:0]	flash_mem_writedata;
	output	[31:0]	flash_mem_readdata;
	output		flash_mem_readdatavalid;
	input	[3:0]	flash_mem_byteenable;
	input		reset_reset_n;
endmodule
