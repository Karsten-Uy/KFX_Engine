/*
 * fx_delay.sv
 *
 * Stereo echo delay with feedback and tap-tempo override.
 *
 * The delay time is derived from fx_time (knob) or tap_samples (footswitch),
 * selected by the tap_active flag from tap_tempo_unit.  Both paths produce
 * the same ADDR_W-bit sample count fed to the delay lines.
 *
 * Knob delay mapping
 * ------------------
 *   scaled_delay = fx_time * DELAY_RANGE / 256
 *   target       = MIN_DELAY_SAMPLES + scaled_delay
 * Clamped to MAX_SAMPLES.
 *
 * Feedback
 * --------
 * The delayed output is mixed back into the input before writing to the
 * delay line.  Feedback is capped at 224/256 ≈ 0.875 to guarantee the
 * signal eventually decays rather than running away.
 *
 * Latency: 2 samples (1 delay-line RAM pipeline + 1 output register).
 *
 * Parameter mapping  (all 8-bit, 0–255)
 * --------------------------------------
 *   fx_time     — delay time  (longer with higher value)
 *   fx_feedback — echo repeats  (0 = single echo, ~230 = near-infinite)
 *   fx_mix      — dry/wet blend (0 = dry, 255 = full wet)
 *
 * Ports
 * -----
 *   audio_in    — stereo signed 16-bit input
 *   audio_out   — stereo signed 16-bit output
 *   tap_samples — delay length in samples from tap_tempo_unit
 *   tap_active  — 1 = use tap_samples instead of the fx_time knob
 *   sample_en   — single-cycle sample strobe
 */

module fx_delay #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                          clk,
    input  logic                          reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,
    output logic signed [1:0][DATA_W-1:0] audio_out,
    input  logic                          flush,
    input  logic [PARAM_W-1:0]            fx_time,
    input  logic [PARAM_W-1:0]            fx_feedback,
    input  logic [PARAM_W-1:0]            fx_mix,
    input  logic                          sample_en,

    input  logic [$clog2(MAX_SAMPLES)-1:0] tap_samples,
    input  logic                           tap_active
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Local Constants
    // ----------------------------------------------------------------

    localparam ADDR_W = $clog2(MAX_SAMPLES);

    // ----------------------------------------------------------------
    // Internal Signals
    // ----------------------------------------------------------------

    logic [ADDR_W-1:0]        target_delay;
    logic signed [DATA_W-1:0] delayed   [1:0];
    logic signed [DATA_W-1:0] fb_in     [1:0];
    logic signed [31:0]       fb_scaled [1:0];
    logic [23:0]              scaled_delay;
    logic [ADDR_W-1:0]        knob_delay;
    logic [23:0]              full_knob_delay;
    logic signed [31:0]       wet_signal [1:0];
    logic signed [31:0]       dry_signal [1:0];
    logic signed [31:0]       mixed      [1:0];
    logic signed [31:0]       raw_fb [1:0];

    // ----------------------------------------------------------------
    // Delay Line Instantiation  (left and right channels independent)
    // ----------------------------------------------------------------

    delay_line #(
        .DATA_W             (DATA_W),
        .MAX_DELAY_SAMPLES  (MAX_SAMPLES),
        .ADDR_W             (ADDR_W)
    ) DELAY_L (
        .clk          (clk),
        .reset_n      (reset_n),
        .sample_en    (sample_en),
        .data_in      (fb_in[0]),
        .data_out     (delayed[0]),
        .delay_samples(target_delay)
    );

    delay_line #(
        .DATA_W             (DATA_W),
        .MAX_DELAY_SAMPLES  (MAX_SAMPLES),
        .ADDR_W             (ADDR_W)
    ) DELAY_R (
        .clk          (clk),
        .reset_n      (reset_n),
        .sample_en    (sample_en),
        .data_in      (fb_in[1]),
        .data_out     (delayed[1]),
        .delay_samples(target_delay)
    );

    // ----------------------------------------------------------------
    // Delay Time Calculation
    //
    // Knob path: fx_time is scaled across [MIN_DELAY_SAMPLES, MAX_SAMPLES].
    // Tap path: tap_samples is used directly when tap_active is asserted.
    // Both channels share a single target_delay for mono delay positioning.
    // ----------------------------------------------------------------

    always_comb begin
        scaled_delay    = fx_time * DELAY_RANGE[14:0];
        
        // Evaluate in 24-bits so it cannot wrap around
        full_knob_delay = MIN_DELAY_SAMPLES + scaled_delay[23:8];

        // Clamp the wide signal safely
        if (full_knob_delay > MAX_SAMPLES)
            knob_delay = MAX_SAMPLES[ADDR_W-1:0];
        else
            knob_delay = full_knob_delay[ADDR_W-1:0];

        target_delay = tap_active ? tap_samples : knob_delay;
    end

    // ----------------------------------------------------------------
    // Feedback and Mix Calculation  (combinational)
    //
    // Feedback is capped at 224/256 ≈ 0.875 to prevent a runaway signal.
    // Mix uses: out = dry + (wet - dry) * fx_mix / 256
    // ----------------------------------------------------------------

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            // 1. Calculate the raw 32-bit feedback value
            raw_fb[i] = $signed(delayed[i]) * $signed({1'b0, fx_feedback}) * 9'sd224;

            // 2. Add 65535 if negative to force rounding towards zero
            fb_scaled[i] = (raw_fb[i] + (raw_fb[i][31] ? 32'sd65535 : 32'sd0)) >>> 16;

            // 3. Add to input and saturate
            fb_in[i]     = flush ? '0 : sat16($signed(audio_in[i]) + fb_scaled[i]);

            // Wet/dry mix (unchanged)
            wet_signal[i] = $signed(delayed[i]);
            dry_signal[i] = $signed(audio_in[i]);
            mixed[i] = dry_signal[i] + (((wet_signal[i] - dry_signal[i])
                       * $signed({1'b0, fx_mix})) >>> 8);
        end
    end

    // ----------------------------------------------------------------
    // Output Register
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            for (int i = 0; i < 2; i++)
                audio_out[i] <= sat16(mixed[i]);
        end
    end

endmodule