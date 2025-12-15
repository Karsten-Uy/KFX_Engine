// Created by Navraj Kambo
// nkambo1@my.bcit.ca
// 2019-07-14
// Altera DE1-SoC, System Verilog
// Basic audio hardware loopback in verilog using Altera University IP catalog
// So that you can you can add your own DSP hardware in-between ADC and DAC
// 16-Bit audio
 
// I/O assignments
module AudioFX(
	// Inputs
	SW, 
	KEY,  
	CLOCK_50,
	AUD_ADCDAT,

	// Bidirectionals
	AUD_BCLK,
	AUD_ADCLRCK,
	AUD_DACLRCK,
	FPGA_I2C_SDAT,

	// Outputs
	AUD_XCK,
	AUD_DACDAT,
	LEDR,
	FPGA_I2C_SCLK,
	GPIO_0,
	HEX0, 
	HEX1, 
	HEX2, 
	HEX3, 
	HEX4, 
	HEX5
	);

	// ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;

    // ---------------- Signals ----------------
	input [9:0] SW;
	input CLOCK_50;
	input [3:0]	KEY;
	input AUD_ADCDAT;

	inout AUD_BCLK;
	inout AUD_ADCLRCK;
	inout AUD_DACLRCK;
	inout FPGA_I2C_SDAT;

	output logic AUD_XCK;
	output logic AUD_DACDAT;
	output logic FPGA_I2C_SCLK;
	output logic [9:0] LEDR;
	output logic [DATA_W-1:0] GPIO_0;
	output logic [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
	
	// registers
	reg [22:0] count;
	
	// logic & wires
	logic reset_out;
	logic [1:0][DATA_W-1:0] DAC_Data, ADC_Data;
	logic [1:0] DAC_Ready, ADC_Ready, DAC_Valid, ADC_Valid;
	
	// These signals are for the Avalon Bus (not used in streaming interface)
	//  (Therefore, I just made random signals for to satify I/O)
	logic [31:0] i2c_data = 32'd0, i2c_read_data = 32'd0;
	logic [3:0] i2c_byte_enable = 4'b1111;
	logic i2c_read=0, i2c_write = 0, i2c_waitrequest;

	// Controller
	logic [PARAM_W-1:0]             params [0:FX_COUNT-1][0:PARAM_COUNT-1];
	logic [$clog2(FX_COUNT)-1:0]    fx_sel;
	logic [$clog2(PARAM_COUNT)-1:0] param_sel;
	logic [PARAM_W-1:0]             current_value;
	logic [9:0]                     cont_LEDR;

    // ---------------- AUDIO I/O INSTANTIATIONS ----------------
	
	// Audio PLL
	AudioPLL u0 (
		.ref_clk_clk        (CLOCK_50),        //      ref_clk.clk
		.ref_reset_reset    (~KEY[0]),    //    ref_reset.reset
		.audio_clk_clk      (AUD_XCK),      //    audio_clk.clk
		.reset_source_reset (reset_out)  // reset_source.reset
	);
	// Audio Config (16bit audio, you can change this with QSYS)
	AVConfig u1 (
		.clk         (CLOCK_50),         //                    clk.clk
		.reset       (~KEY[0]),       //                  reset.reset
		.address     (i2c_read_data),     // avalon_av_config_slave.address
		.byteenable  (i2c_byte_enable),  //                       .byteenable
		.read        (i2c_read),        //                       .read
		.write       (i2c_write),       //                       .write
		.writedata   (i2c_data),   //                       .writedata
		.readdata    (i2c_data),    //                       .readdata
		.waitrequest (i2c_waitrequest), //                       .waitrequest
		.I2C_SDAT    (FPGA_I2C_SDAT),    //     external_interface.SDAT
		.I2C_SCLK    (FPGA_I2C_SCLK)     //                       .SCLK
	);
	// Audio Codec
	AudioCodec u2 (
		.clk                          (CLOCK_50),                          //                         clk.clk
		.reset                        (~KEY[0]),                        //                       reset.reset
		.AUD_ADCDAT                   (AUD_ADCDAT),                   //          external_interface.ADCDAT
		.AUD_ADCLRCK                  (AUD_ADCLRCK),                  //                            .ADCLRCK
		.AUD_BCLK                     (AUD_BCLK),                     //                            .BCLK
		.AUD_DACDAT                   (AUD_DACDAT),                   //                            .DACDAT
		.AUD_DACLRCK                  (AUD_DACLRCK),                  //                            .DACLRCK
		.from_adc_left_channel_ready  (ADC_Ready[0]),  //  avalon_left_channel_source.ready
		.from_adc_left_channel_data   (ADC_Data[0]),   //                            .data
		.from_adc_left_channel_valid  (ADC_Valid[0]),  //                            .valid
		.from_adc_right_channel_ready (ADC_Ready[1]), // avalon_right_channel_source.ready
		.from_adc_right_channel_data  (ADC_Data[1]),  //                            .data
		.from_adc_right_channel_valid (ADC_Valid[1]), //                            .valid
		.to_dac_left_channel_data     (DAC_Data[0]),     //    avalon_left_channel_sink.data
		.to_dac_left_channel_valid    (DAC_Valid[0]),    //                            .valid
		.to_dac_left_channel_ready    (DAC_Ready[0]),    //                            .ready
		.to_dac_right_channel_data    (DAC_Data[1]),    //   avalon_right_channel_sink.data
		.to_dac_right_channel_valid   (DAC_Valid[1]),   //                            .valid
		.to_dac_right_channel_ready   (DAC_Ready[1])    //                            .ready
	);
		
	// Basic tie-back for audio ADC -> DAC
	always@(posedge(CLOCK_50)) begin
		// Mute Condition using switch 9
		if(SW[0]==1) begin
			DAC_Data[0] <= 0;
			DAC_Data[1] <= 0;
			DAC_Valid[0] <= ADC_Valid[1];
			DAC_Valid[1] <= ADC_Valid[0];
			ADC_Ready[0] <= DAC_Ready[1];
			ADC_Ready[1] <= DAC_Ready[0];
		end else begin
			// Normal operation
			DAC_Data[0] <= ADC_Data[0];
			DAC_Data[1] <= ADC_Data[1];
			DAC_Valid[0] <= ADC_Valid[0];
			DAC_Valid[1] <= ADC_Valid[1];
			ADC_Ready[0] <= DAC_Ready[0];
			ADC_Ready[1] <= DAC_Ready[1];
		end
	end

	// Useful for signal tap or scope debugging and
	assign GPIO_0[DATA_W-1:0] = DAC_Data[0];
	
    // ---------------- CONTROLLER + DISPLAY ----------------

	controller #(
        .FX_COUNT(FX_COUNT),
        .PARAM_COUNT(PARAM_COUNT),
        .PARAM_W(PARAM_W),
        .DEBOUNCE_CNT_MAX(DEBOUNCE_CNT_MAX),
		.REPEAT_START_CNT(REPEAT_START_CNT),
		.REPEAT_RATE_CNT(REPEAT_RATE_CNT)
    ) CONTROL (
        .clk(CLOCK_50),
        .reset_n(KEY[0]),
        .sw_fx_sel(SW[9:6]),    // NOTE: Need to change if expand param count + FX_COUNT
        .sw_param_sel(SW[3:1]), // NOTE: Need to change if expand param count + PARAM_COUNT
        .key_inc(~KEY[2]),
        .key_dec(~KEY[3]),
        .params(params),
        .fx_sel(fx_sel),
        .param_sel(param_sel),
        .current_value(current_value)
    );

	display #(
		.FX_COUNT(FX_COUNT),
        .PARAM_COUNT(PARAM_COUNT),
        .PARAM_W(PARAM_W)
	) DISPLAY (
		.fx_sel        (fx_sel),
		.param_sel     (param_sel),
		.current_value (current_value),
		.SW            (SW[9:0]),
		.LEDR          (LEDR[9:0]),
		.HEX0          (HEX0),
		.HEX1          (HEX1),
		.HEX2          (HEX2),
		.HEX3          (HEX3),
		.HEX4          (HEX4),
		.HEX5          (HEX5)
	);

    // ---------------- AUDIO FX INSTANTIATIONS ----------------



	
endmodule
