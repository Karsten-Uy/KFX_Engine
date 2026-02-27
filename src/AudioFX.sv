/*
 * AudioFX.sv
 *
 * Top-level module for the multi-effects guitar pedalboard on DE1-SoC.
 *
 * Instantiates and connects four subsystems:
 *
 *   Audio I/O     — PLL (AUD_XCK), I2C codec config (AVConfig), and the
 *                   streaming codec interface (AudioCodec).  Gated by the
 *                   `ifndef NO_DSP macro for simulation without hardware IPs.
 *
 *   Flash memory  — FlashMemInterface Qsys/Platform Designer IP, providing
 *                   two Avalon-MM buses (avl_mem + avl_csr) to the controller.
 *                   Note: the EPCQ256 AS interface is internal to the IP;
 *                   no user-logic flash pins appear here.
 *
 *   Controller    — Manages params[][], button inputs, save/load, and mute.
 *
 *   Display       — Drives LEDR and HEX0–HEX5 from controller state and
 *                   the tuner engine output.
 *
 * FX chain  (left to right, all stereo, all pipelined on sample_en_pipe[])
 * -------------------------------------------------------------------------
 *   FX 0  Input Gain  →  FX 1  Gate       →  FX 2  EQ 1
 *   FX 3  Compressor  →  FX 4  Distortion →  FX 5  EQ 2
 *   FX 6  Chorus      →  FX 7  Spectral Gain
 *   FX 8  Delay  (tap-tempo capable)
 *   FX 9  Reverb      →  FX 10 Output Gain  →  DAC
 *
 * DAC muting
 * ----------
 *   The DAC output is forced to zero when is_mute is asserted (footswitch
 *   long-press) or fsm_busy is high (flash save / load in progress).
 *   Muting during fsm_busy prevents audible glitches from mid-stream param
 *   updates while the load FSM writes bytes one at a time into the FX chain.
 *
 * Tuner
 * -----
 *   tuner_yin_engine runs continuously on the raw ADC input and produces a
 *   best_lag estimate roughly every 170 ms.  The display module converts this
 *   to a note name and tuning indicator on HEX0–HEX5 while mute is active.
 *
 * Macro
 * -----
 *   `define NO_DSP  — omit all audio hardware IPs and FX chain; useful for
 *                     controller / display simulation without codec files.
 */

// `define NO_DSP

module AudioFX (
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
    HEX0, HEX1, HEX2, HEX3, HEX4, HEX5
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // I/O Declarations
    // ----------------------------------------------------------------

    input  logic [9:0] SW;
    input  logic       CLOCK_50;
    input  logic [3:0] KEY;
    input  logic       AUD_ADCDAT;

    inout  AUD_BCLK;
    inout  AUD_ADCLRCK;
    inout  AUD_DACLRCK;
    inout  FPGA_I2C_SDAT;

    output logic        AUD_XCK;
    output logic        AUD_DACDAT;
    output logic        FPGA_I2C_SCLK;
    output logic [9:0]  LEDR;
    output logic [DATA_W-1:0] GPIO_0;
    output logic [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;

    // ----------------------------------------------------------------
    // Internal Signals
    // ----------------------------------------------------------------

    // Audio codec streaming interface
    logic [1:0][DATA_W-1:0] DAC_Data, ADC_Data;
    logic [1:0] DAC_Ready, ADC_Ready, DAC_Valid, ADC_Valid;

    // Avalon-MM stub signals for AVConfig (unused address/control ports)
    logic [31:0] i2c_data       = 32'd0;
    logic [31:0] i2c_read_data  = 32'd0;
    logic [3:0]  i2c_byte_enable = 4'b1111;
    logic        i2c_read       = 1'b0;
    logic        i2c_write      = 1'b0;
    logic        i2c_waitrequest;

    // Controller outputs
    logic [PARAM_W-1:0]             params [0:FX_COUNT-1][0:PARAM_COUNT-1];
    logic [$clog2(FX_COUNT)-1:0]    fx_sel;
    logic [$clog2(PARAM_COUNT)-1:0] param_sel;
    logic [PARAM_W-1:0]             current_value;
    logic                           fsm_busy;
    logic                           is_mute;
    logic                           delay_pulse;

    // FX chain intermediate stereo busses (one per stage output)
    logic [1:0][DATA_W-1:0] pre_fx;
    logic [1:0][DATA_W-1:0] gain_in_out;
    logic [1:0][DATA_W-1:0] gate_out;
    logic [1:0][DATA_W-1:0] eq_out_1;
    logic [1:0][DATA_W-1:0] comp_out;
    logic [1:0][DATA_W-1:0] dist_out;
    logic [1:0][DATA_W-1:0] eq_out_2;
    logic [1:0][DATA_W-1:0] chorus_out;
    logic [1:0][DATA_W-1:0] gain_spectral_out;
    logic [1:0][DATA_W-1:0] delay_out;
    logic [1:0][DATA_W-1:0] reverb_out;
    logic [1:0][DATA_W-1:0] gain_out_out;

    // Sample-enable shift register: one stage per FX block
    logic [FX_STAGES-1:0] sample_en_pipe;

    // Tuner
    logic [11:0] tuner_best_lag;
    logic        tuner_valid;

    // Flash Avalon-MM buses (avl_mem — data reads/writes)
    logic [21:0] flash_mem_address;
    logic        flash_mem_read;
    logic        flash_mem_write;
    logic [31:0] flash_mem_writedata;
    logic [31:0] flash_mem_readdata;
    logic        flash_mem_waitrequest;
    logic        flash_mem_readdatavalid;
    logic [3:0]  flash_mem_byteenable;

    // Flash Avalon-MM buses (avl_csr — erase / WREN commands)
    logic [5:0]  flash_csr_address;
    logic        flash_csr_read;
    logic [31:0] flash_csr_readdata;
    logic        flash_csr_write;
    logic [31:0] flash_csr_writedata;
    logic        flash_csr_waitrequest;
    logic        flash_csr_readdatavalid;

	// Tap Tempo
	logic [$clog2(24000)-1:0] tap_delay_samples;
    logic                     tap_tempo_active;

    // ----------------------------------------------------------------
    // Audio Hardware IPs  (omitted when NO_DSP is defined)
    // ----------------------------------------------------------------

    `ifndef NO_DSP

        // Audio PLL — generates AUD_XCK for the WM8731 codec
        AudioPLL u0 (
            .ref_clk_clk        (CLOCK_50),
            .ref_reset_reset    (~KEY[0]),
            .audio_clk_clk      (AUD_XCK),
            .reset_source_reset ()           // unused
        );

        // I2C codec configuration (16-bit audio, 48 kHz)
        AVConfig u1 (
            .clk         (CLOCK_50),
            .reset       (~KEY[0]),
            .address     (i2c_read_data),
            .byteenable  (i2c_byte_enable),
            .read        (i2c_read),
            .write       (i2c_write),
            .writedata   (i2c_data),
            .readdata    (i2c_data),
            .waitrequest (i2c_waitrequest),
            .I2C_SDAT    (FPGA_I2C_SDAT),
            .I2C_SCLK    (FPGA_I2C_SCLK)
        );

        // Avalon-streaming codec: ADC capture and DAC playback
        AudioCodec u2 (
            .clk                          (CLOCK_50),
            .reset                        (~KEY[0]),
            .AUD_ADCDAT                   (AUD_ADCDAT),
            .AUD_ADCLRCK                  (AUD_ADCLRCK),
            .AUD_BCLK                     (AUD_BCLK),
            .AUD_DACDAT                   (AUD_DACDAT),
            .AUD_DACLRCK                  (AUD_DACLRCK),
            .from_adc_left_channel_ready  (ADC_Ready[0]),
            .from_adc_left_channel_data   (ADC_Data[0]),
            .from_adc_left_channel_valid  (ADC_Valid[0]),
            .from_adc_right_channel_ready (ADC_Ready[1]),
            .from_adc_right_channel_data  (ADC_Data[1]),
            .from_adc_right_channel_valid (ADC_Valid[1]),
            .to_dac_left_channel_data     (DAC_Data[0]),
            .to_dac_left_channel_valid    (DAC_Valid[0]),
            .to_dac_left_channel_ready    (DAC_Ready[0]),
            .to_dac_right_channel_data    (DAC_Data[1]),
            .to_dac_right_channel_valid   (DAC_Valid[1]),
            .to_dac_right_channel_ready   (DAC_Ready[1])
        );

        // Expose left DAC output on GPIO for scope / SignalTap debugging
        assign GPIO_0[DATA_W-1:0] = DAC_Data[0];

    `endif

    // ----------------------------------------------------------------
    // Flash Memory Interface
    //
    // The FlashMemInterface IP (intel_generic_serial_flash_interface) is
    // configured with "Disable dedicated Active Serial interface" UNCHECKED,
    // so it connects directly to the EPCQ128 via the internal ASMI block.
    // No user-logic SPI pins are needed or permitted.
    // ----------------------------------------------------------------

    FlashMemInterface F_MEM (
        .clk_clk                 (CLOCK_50),
        .reset_reset_n           (KEY[0]),

        .flash_csr_address       (flash_csr_address),
        .flash_csr_read          (flash_csr_read),
        .flash_csr_readdata      (flash_csr_readdata),
        .flash_csr_write         (flash_csr_write),
        .flash_csr_writedata     (flash_csr_writedata),
        .flash_csr_waitrequest   (flash_csr_waitrequest),
        .flash_csr_readdatavalid (flash_csr_readdatavalid),

        .flash_mem_write         (flash_mem_write),
        .flash_mem_burstcount    (7'd1),
        .flash_mem_waitrequest   (flash_mem_waitrequest),
        .flash_mem_read          (flash_mem_read),
        .flash_mem_address       (flash_mem_address),
        .flash_mem_writedata     (flash_mem_writedata),
        .flash_mem_readdata      (flash_mem_readdata),
        .flash_mem_readdatavalid (flash_mem_readdatavalid),
        .flash_mem_byteenable    (flash_mem_byteenable)
    );

    // ----------------------------------------------------------------
    // FX Parameter Controller
    // ----------------------------------------------------------------

    controller CONTROL (
        .clk          (CLOCK_50),
        .reset_n      (KEY[0]),
        .sw_fx_sel    (SW[9:6]),
        .sw_param_sel (SW[4:2]),
        .key_inc      (~KEY[2]),
        .key_dec      (~KEY[3]),
        .save_button  (SW[0]),
        .load_button  (SW[1]),
        .mute_button  (~KEY[1]),
        .params       (params),
        .fx_sel       (fx_sel),
        .param_sel    (param_sel),
        .current_value(current_value),
        .is_mute      (is_mute),
        .delay_pulse  (delay_pulse),
        .LEDR         (),        // diagnostic LEDs driven by display module
        .fsm_busy     (fsm_busy),

        .flash_mem_address       (flash_mem_address),
        .flash_mem_read          (flash_mem_read),
        .flash_mem_write         (flash_mem_write),
        .flash_mem_writedata     (flash_mem_writedata),
        .flash_mem_readdata      (flash_mem_readdata),
        .flash_mem_waitrequest   (flash_mem_waitrequest),
        .flash_mem_readdatavalid (flash_mem_readdatavalid),
        .flash_mem_byteenable    (flash_mem_byteenable),
        .flash_csr_address       (flash_csr_address),
        .flash_csr_write         (flash_csr_write),
        .flash_csr_read          (flash_csr_read),
        .flash_csr_writedata     (flash_csr_writedata),
        .flash_csr_readdata      (flash_csr_readdata),
        .flash_csr_waitrequest   (flash_csr_waitrequest),
        .flash_csr_readdatavalid (flash_csr_readdatavalid)
    );

    // ----------------------------------------------------------------
    // LEDR + HEX Display Controller
    // ----------------------------------------------------------------

    display DISPLAY (
        .clk           (CLOCK_50),
        .reset_n       (KEY[0]),
        .fx_sel        (fx_sel),
        .param_sel     (param_sel),
        .current_value (current_value),
        .fsm_busy      (fsm_busy),
        .is_mute       (is_mute),
        .tuner_best_lag(tuner_best_lag),
        .tuner_valid   (tuner_valid),
        .SW            (SW),
        .LEDR          (LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2),
        .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5)
    );

    // ----------------------------------------------------------------
    // FX Chain  (compiled only with audio hardware IPs)
    // ----------------------------------------------------------------

    `ifndef NO_DSP

        // Guitar is mono: duplicate left ADC channel to both stereo lanes
        assign pre_fx[0] = ADC_Data[0];
        assign pre_fx[1] = ADC_Data[0];

        // ---- Tuner Engine ----------------------------------------
        // Runs continuously on the raw (pre-FX) ADC input
        tuner_yin_engine TUNER (
            .clk        (CLOCK_50),
            .reset_n    (KEY[0]),
            .audio_in   (ADC_Data[0]),
            .sample_en  (ADC_Valid[0]),
            .best_lag_out(tuner_best_lag),
            .data_valid (tuner_valid)
        );

        // ---- Sample-Enable Pipeline ----------------------------------
        // Each FX stage gets a one-cycle-delayed version of ADC_Valid[0],
        // so every block gets exactly one enable pulse per audio sample.
        always_ff @(posedge CLOCK_50) begin : en_PIPELINE
            if (!KEY[0]) begin
                sample_en_pipe <= '0;
            end else begin
                sample_en_pipe[0] <= ADC_Valid[0];
                for (int i = 1; i <= FX_STAGES - 1; i++)
                    sample_en_pipe[i] <= sample_en_pipe[i-1];
            end
        end

        // ---- FX 0: Input Gain ----------------------------------------
        fx_gain #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_INPUT_GAIN (
            .clk      (CLOCK_50),
            .reset_n  (KEY[0]),
            .audio_in (pre_fx),
            .audio_out(gain_in_out),
            .fx_gain  (params[0][0]),
            .sample_en(sample_en_pipe[0])
        );

        // ---- FX 1: Noise Gate ----------------------------------------
        fx_gate #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_GATE (
            .clk          (CLOCK_50),
            .reset_n      (KEY[0]),
            .audio_in     (gain_in_out),
            .audio_out    (gate_out),
            .fx_threshold (params[1][0]),
            .fx_attack    (params[1][1]),
            .fx_release   (params[1][2]),
            .fx_knee      (params[1][3]),
            .fx_depth     (params[1][4]),
            .sample_en    (sample_en_pipe[1])
        );

        // ---- FX 2: EQ 1  (pre-distortion) ---------------------------
        fx_eq #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_EQ_1 (
            .clk         (CLOCK_50),
            .reset_n     (KEY[0]),
            .audio_in    (gate_out),
            .audio_out   (eq_out_1),
            .fx_sub_gain (params[2][0]),
            .fx_low_gain (params[2][1]),
            .fx_mid_gain (params[2][2]),
            .fx_high_gain(params[2][3]),
            .sample_en   (sample_en_pipe[2])
        );

        // ---- FX 3: Compressor ----------------------------------------
        fx_compressor #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_COMPRESSOR (
            .clk           (CLOCK_50),
            .reset_n       (KEY[0]),
            .audio_in      (eq_out_1),
            .audio_out     (comp_out),
            .fx_threshold  (params[3][0]),
            .fx_ratio      (params[3][1]),
            .fx_attack     (params[3][2]),
            .fx_release    (params[3][3]),
            .fx_input_gain (params[3][4]),
            .fx_makeup_gain(params[3][5]),
            .fx_mix        (params[3][6]),
            .sample_en     (sample_en_pipe[3])
        );

        // ---- FX 4: Distortion ----------------------------------------
        fx_distortion #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_DISTORTION (
            .clk           (CLOCK_50),
            .reset_n       (KEY[0]),
            .audio_in      (comp_out),
            .audio_out     (dist_out),
            .fx_drive      (params[4][0]),
            .fx_makeup_gain(params[4][1]),
            .fx_mix        (params[4][2]),
            .sample_en     (sample_en_pipe[4])
        );

        // ---- FX 5: EQ 2  (post-distortion) --------------------------
        fx_eq #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_EQ_2 (
            .clk         (CLOCK_50),
            .reset_n     (KEY[0]),
            .audio_in    (dist_out),
            .audio_out   (eq_out_2),
            .fx_sub_gain (params[5][0]),
            .fx_low_gain (params[5][1]),
            .fx_mid_gain (params[5][2]),
            .fx_high_gain(params[5][3]),
            .sample_en   (sample_en_pipe[5])
        );

        // ---- FX 6: Chorus --------------------------------------------
        fx_chorus #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_CHORUS (
            .clk      (CLOCK_50),
            .reset_n  (KEY[0]),
            .audio_in (eq_out_2),
            .audio_out(chorus_out),
            .fx_rate  (params[6][0]),
            .fx_depth (params[6][1]),
            .fx_mix   (params[6][2]),
            .sample_en(sample_en_pipe[6])
        );

        // ---- FX 7: Spectral Gain  (expression pedal target) ----------
        fx_gain #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_SPECTRAL_GAIN (
            .clk      (CLOCK_50),
            .reset_n  (KEY[0]),
            .audio_in (chorus_out),
            .audio_out(gain_spectral_out),
            .fx_gain  (params[7][0]),
            .sample_en(sample_en_pipe[7])
        );

        // ---- Tap Tempo -----------------------------------------------
        // Converts footswitch tap intervals into a delay sample count
        tap_tempo_unit TAP_TEMPO (
            .clk          (CLOCK_50),
            .rst_n        (KEY[0]),
            .tap_pulse    (delay_pulse),
            .delay_samples(tap_delay_samples),
            .tap_active   (tap_tempo_active)
        );

        // ---- FX 8: Delay  (tap-tempo capable) -----------------------
        fx_delay #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_DELAY (
            .clk        (CLOCK_50),
            .reset_n    (KEY[0]),
            .audio_in   (gain_spectral_out),
            .audio_out  (delay_out),
            .fx_time    (params[8][0]),
            .fx_feedback(params[8][1]),
            .fx_mix     (params[8][2]),
            .sample_en  (sample_en_pipe[8]),
            .tap_samples(tap_delay_samples),
            .tap_active (tap_tempo_active)
        );

        // ---- FX 9: Reverb --------------------------------------------
        fx_reverb #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_REVERB (
            .clk       (CLOCK_50),
            .reset_n   (KEY[0]),
            .audio_in  (delay_out),
            .audio_out (reverb_out),
            .fx_size   (params[9][0]),
            .fx_damping(params[9][1]),
            .fx_mix    (params[9][2]),
            .sample_en (sample_en_pipe[9])
        );

        // ---- FX 10: Output Gain -------------------------------------
        fx_gain #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_OUTPUT_GAIN (
            .clk      (CLOCK_50),
            .reset_n  (KEY[0]),
            .audio_in (reverb_out),
            .audio_out(gain_out_out),
            .fx_gain  (params[10][0]),
            .sample_en(sample_en_pipe[10])
        );

        // ---- DAC Output  (muted during mute or flash operation) ------
        //
        // Writing params[] while the FX chain is running produces per-sample
        // glitches (gain, threshold, and EQ jumps).  Gating the DAC to zero
        // for the brief duration of fsm_busy eliminates this completely.
        always_ff @(posedge CLOCK_50) begin
            if (is_mute || fsm_busy) begin
                DAC_Data[0] <= 16'd0;
                DAC_Data[1] <= 16'd0;
            end else begin
                DAC_Data[0] <= gain_out_out[0];
                DAC_Data[1] <= gain_out_out[1];
            end
            // Valid and Ready are unconditional
            DAC_Valid[0] <= sample_en_pipe[FX_STAGES-1];
            DAC_Valid[1] <= sample_en_pipe[FX_STAGES-1];
            ADC_Ready[0] <= DAC_Ready[0];
            ADC_Ready[1] <= DAC_Ready[1];
        end

    `endif

endmodule