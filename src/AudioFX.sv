 /*
 * AudioFX.sv
 *
 * Top-level module for the multi-effects guitar pedalboard on DE1-SoC.
 *
 * Instantiates and connects the following subsystems:
 *
 *   Audio I/O     — PLL (AUD_XCK), I2C codec config (AVConfig), and the
 *                   streaming codec interface (AudioCodec).  Gated by the
 *                   `ifndef NO_DSP macro for simulation without hardware IPs.
 *
 *   Flash memory  — FlashMemInterface Qsys/Platform Designer IP, providing
 *                   two Avalon-MM buses (avl_mem + avl_csr) to the controller
 *                   for save/load of preset banks across power cycles.
 *
 *   Controller    — Manages params[][], button inputs, save/load, mute,
 *                   tap-tempo, and bank selection.
 *
 *   Display       — Drives LEDR, HEX0–HEX5, and the tap/mute LED from
 *                   controller state and the tuner engine output.
 *
 *   Tuner         — Runs continuously on the raw ADC input regardless of
 *                   the chain state; result shown on HEX while muted.
 *
 *   Fade FSM      — Soft-mutes the DAC and chain input during bank switches
 *                   and footswitch mute, suppressing pops and BRAM-tail
 *                   bleed-through.
 *
 * FX chain  (audio flows in this order)
 * --------
 *   FX 0  Input Gain   — fx_gain (32 = unity)
 *   FX 1  Gate         — bit-exact bypass when fx_threshold==0 && fx_knee==0
 *   FX 2  EQ 1         — 4-band (sub/low/mid/high), unity at gain=128
 *   FX 3  Compressor   — mathematical bypass at fx_mix==0 (mixed = dry)
 *   FX 4  Distortion   — true bypass at fx_mix==0; cabinet IIR coefficient
 *                        clamped at 1.0 (fx_tone>=246 → safe_tone=256) so
 *                        the cabinet stays stable at any tone setting
 *   FX 5  EQ 2         — same module as EQ 1
 *   FX 6  Chorus       — stereo, two-voice (0°/90° quadrature)
 *   FX 7  Expression Gain — driven from external pedal via ADC_DOUT
 *   FX 8  Delay        — tap-tempo capable; KEY[1]/footswitch sets BPM
 *   FX 9  Reverb       — Schroeder (parallel comb + series allpass)
 *   FX 10 Output Gain  — fx_gain (32 = unity)
 *
 * Peripheral pins
 * ---------------
 *   GPIO_1[3:0]   — four bank-select footswitches (each picks a preset bank)
 *   GPIO_1[4]     — mute / tuner footswitch (OR'd with KEY[1])
 *   GPIO_1_LED    — tap LED: solid when muted, pulses at tap-tempo when not
 *   ADC_DOUT      — pot/ADC stream from external knob + expression pedal
 *                   (knob → pot_value for parameter editing; pedal →
 *                    Expression Gain stage at FX 7)
 *
 * DAC muting
 * ----------
 *   The DAC output is forced to zero when is_mute is asserted (footswitch
 *   long-press / KEY[1]) or fsm_busy is high (flash save / load in progress).
 *   Muting during fsm_busy prevents audible glitches from mid-stream param
 *   updates while the load FSM writes bytes one at a time into the FX chain.
 *
 * Tuner
 * -----
 *   tuner_yin_engine runs continuously on the raw ADC input and produces a
 *   Q12.4 lag estimate roughly every 170 ms.  Pitch detection uses YIN with
 *   threshold-cross *plus a descent walk* — once the difference function
 *   d(tau) drops below threshold the engine keeps walking down the dip until
 *   d(tau) starts increasing, then parabolic-interpolates around the actual
 *   local minimum for sub-sample precision (eliminates the +60..90 cent
 *   bias that the old plain-threshold-cross implementation had on guitar).
 *
 *   tuner_display takes the lag and produces the six HEX values: SW[9]
 *   selects between note mode (letter + octave + ^/V/- indicator with
 *   ±5-cent tolerance and ±10-cent boundary hysteresis) and frequency mode
 *   (Hz reading).  Output goes to HEX0–HEX5 only while is_mute is high.
 *
 * Soft-mute / bank-switch click suppression
 * -----------------------------------------
 *   The fade FSM (`fade_fsm`, src/control/fade_fsm.sv) drives `ramp_vol`,
 *   `muted`, and `unmuted`.  These three outputs are consumed here:
 *
 *     • DAC output is multiplied by ramp_vol (smooth fade always).
 *     • Chain input is multiplied by ramp_vol *during transitions
 *       only*; in steady state it bypasses the multiplier so the
 *       audio path is bit-exact (avoids DSP-block routing hiss).
 *     • `fx_reset_n` drops while `muted` is high — clears delay /
 *       reverb pointers + BRAM (via the self-clearing walk in
 *       delay_line.sv) so old echo tails don't leak into the new
 *       bank's feedback paths.
 *     • `fx_flush` is just `muted`, used by delay/reverb to clamp
 *       feedback during the muted window.
 *
 * Chain latency  (audio_in → audio_out, in 48 kHz samples)
 * --------------------------------------------------------
 *   FX 0  Input Gain     1     fx_gain registered output
 *   FX 1  Gate           0     audio_out is combinational (assign)
 *   FX 2  EQ 1           2     leaky integrators + output reg
 *   FX 3  Compressor    10     1 input_gain + 8 lookahead + 1 output reg
 *   FX 4  Distortion     6     pipeline regs in drive/clip/post chain
 *                              (drops to 1 when fx_mix == 0 — true bypass)
 *   FX 5  EQ 2           2     same module as EQ 1
 *   FX 6  Chorus         3     2 delay_line_li pipeline + 1 output reg
 *   FX 7  Expression     1     fx_gain registered output
 *   FX 8  Delay          2     1 delay-line RAM + 1 output reg
 *   FX 9  Reverb         1     dry path: combinational mix + output reg
 *   FX 10 Output Gain    1     fx_gain registered output
 *   FX 15 Global Gain    1     fx_gain registered output
 *   DAC reg              0     <1 CLOCK_50 cycle, negligible
 *   --------------------------
 *   Worst case (all engaged):  30 samples = 625 µs  @ 48 kHz
 *   Best case (dist bypassed): 25 samples = 521 µs  @ 48 kHz
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
    logic [1:0][DATA_W-1:0] global_gain_out;

    // Sample-enable shift register
    logic [FX_STAGES-1:0] sample_en_pipe;

    // Tuner — Q12.4 lag (12 integer samples + 4 fractional bits from
    // parabolic interpolation around the YIN minimum)
    logic [15:0] tuner_best_lag;
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

    // Chain warm-up — gates sample_en_pipe[0] until the codec has
    // produced WARM_UP_SAMPLES valid samples after reset.
    localparam WARM_UP_SAMPLES = 16'd65535;
    logic [15:0] warm_ctr;
    logic        chain_warm;

    // Soft-mute fade FSM (instantiated below as `fade_fsm`)
    logic        mute_req;
    logic [8:0]  ramp_vol;       // 0..256 (256 = unity gain)
    logic        muted;          // ST_MUTED (drives fx_reset_n drop, fx_flush)
    logic        unmuted;        // ST_UNMUTED (selects direct ADC bypass)
    logic        fx_reset_n;     // KEY[0] && !muted — fed to delay/reverb
    logic        fx_flush;       // == muted — clamps feedback in delay/reverb

    // Chain-input scaler — only used during fade transitions.  In steady
    // state, pre_fx is wired directly from ADC_Data so the multiplier is
    // fully bypassed (bit-exact audio path, no DSP-block routing hiss).
    logic signed [DATA_W+8:0] pre_fx_scaled;

    // DAC output scaler — applies ramp_vol smoothly on every clock so
    // the fade is heard at the speakers regardless of chain state.
    logic signed [DATA_W+8:0] dac_left_scaled;
    logic signed [DATA_W+8:0] dac_right_scaled;

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

    // Host (PC) parameter-interface signals (JTAG-UART transport)
    logic                           host_wr_en, host_rst_en;
    logic                           host_save_pulse, host_load_pulse;
    logic [$clog2(BANK_COUNT)-1:0]  host_bank;
    logic [$clog2(FX_COUNT)-1:0]    host_fx;
    logic [$clog2(PARAM_COUNT)-1:0] host_param;
    logic [PARAM_W-1:0]             host_data, host_rd_value, host_default_value;
    logic [1:0]                     host_rst_scope;

    logic [7:0]  hu_rx_data, hu_tx_data;          // host_if <-> adapter byte stream
    logic        hu_rx_valid, hu_rx_ready, hu_tx_valid, hu_tx_ready;

    logic        ju_chipselect, ju_address, ju_read_n, ju_write_n, ju_waitrequest;
    logic [31:0] ju_readdata, ju_writedata;       // adapter <-> JtagUart Avalon-MM

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
        .flash_csr_readdatavalid (flash_csr_readdatavalid),

        .host_wr_en         (host_wr_en),
        .host_bank          (host_bank),
        .host_fx            (host_fx),
        .host_param         (host_param),
        .host_data          (host_data),
        .host_rst_en        (host_rst_en),
        .host_rst_scope     (host_rst_scope),
        .host_save_pulse    (host_save_pulse),
        .host_load_pulse    (host_load_pulse),
        .host_rd_value      (host_rd_value),
        .host_default_value (host_default_value)
    );

    // ----------------------------------------------------------------
    // Host (PC) Parameter Interface — JTAG-UART transport
    //
    //   JtagUart (Qsys IP)  <-Avalon->  jtag_uart_adapter  <-bytes->  host_if
    //   host_if drives the controller's host_* ports.  No top-level pins:
    //   the JTAG side rides the on-board USB-Blaster cable.
    // ----------------------------------------------------------------

    JtagUart JTAG_UART (
        .clk_clk                     (CLOCK_50),
        .reset_reset_n               (KEY[0]),
        .jtag_uart_slave_chipselect  (ju_chipselect),
        .jtag_uart_slave_address     (ju_address),
        .jtag_uart_slave_read_n      (ju_read_n),
        .jtag_uart_slave_readdata    (ju_readdata),
        .jtag_uart_slave_write_n     (ju_write_n),
        .jtag_uart_slave_writedata   (ju_writedata),
        .jtag_uart_slave_waitrequest (ju_waitrequest)
    );

    jtag_uart_adapter JTAG_ADAPTER (
        .clk            (CLOCK_50),
        .reset_n        (KEY[0]),
        .av_chipselect  (ju_chipselect),
        .av_address     (ju_address),
        .av_read_n      (ju_read_n),
        .av_readdata    (ju_readdata),
        .av_write_n     (ju_write_n),
        .av_writedata   (ju_writedata),
        .av_waitrequest (ju_waitrequest),
        .rx_data        (hu_rx_data),
        .rx_valid       (hu_rx_valid),
        .rx_ready       (hu_rx_ready),
        .tx_data        (hu_tx_data),
        .tx_valid       (hu_tx_valid),
        .tx_ready       (hu_tx_ready)
    );

    host_if HOST_IF (
        .clk                (CLOCK_50),
        .reset_n            (KEY[0]),
        .rx_data            (hu_rx_data),
        .rx_valid           (hu_rx_valid),
        .rx_ready           (hu_rx_ready),
        .tx_data            (hu_tx_data),
        .tx_valid           (hu_tx_valid),
        .tx_ready           (hu_tx_ready),
        .host_wr_en         (host_wr_en),
        .host_bank          (host_bank),
        .host_fx            (host_fx),
        .host_param         (host_param),
        .host_data          (host_data),
        .host_rst_en        (host_rst_en),
        .host_rst_scope     (host_rst_scope),
        .host_save_pulse    (host_save_pulse),
        .host_load_pulse    (host_load_pulse),
        .host_rd_value      (host_rd_value),
        .host_default_value (host_default_value),
        .bank_sel           (bank_sel),
        .fsm_busy           (fsm_busy)
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

        // Concatenating 1'b0 prevents the multiplier from misinterpreting
        // ramp_vol = 256 (9'h100) as a negative signed number.
        assign pre_fx_scaled = $signed(ADC_Data[0]) * $signed({1'b0, ramp_vol});

        // Guitar is mono: duplicate left ADC channel to both stereo lanes.
        // Direct passthrough in steady state, scaled during fade in/out.
        assign pre_fx[0] = unmuted ? ADC_Data[0]
                                   : pre_fx_scaled[DATA_W+7:8];
        assign pre_fx[1] = unmuted ? ADC_Data[0]
                                   : pre_fx_scaled[DATA_W+7:8];

        assign fx_flush = muted;

        // ---- Tuner Engine ----------------------------------------
        tuner_yin_engine TUNER (
            .clk        (CLOCK_50),
            .reset_n    (KEY[0]),
            .audio_in   (ADC_Data[0]),
            .sample_en  (ADC_Valid[0]),
            .best_lag_q4_out(tuner_best_lag),
            .data_valid     (tuner_valid)
        );

        // ---- Sample-Enable Pipeline ----------------------------------
        // Warm-up counter holds sample_en_pipe[0] low for the first
        // WARM_UP_SAMPLES audio samples after reset, giving codec / PLL
        // / IIR initial transients time to settle before the chain
        // starts processing.
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
        // Soft-Mute Fade FSM
        //
        // mute_req sources: footswitch long-press (is_mute), controller
        // FSM busy (fsm_busy), and bank switch in progress
        // (bank_switching).  fade_fsm turns this into ramp_vol (DAC +
        // chain-input scale) plus muted/unmuted flags consumed below.
        //
        // Clocked on ADC_Valid[0] (not sample_en_pipe[FX_STAGES-1])
        // because the latter is gated by chain_warm — the FSM must
        // advance from the very first codec sample so it can never
        // stall mid-fade.
        // ----------------------------------------------------------------

        assign mute_req   = is_mute || fsm_busy || bank_switching;
        assign fx_reset_n = KEY[0] && !muted;

        fade_fsm #(.FADE_IN_DIV(4)) FADE (
            .clk       (CLOCK_50),
            .reset_n   (KEY[0]),
            .sample_en (ADC_Valid[0]),
            .mute_req  (mute_req),
            .ramp_vol  (ramp_vol),
            .muted     (muted),
            .unmuted   (unmuted)
        );

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
            .fx_mix        (params[3][7]),
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
            .clk        (CLOCK_50),
            .reset_n    (fx_reset_n),
            .audio_in   (delay_out),
            .audio_out  (reverb_out),
            .flush      (fx_flush),
            .fx_size    (params[9][0]),
            .fx_damping (params[9][1]),
            .fx_decay   (params[9][2]),
            .fx_moddepth(params[9][3]),
            .fx_diffusion(params[9][4]),
            .fx_predelay(params[9][5]),
            .fx_width   (params[9][6]),
            .fx_mix     (params[9][7]),
            .sample_en  (sample_en_pipe[9])
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

        // ---- FX 15: Global Gain (mirrored across all banks) ---------
        // Master volume that's the same regardless of active bank.  The
        // controller writes the same value to every bank's params[15][0]
        // slot, so this read is bank-agnostic.
        fx_gain #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) FX_GLOBAL_GAIN (
            .clk      (CLOCK_50),
            .reset_n  (KEY[0]),
            .audio_in (gain_out_out),
            .audio_out(global_gain_out),
            .fx_gain  (params[15][0]),
            .sample_en(sample_en_pipe[11])
        );

        // ---- DAC Output  (apply ramp_vol) ----------------------------
        // Concatenating 1'b0 prevents the multiplier from misinterpreting
        // ramp_vol = 256 (9'h100) as a negative signed number.
        assign dac_left_scaled  = $signed(global_gain_out[0]) * $signed({1'b0, ramp_vol});
        assign dac_right_scaled = $signed(global_gain_out[1]) * $signed({1'b0, ramp_vol});

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