/*
 * AudioFX.sv  —  FIXED (pop + reverb-buzz)
 *
 * Fix 1 — Pop (ramp FSM stall)
 *   The fade FSM previously advanced only on sample_en_pipe[FX_STAGES-1],
 *   which is gated by chain_warm.  Before chain_warm asserts (65 535
 *   samples after reset) the FSM could stall mid-fade and produce a pop
 *   when audio finally began.  The FSM now advances on ADC_Valid[0],
 *   which is unconditional once the codec is running.
 *
 * Fix 2 — Reverb / delay buzz after bank switch
 *   When bank_sel flips at BANK_FADE_CYCLES the reverb comb-delay lengths
 *   change combinationally.  The read pointer (write_ptr - delay_samples)
 *   jumps to an arbitrary buffer position, injecting a discontinuous
 *   sample that then recirculates through the feedback path (gain ≈ 0.922)
 *   and rings — that's the buzz.  The 14 ms hold window doesn't help
 *   because the feedback loop sustains the glitch indefinitely.
 *
 *   Fix: assert fx_reset_n = 0 while fade_state == ST_MUTED (ramp_vol is
 *   already 0 so the DAC output is silent).  This re-initialises every
 *   delay pointer, BRAM address, and IIR accumulator to zero before the
 *   new bank's params take effect.  Residual BRAM content is inaudible
 *   because ramp_vol starts from 0 on fade-in and any leaking energy
 *   decays through the (now-reset) feedback path.
 *
 * All other logic is unchanged from the original.
 */

// `define NO_DSP

module AudioFX (
    // Inputs
    SW,
    KEY,
    CLOCK_50,
    AUD_ADCDAT,
    GPIO_1,
    ADC_DOUT,

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
    HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    ADC_CS_N,
    ADC_SCLK,
    ADC_DIN,
    GPIO_1_LED
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

    input  logic [4:0] GPIO_1;
    output logic       GPIO_1_LED;
    output logic ADC_CS_N;
    output logic ADC_SCLK;
    output logic ADC_DIN;
    input  logic ADC_DOUT;

    // ----------------------------------------------------------------
    // Internal Signals
    // ----------------------------------------------------------------

    // Audio codec streaming interface
    logic [1:0][DATA_W-1:0] DAC_Data, ADC_Data;
    logic [1:0] DAC_Ready, ADC_Ready, DAC_Valid, ADC_Valid;

    // Avalon-MM stub signals for AVConfig
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
    logic [$clog2(BANK_COUNT)-1:0]  bank_sel;
    logic                           bank_switching;

    // FX chain intermediate stereo busses
    logic [1:0][DATA_W-1:0] pre_fx;
    logic [1:0][DATA_W-1:0] gain_in_out;
    logic [1:0][DATA_W-1:0] gate_out;
    logic [1:0][DATA_W-1:0] eq_out_1;
    logic [1:0][DATA_W-1:0] comp_out;
    logic [1:0][DATA_W-1:0] dist_out;
    logic [1:0][DATA_W-1:0] eq_out_2;
    logic [1:0][DATA_W-1:0] chorus_out;
    logic [1:0][DATA_W-1:0] gain_expression_out;
    logic [1:0][DATA_W-1:0] delay_out;
    logic [1:0][DATA_W-1:0] reverb_out;
    logic [1:0][DATA_W-1:0] gain_out_out;

    // Sample-enable shift register
    logic [FX_STAGES-1:0] sample_en_pipe;

    // Tuner
    logic [11:0] tuner_best_lag;
    logic        tuner_valid;

    // Flash Avalon-MM buses (avl_mem)
    logic [21:0] flash_mem_address;
    logic        flash_mem_read;
    logic        flash_mem_write;
    logic [31:0] flash_mem_writedata;
    logic [31:0] flash_mem_readdata;
    logic        flash_mem_waitrequest;
    logic        flash_mem_readdatavalid;
    logic [3:0]  flash_mem_byteenable;

    // Flash Avalon-MM buses (avl_csr)
    logic [5:0]  flash_csr_address;
    logic        flash_csr_read;
    logic [31:0] flash_csr_readdata;
    logic        flash_csr_write;
    logic [31:0] flash_csr_writedata;
    logic        flash_csr_waitrequest;
    logic        flash_csr_readdatavalid;

    // Tap Tempo
    logic [$clog2(MAX_SAMPLES)-1:0] tap_delay_samples;
    logic                     tap_tempo_active;
    logic                     beat_pulse;

    // Potentiometer ADC
    logic [11:0] pot_value;

    // ----------------------------------------------------------------
    // Audio Hardware IPs
    // ----------------------------------------------------------------

    `ifndef NO_DSP

        // Audio PLL — generates AUD_XCK for the WM8731 codec
        AudioPLL AUDIO_PLL (
            .ref_clk_clk        (CLOCK_50),
            .ref_reset_reset    (~KEY[0]),
            .audio_clk_clk      (AUD_XCK),
            .reset_source_reset ()
        );

        // I2C codec configuration (16-bit audio, 48 kHz)
        AVConfig AV_CONFIG (
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
        AudioCodec AUDIO_CODEC (
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
    // Expression Pedal Potentiometer ADC  (always active)
    // ----------------------------------------------------------------

    altera_up_avalon_adc_mega #(
        .tsclk     (8'd6),
        .numch     (4'd1),
        .board     ("DE1-SoC"),
        .board_rev ("Autodetect")
    ) POT_ADC (
        .CLOCK    (CLOCK_50),
        .RESET    (~KEY[0]),
        .ADC_CS_N (ADC_CS_N),
        .ADC_SCLK (ADC_SCLK),
        .ADC_DIN  (ADC_DIN),
        .ADC_DOUT (ADC_DOUT),
        .CH0      (pot_value),
        .CH1      (), .CH2(), .CH3(),
        .CH4      (), .CH5(), .CH6(), .CH7()
    );

    // ----------------------------------------------------------------
    // FX Parameter Controller
    // ----------------------------------------------------------------

    controller CONTROL (
        .clk               (CLOCK_50),
        .reset_n           (KEY[0]),
        .sw_fx_sel         (SW[9:6]),
        .sw_param_sel      (SW[5:3]),
        .bank_btn          (GPIO_1[3:0]),
        .bank_toggle       (SW[2]),
        .pot_value         (pot_value),
        .pot_valid         (1'b1),
        .key_inc           (~KEY[2]),
        .key_dec           (~KEY[3]),
        .save_button       (SW[0]),
        .load_button       (SW[1]),
        .mute_button       (~KEY[1] | ~GPIO_1[4]),
        .params            (params),
        .fx_sel            (fx_sel),
        .param_sel         (param_sel),
        .current_value     (current_value),
        .is_mute           (is_mute),
        .delay_pulse       (delay_pulse),
        .bank_sel          (bank_sel),
        .tap_delay_samples (tap_delay_samples),
        .tap_active        (tap_tempo_active),
        .beat_pulse        (beat_pulse),

        .LEDR              (),
        .fsm_busy          (fsm_busy),
        .bank_switching    (bank_switching),

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
        .bank_sel      (bank_sel),
        .beat_pulse    (beat_pulse),
        .tuner_best_lag(tuner_best_lag),
        .tuner_valid   (tuner_valid),
        .SW            (SW),
        .LEDR          (LEDR),
        .tap_mute_led  (GPIO_1_LED),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2),
        .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5)
    );

    // ----------------------------------------------------------------
    // FX Chain  (compiled only with audio hardware IPs)
    // ----------------------------------------------------------------

    `ifndef NO_DSP

        // Apply the same ramp_vol curve at the CHAIN INPUT, not just the
        // DAC output.  Without this, ST_MUTED→ST_FADE_IN flipped pre_fx
        // from 0 to full audio in one cycle: that step propagated into the
        // reverb combs and surfaced ~30 ms later as a crackle when the
        // first echo recirculated through the now-warm feedback path.
        // Scaling at both ends gives a smooth (slightly "S"-shaped)
        // fade and guarantees the chain never sees a discontinuity.
        // Concatenating 1'b0 prevents the multiplier from misinterpreting
        // ramp_vol = 256 (9'h100) as a negative signed number.
        logic signed [DATA_W+8:0] pre_fx_scaled;
        assign pre_fx_scaled = $signed(ADC_Data[0]) * $signed({1'b0, ramp_vol});

        // Guitar is mono: duplicate left ADC channel to both stereo lanes
        assign pre_fx[0] = pre_fx_scaled[DATA_W+7:8];
        assign pre_fx[1] = pre_fx_scaled[DATA_W+7:8];

        logic fx_flush;
        assign fx_flush = (fade_state == ST_MUTED);

        // ---- Tuner Engine ----------------------------------------
        tuner_yin_engine TUNER (
            .clk        (CLOCK_50),
            .reset_n    (KEY[0]),
            .audio_in   (ADC_Data[0]),
            .sample_en  (ADC_Valid[0]),
            .best_lag_out(tuner_best_lag),
            .data_valid (tuner_valid)
        );

        // ---- Sample-Enable Pipeline ----------------------------------
        localparam WARM_UP_SAMPLES = 16'd65535;
        logic [15:0] warm_ctr;
        logic        chain_warm;

        always_ff @(posedge CLOCK_50) begin
            if (!KEY[0]) begin
                warm_ctr   <= '0;
                chain_warm <= 1'b0;
            end else if (!chain_warm && ADC_Valid[0]) begin
                if (warm_ctr == WARM_UP_SAMPLES)
                    chain_warm <= 1'b1;
                else
                    warm_ctr <= warm_ctr + 1'b1;
            end
        end

        always_ff @(posedge CLOCK_50) begin : en_PIPELINE
            if (!KEY[0]) begin
                sample_en_pipe <= '0;
            end else begin
                sample_en_pipe[0] <= ADC_Valid[0] && chain_warm;
                for (int i = 1; i <= FX_STAGES - 1; i++)
                    sample_en_pipe[i] <= sample_en_pipe[i-1];
            end
        end

        // ----------------------------------------------------------------
        // DAC Soft-Mute Ramp + FX Reset
        //
        // mute_req sources: footswitch long-press, FSM busy, bank switching.
        //
        // FIX 1 — Pop:
        //   The FSM now advances on ADC_Valid[0] rather than
        //   sample_en_pipe[FX_STAGES-1].  The pipe-end enable is gated by
        //   chain_warm, so the old FSM could stall before the chain was warm
        //   and produce a pop when audio finally began.  ADC_Valid[0] is
        //   unconditional once the codec is running and always advances the
        //   ramp at the correct 48 kHz sample rate.
        //
        // FIX 2 — Reverb / delay buzz after bank switch:
        //   fx_reset_n is driven low while fade_state == ST_MUTED.
        //   At that point ramp_vol == 0 so the DAC output is silent —
        //   resetting every delay pointer, BRAM address register, and IIR
        //   accumulator is completely inaudible.  On the subsequent ST_FADE_IN
        //   ramp_vol climbs from 0, so any residual BRAM content (old echo
        //   tails) leaks in at negligible amplitude and decays naturally.
        //   This eliminates the feedback-sustained buzz that the 14 ms hold
        //   window alone could not suppress.
        // ----------------------------------------------------------------

        logic mute_req;
        assign mute_req = is_mute || fsm_busy || bank_switching;

        logic [8:0] ramp_vol;   // 0–256 (256 = unity gain)

        typedef enum logic [1:0] {
            ST_UNMUTED,
            ST_FADE_OUT,
            ST_MUTED,
            ST_FADE_IN
        } fade_state_t;
        fade_state_t fade_state;

        // ---- FIX 2: FX reset signal ----------------------------------
        // Low while ST_MUTED; propagates to every FX module's reset_n port.
        // Because ramp_vol is already 0 before this asserts, the DAC sees
        // no discontinuity.
        logic fx_reset_n;
        assign fx_reset_n = KEY[0] && (fade_state != ST_MUTED);

        // ---- FIX 1: Soft-mute FSM clocked on ADC_Valid[0] -----------
        // Previously clocked on sample_en_pipe[FX_STAGES-1] which is
        // gated by chain_warm — fixed by using ADC_Valid[0] directly.
        always_ff @(posedge CLOCK_50 or negedge KEY[0]) begin
            if (!KEY[0]) begin
                fade_state <= ST_UNMUTED;
                ramp_vol   <= 9'd256;
            end else if (ADC_Valid[0]) begin   // <-- FIX 1: was sample_en_pipe[FX_STAGES-1]
                case (fade_state)
                    ST_UNMUTED: begin
                        if (mute_req) begin
                            fade_state <= ST_FADE_OUT;
                            ramp_vol   <= ramp_vol - 1'b1;
                        end
                    end
                    ST_FADE_OUT: begin
                        if (!mute_req) begin
                            fade_state <= ST_FADE_IN;
                            ramp_vol   <= ramp_vol + 1'b1;
                        end else if (ramp_vol == 9'd0) begin
                            fade_state <= ST_MUTED;   // fx_reset_n drops here
                        end else begin
                            ramp_vol <= ramp_vol - 1'b1;
                        end
                    end
                    ST_MUTED: begin
                        // fx_reset_n = 0 while we stay here; FX modules
                        // hold reset until mute_req releases.
                        if (!mute_req) begin
                            fade_state <= ST_FADE_IN;
                            ramp_vol   <= ramp_vol + 1'b1;
                            // fx_reset_n rises on the same edge as we
                            // leave ST_MUTED, so FX modules come out of
                            // reset exactly as the fade-in begins.
                        end
                    end
                    ST_FADE_IN: begin
                        if (mute_req) begin
                            fade_state <= ST_FADE_OUT;
                            ramp_vol   <= ramp_vol - 1'b1;
                        end else if (ramp_vol == 9'd256) begin
                            fade_state <= ST_UNMUTED;
                        end else begin
                            ramp_vol <= ramp_vol + 1'b1;
                        end
                    end
                endcase
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
            .reset_n      (fx_reset_n),
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
            .reset_n     (fx_reset_n),
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
            .reset_n       (fx_reset_n),
            .audio_in      (eq_out_1),
            .audio_out     (comp_out),
            .fx_threshold  (params[3][0]),
            .fx_ratio      (params[3][1]),
            .fx_attack     (params[3][2]),
            .fx_release    (params[3][3]),
            .fx_input_gain (params[3][4]),
            .fx_makeup_gain(params[3][5]),
            .fx_mix        (params[3][7]),
            .sample_en     (sample_en_pipe[3])
        );

        // ---- FX 4: Distortion ----------------------------------------
        fx_distortion #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_DISTORTION (
            .clk           (CLOCK_50),
            .reset_n       (fx_reset_n),
            .audio_in      (comp_out),
            .audio_out     (dist_out),
            .fx_drive      (params[4][0]),
            .fx_makeup_gain(params[4][1]),
            .fx_bias       (params[4][2]),
            .fx_sag        (params[4][3]),
            .fx_tone       (params[4][4]),
            .fx_tightness  (params[4][5]),
            .fx_smooth     (params[4][6]),
            .fx_mix        (params[4][7]),
            .sample_en     (sample_en_pipe[4])
        );

        // ---- FX 5: EQ 2  (post-distortion) --------------------------
        fx_eq #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_EQ_2 (
            .clk         (CLOCK_50),
            .reset_n     (fx_reset_n),
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
            .reset_n  (fx_reset_n),
            .audio_in (eq_out_2),
            .audio_out(chorus_out),
            .fx_rate  (params[6][0]),
            .fx_depth (params[6][1]),
            .fx_mix   (params[6][7]),
            .sample_en(sample_en_pipe[6])
        );

        // ---- FX 7: Expression Gain -----------------------------------
        fx_gain #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_EXPRESSION_GAIN (
            .clk      (CLOCK_50),
            .reset_n  (KEY[0]),       
            .audio_in (chorus_out),
            .audio_out(gain_expression_out),
            .fx_gain  (params[7][0]),
            .sample_en(sample_en_pipe[7])
        );

        // ---- FX 8: Delay  (tap-tempo capable) -----------------------
        fx_delay #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_DELAY (
            .clk        (CLOCK_50),
            .reset_n    (fx_reset_n),     
            .audio_in   (gain_expression_out),
            .audio_out  (delay_out),
            .flush      (fx_flush),
            .fx_time    (params[8][0]),
            .fx_feedback(params[8][1]),
            .fx_mix     (params[8][7]),
            .sample_en  (sample_en_pipe[8]),
            .tap_samples(tap_delay_samples),
            .tap_active (tap_tempo_active)
        );

        // ---- FX 9: Reverb --------------------------------------------
        fx_reverb #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_REVERB (
            .clk       (CLOCK_50),
            .reset_n   (fx_reset_n),      
            .audio_in  (delay_out),
            .audio_out (reverb_out),
            .flush     (fx_flush),
            .fx_size   (params[9][0]),
            .fx_damping(params[9][1]),
            .fx_mix    (params[9][7]),
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

        // ---- DAC Output  (apply ramp_vol) ----------------------------
        // Concatenating 1'b0 prevents the multiplier from misinterpreting
        // ramp_vol = 256 (9'h100) as a negative signed number.
        logic signed [DATA_W+8:0] dac_left_scaled;
        logic signed [DATA_W+8:0] dac_right_scaled;

        assign dac_left_scaled  = $signed(gain_out_out[0]) * $signed({1'b0, ramp_vol});
        assign dac_right_scaled = $signed(gain_out_out[1]) * $signed({1'b0, ramp_vol});

        always_ff @(posedge CLOCK_50) begin
            DAC_Data[0] <= dac_left_scaled[DATA_W+7:8];
            DAC_Data[1] <= dac_right_scaled[DATA_W+7:8];
            DAC_Valid[0] <= sample_en_pipe[FX_STAGES-1];
            DAC_Valid[1] <= sample_en_pipe[FX_STAGES-1];
            ADC_Ready[0] <= DAC_Ready[0];
            ADC_Ready[1] <= DAC_Ready[1];
        end

    `endif

endmodule