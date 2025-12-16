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
		
	// // Basic tie-back for audio ADC -> DAC
	// always@(posedge(CLOCK_50)) begin
	// 	// Mute Condition using switch 9
	// 	if(SW[0]==1) begin
	// 		DAC_Data[0] <= 0;
	// 		DAC_Data[1] <= 0;
	// 		DAC_Valid[0] <= ADC_Valid[1];
	// 		DAC_Valid[1] <= ADC_Valid[0];
	// 		ADC_Ready[0] <= DAC_Ready[1];
	// 		ADC_Ready[1] <= DAC_Ready[0];
	// 	end else begin
	// 		// Normal operation
	// 		DAC_Data[0] <= ADC_Data[0];
	// 		DAC_Data[1] <= ADC_Data[1];
	// 		DAC_Valid[0] <= ADC_Valid[0];
	// 		DAC_Valid[1] <= ADC_Valid[1];
	// 		ADC_Ready[0] <= DAC_Ready[0];
	// 		ADC_Ready[1] <= DAC_Ready[1];
	// 	end
	// end

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

	// FX Chain intermediate signals
	logic [1:0][DATA_W-1:0] pre_fx; 
	logic [1:0][DATA_W-1:0] gain_in_out; 
	logic [1:0][DATA_W-1:0] gate_out; 
	logic [1:0][DATA_W-1:0] eq_out; 
	logic [1:0][DATA_W-1:0] comp_out;
	logic [1:0][DATA_W-1:0] dist_out;
	logic [1:0][DATA_W-1:0] chorus_out;
	logic [1:0][DATA_W-1:0] delay_out;
	logic [1:0][DATA_W-1:0] reverb_out;
	logic [1:0][DATA_W-1:0] gain_out_out;

	// Pipeline
	logic [FX_STAGES:0] sample_en_pipe;

	/*
		How Audio is passed through the FX
		
		1. it is first turning into mono for a guitar input by duplicating the left channel
		2. it then passes the signal to each effect, which takes 1 clk cycle to process once ADC_Valid[0] pulses
		   which then is pipelined in a way such that the final processed audio will reach the DAC at the same
		   time as the final sample_en_pipe pulse
	*/

	// Mono converter, needed for guitar
	assign pre_fx[0] = ADC_Data[0];
	assign pre_fx[1] = ADC_Data[0];

	always_ff @(posedge CLOCK_50) begin: en_PIPELINE
		if (!KEY[0]) begin
			sample_en_pipe <= '0;
		end else begin
			sample_en_pipe[0] <= ADC_Valid[0];
			for (int i = 1; i <= FX_STAGES; i++) begin
				sample_en_pipe[i] <= sample_en_pipe[i-1];
			end
		end
	end
	
	// Input Gain (FX 0)
	fx_gain #(
		.DATA_W(DATA_W),
		.PARAM_W(PARAM_W)
	) FX_INPUT_GAIN (
		.clk       (CLOCK_50),
		.reset_n   (KEY[0]),
		.audio_in  (pre_fx),
		.audio_out (gain_in_out),
		.fx_gain   (params[0][0]),
		.sample_en (sample_en_pipe[0])
	);

	// Gate (FX 1)
	fx_gate #(
		.DATA_W(DATA_W),
		.PARAM_W(PARAM_W)
	) FX_GATE (
		.clk          (CLOCK_50),
		.reset_n      (KEY[0]),
		.audio_in     (gain_in_out),
		.audio_out    (gate_out),
		.fx_threshold (params[1][0]),
		.fx_attack    (params[1][1]),
		.fx_release   (params[1][2]),
		.sample_en    (sample_en_pipe[1])
	);

	// EQ (FX 2)
	fx_eq #(
		.DATA_W(DATA_W),
		.PARAM_W(PARAM_W)
	) FX_EQ (
		.clk          (CLOCK_50),
		.reset_n      (KEY[0]),
		.audio_in     (gate_out),
		.audio_out    (eq_out),
		.fx_low_gain  (params[2][0]),
		.fx_mid_gain  (params[2][1]),
		.fx_high_gain (params[2][2]),
		.fx_presence  (params[2][3]),
		.sample_en    (sample_en_pipe[2])
	);

	// Compressor (FX 3)
	fx_compressor #(
		.DATA_W(DATA_W),
		.PARAM_W(PARAM_W)
	) FX_COMPRESSOR (
		.clk          (CLOCK_50),
		.reset_n      (KEY[0]),
		.audio_in     (eq_out),
		.audio_out    (comp_out),
		.fx_threshold (params[3][0]),
		.fx_ratio     (params[3][1]),
		.fx_attack    (params[3][2]),
		.fx_release   (params[3][3]),
		.sample_en    (sample_en_pipe[3])
	);

	// Distortion (FX 4)
	fx_distortion #(
		.DATA_W(DATA_W),
		.PARAM_W(PARAM_W)
	) FX_DISTORTION (
		.clk       (CLOCK_50),
		.reset_n   (KEY[0]),
		.audio_in  (comp_out),
		.audio_out (dist_out),
		.fx_drive  (params[4][0]),
		.fx_tone   (params[4][1]),
		.fx_mix    (params[4][2]),
		.sample_en (sample_en_pipe[4])
	);

	// Chorus (FX 5)
	fx_chorus #(
		.DATA_W(DATA_W),
		.PARAM_W(PARAM_W)
	) FX_CHORUS (
		.clk       (CLOCK_50),
		.reset_n   (KEY[0]),
		.audio_in  (dist_out),
		.audio_out (chorus_out),
		.fx_rate   (params[5][0]),
		.fx_depth  (params[5][1]),
		.fx_mix    (params[5][2]),
		.sample_en (sample_en_pipe[5])
	);

	// Delay (FX 6)
	fx_delay #(
		.DATA_W(DATA_W),
		.PARAM_W(PARAM_W)
	) FX_DELAY (
		.clk         (CLOCK_50),
		.reset_n     (KEY[0]),
		.audio_in    (chorus_out),
		.audio_out   (delay_out),
		.fx_time     (params[6][0]),
		.fx_feedback (params[6][1]),
		.fx_mix      (params[6][2]),
		.sample_en   (sample_en_pipe[6])
	);

	// Reverb (FX 7)
	fx_reverb #(
		.DATA_W(DATA_W),
		.PARAM_W(PARAM_W)
	) FX_REVERB (
		.clk        (CLOCK_50),
		.reset_n    (KEY[0]),
		.audio_in   (delay_out),
		.audio_out  (reverb_out),
		.fx_size    (params[7][0]),
		.fx_damping (params[7][1]),
		.fx_mix     (params[7][2]),
		.sample_en  (sample_en_pipe[7])
	);

	// Output Gain (FX 8)
	fx_gain #(
		.DATA_W(DATA_W),
		.PARAM_W(PARAM_W)
	) FX_OUTPUT_GAIN (
		.clk       (CLOCK_50),
		.reset_n   (KEY[0]),
		.audio_in  (reverb_out),
		.audio_out (gain_out_out),
		.fx_gain   (params[8][0]),
		.sample_en (sample_en_pipe[8])
	);

	// FX Chain output to DAC
	always@(posedge(CLOCK_50)) begin
		// Mute Condition using switch 0
		if(SW[0]==1) begin
			DAC_Data[0] <= 0;
			DAC_Data[1] <= 0;
			DAC_Valid[0] <= sample_en_pipe[8];
			DAC_Valid[1] <= sample_en_pipe[8];
			ADC_Ready[0] <= DAC_Ready[1];
			ADC_Ready[1] <= DAC_Ready[0];
		end else begin
			// FX Chain output
			DAC_Data[0] <= gain_out_out[0];
			DAC_Data[1] <= gain_out_out[1];
			DAC_Valid[0] <= sample_en_pipe[8];
			DAC_Valid[1] <= sample_en_pipe[8];
			ADC_Ready[0] <= DAC_Ready[0];
			ADC_Ready[1] <= DAC_Ready[1];
		end
	end

	
endmodule
