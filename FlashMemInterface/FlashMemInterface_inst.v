	FlashMemInterface u0 (
		.clk_clk                 (<connected-to-clk_clk>),                 //       clk.clk
		.flash_csr_address       (<connected-to-flash_csr_address>),       // flash_csr.address
		.flash_csr_read          (<connected-to-flash_csr_read>),          //          .read
		.flash_csr_readdata      (<connected-to-flash_csr_readdata>),      //          .readdata
		.flash_csr_write         (<connected-to-flash_csr_write>),         //          .write
		.flash_csr_writedata     (<connected-to-flash_csr_writedata>),     //          .writedata
		.flash_csr_waitrequest   (<connected-to-flash_csr_waitrequest>),   //          .waitrequest
		.flash_csr_readdatavalid (<connected-to-flash_csr_readdatavalid>), //          .readdatavalid
		.flash_mem_write         (<connected-to-flash_mem_write>),         // flash_mem.write
		.flash_mem_burstcount    (<connected-to-flash_mem_burstcount>),    //          .burstcount
		.flash_mem_waitrequest   (<connected-to-flash_mem_waitrequest>),   //          .waitrequest
		.flash_mem_read          (<connected-to-flash_mem_read>),          //          .read
		.flash_mem_address       (<connected-to-flash_mem_address>),       //          .address
		.flash_mem_writedata     (<connected-to-flash_mem_writedata>),     //          .writedata
		.flash_mem_readdata      (<connected-to-flash_mem_readdata>),      //          .readdata
		.flash_mem_readdatavalid (<connected-to-flash_mem_readdatavalid>), //          .readdatavalid
		.flash_mem_byteenable    (<connected-to-flash_mem_byteenable>),    //          .byteenable
		.reset_reset_n           (<connected-to-reset_reset_n>)            //     reset.reset_n
	);

