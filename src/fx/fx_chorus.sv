/*
 * fx_chorus.sv
 *
 * Stereo chorus effect: two independent LFO-modulated voices with
 * linear-interpolation delay lines and wet/dry mix.
 *
 * Architecture
 * ------------
 * Two quadrature voices (V1 at 0°, V2 at 90°) modulate independent delay
 * times around fixed base delays, producing a lush stereo spread.  Each
 * voice has separate left and right delay lines, all using delay_line_li
 * for sub-sample interpolation that eliminates the quantisation buzz
 * present in integer-only delay lines.
 *
 * Each voice delay time is smoothed by a low-pass slew accumulator (>>10
 * per sample) to prevent audible clicks on fast LFO rates.
 *
 * LFO
 * ---
 * A 24-bit phase accumulator generates a triangle wave.  Voice 2 uses a
 * 90° phase offset (lfo_phase + 0x400000) for stereo movement.
 * Rate:   lfo_inc = 2 + (fx_rate × 80) >> 8
 * Depth:  mod = (lfo_tri × fx_depth) >> 18
 *
 * Delay constants  (local — chorus-specific tuning, not shared)
 * --------------------------------------------------------------
 *   BASE_DELAY_MS_V1 = 20 ms  → 960 samples @ 48 kHz
 *   BASE_DELAY_MS_V2 = 28 ms  → 1344 samples @ 48 kHz
 *   MAX_DELAY_SAMPLES = 2048
 *
 * Latency: 2 samples (delay_line_li pipeline) + 1 sample (output register).
 *
 * Parameter mapping  (all 8-bit, 0–255)
 * --------------------------------------
 *   fx_rate  — LFO rate    (0 = very slow, 255 = fastest)
 *   fx_depth — modulation depth  (0 = no modulation, 255 = maximum)
 *   fx_mix   — dry/wet blend     (0 = dry, 255 = ~99.6% wet)
 *
 * Ports
 * -----
 *   audio_in  — stereo signed 16-bit input
 *   audio_out — stereo signed 16-bit output
 *   sample_en — single-cycle sample strobe
 */

module fx_chorus #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                          clk,
    input  logic                          reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,
    output logic signed [1:0][DATA_W-1:0] audio_out,
    input  logic [PARAM_W-1:0]            fx_rate,
    input  logic [PARAM_W-1:0]            fx_depth,
    input  logic [PARAM_W-1:0]            fx_mix,
    input  logic                          sample_en
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Local Constants  (chorus-specific, not shared with other modules)
    // ----------------------------------------------------------------

    localparam FRAC_W            = 4;                                        // fractional bits for interpolation
    localparam BASE_DELAY_MS_V1  = 20;
    localparam BASE_DELAY_MS_V2  = 28;
    localparam BASE_DELAY_V1     = (BASE_DELAY_MS_V1 * SAMPLE_RATE) / 1000;  // ~960 samples
    localparam BASE_DELAY_V2     = (BASE_DELAY_MS_V2 * SAMPLE_RATE) / 1000;  // ~1344 samples
    localparam MAX_DELAY_SAMPLES = 2048;
    localparam ADDR_W            = $clog2(MAX_DELAY_SAMPLES);

    // ----------------------------------------------------------------
    // Internal Signals
    // ----------------------------------------------------------------

    logic [23:0] lfo_phase;
    logic [23:0] lfo_inc;
    logic [23:0] ph90;
    logic signed [15:0] lfo_tri_0;
    logic signed [15:0] lfo_tri_90;

    // Voice delay accumulators (Q16.16)
    logic signed [31:0] v1_L_acc, v1_R_acc;
    logic signed [31:0] v2_L_acc, v2_R_acc;

    // Fixed-point delay values passed to delay_line_li  (Q(ADDR_W).(FRAC_W))
    logic [ADDR_W+FRAC_W-1:0] v1_L_fixed, v1_R_fixed;
    logic [ADDR_W+FRAC_W-1:0] v2_L_fixed, v2_R_fixed;

    logic signed [DATA_W-1:0] wet_v1_L, wet_v1_R;
    logic signed [DATA_W-1:0] wet_v2_L, wet_v2_R;

    logic signed [31:0] mod_0, mod_90;
    logic signed [31:0] target_v1L, target_v1R, target_v2L, target_v2R;
    logic signed [1:0][DATA_W-1:0] dry_pipe [3:0];  // aligned with delay_line_li latency

    logic signed [32:0] avg_wet_L, avg_wet_R;
    logic signed [33:0] mix_L, mix_R;

    // ----------------------------------------------------------------
    // Delay Line Instantiation
    //
    // Four independent delay_line_li instances — one per voice per channel.
    // All use linear interpolation to prevent aliasing on the modulated read.
    // ----------------------------------------------------------------

    delay_line_li #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES), .FRAC_W(FRAC_W))
    DL_V1_L (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
             .data_in(audio_in[0]), .data_out(wet_v1_L), .delay_samples(v1_L_fixed));

    delay_line_li #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES), .FRAC_W(FRAC_W))
    DL_V1_R (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
             .data_in(audio_in[1]), .data_out(wet_v1_R), .delay_samples(v1_R_fixed));

    delay_line_li #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES), .FRAC_W(FRAC_W))
    DL_V2_L (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
             .data_in(audio_in[0]), .data_out(wet_v2_L), .delay_samples(v2_L_fixed));

    delay_line_li #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES), .FRAC_W(FRAC_W))
    DL_V2_R (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
             .data_in(audio_in[1]), .data_out(wet_v2_R), .delay_samples(v2_R_fixed));

    // ----------------------------------------------------------------
    // LFO and Modulation  (combinational)
    //
    // Triangle wave: MSB of phase selects inversion.
    // Modulation target = base_delay ± mod, in Q16.16 format.
    // ----------------------------------------------------------------

    assign lfo_inc = 2 + ((fx_rate * 24'd80) >> 8);

    always_comb begin
        ph90 = lfo_phase + 24'h40_0000;

        // Triangle wave: convert 0–2^24 phase to signed triangle
        lfo_tri_0  = lfo_phase[23] ? $signed(~lfo_phase[22:7]) : $signed(lfo_phase[22:7]);
        lfo_tri_90 = ph90[23]      ? $signed(~ph90[22:7])      : $signed(ph90[22:7]);

        mod_0  = ($signed(lfo_tri_0)  * $signed({1'b0, fx_depth})) >>> 18;
        mod_90 = ($signed(lfo_tri_90) * $signed({1'b0, fx_depth})) >>> 18;

        // Shift base delays to Q16.16 before adding modulation
        target_v1L = ($signed(BASE_DELAY_V1) + mod_0)  << 16;
        target_v1R = ($signed(BASE_DELAY_V1) - mod_0)  << 16;
        target_v2L = ($signed(BASE_DELAY_V2) + mod_90) << 16;
        target_v2R = ($signed(BASE_DELAY_V2) - mod_90) << 16;

        // Average the two voices, then blend wet with dry
        avg_wet_L = ($signed(wet_v1_L) + $signed(wet_v2_L)) >>> 1;
        avg_wet_R = ($signed(wet_v1_R) + $signed(wet_v2_R)) >>> 1;

        // Wet/dry mix: dry + (wet - dry) * mix / 256
        // mix=0 → full dry (exact unity), mix=255 → ~99.6% wet
        mix_L = $signed(dry_pipe[3][0]) +
                (((avg_wet_L - $signed(dry_pipe[3][0])) * $signed({1'b0, fx_mix})) >>> 8);
        mix_R = $signed(dry_pipe[3][1]) +
                (((avg_wet_R - $signed(dry_pipe[3][1])) * $signed({1'b0, fx_mix})) >>> 8);
    end

    // ----------------------------------------------------------------
    // Sequential Logic: LFO Advance, Slew, Dry Pipeline, Output
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            lfo_phase <= 0;
            v1_L_acc  <= $signed(BASE_DELAY_V1) << 16;
            v1_R_acc  <= $signed(BASE_DELAY_V1) << 16;
            v2_L_acc  <= $signed(BASE_DELAY_V2) << 16;
            v2_R_acc  <= $signed(BASE_DELAY_V2) << 16;
            audio_out <= '0;
        end else if (sample_en) begin
            lfo_phase <= lfo_phase + lfo_inc;

            // Slew delay accumulators toward targets — prevents clicks on fast LFO
            v1_L_acc <= v1_L_acc + ((target_v1L - v1_L_acc) >>> 10);
            v1_R_acc <= v1_R_acc + ((target_v1R - v1_R_acc) >>> 10);
            v2_L_acc <= v2_L_acc + ((target_v2L - v2_L_acc) >>> 10);
            v2_R_acc <= v2_R_acc + ((target_v2R - v2_R_acc) >>> 10);

            // Extract the ADDR_W + FRAC_W bits that delay_line_li expects
            v1_L_fixed <= v1_L_acc[16+ADDR_W-1 : 16-FRAC_W];
            v1_R_fixed <= v1_R_acc[16+ADDR_W-1 : 16-FRAC_W];
            v2_L_fixed <= v2_L_acc[16+ADDR_W-1 : 16-FRAC_W];
            v2_R_fixed <= v2_R_acc[16+ADDR_W-1 : 16-FRAC_W];

            // Dry pipeline — 4 registers to align with delay_line_li latency
            dry_pipe[0] <= audio_in;
            dry_pipe[1] <= dry_pipe[0];
            dry_pipe[2] <= dry_pipe[1];
            dry_pipe[3] <= dry_pipe[2];

            audio_out[0] <= sat16(mix_L);
            audio_out[1] <= sat16(mix_R);
        end
    end

endmodule