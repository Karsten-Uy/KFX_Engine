// ============================================================
//  fx_compressor.sv
//
//  Classic feed-forward peak compressor.
//
//  Signal flow:
//    audio_in ──► |peak detect| ──► envelope follower
//                                        │
//                                   threshold compare
//                                        │
//                                  gain_target (Q15)
//                                        │
//                               gain smoother (atk/rel)
//                                        │
//    audio_in ────────────────► multiply by gain_smooth ──► audio_out
//
//  Parameter map  (PARAM_W = 8, range 0x00..0xFF)
//  ──────────────────────────────────────────────
//  fx_threshold : linear amplitude threshold
//                 0x00 = near-silence, 0xFF = full-scale
//                 threshold_lin = fx_threshold << (DATA_W - PARAM_W)
//
//  fx_ratio     : top 3 bits → ratio_shift 0..7
//                 0 → 1:1 (bypass)  1 → 2:1  ... 7 → 128:1
//
//  fx_attack    : top 4 bits | 1 → atk_shift 1..15
//                 small value = fast attack (gain clamps quickly)
//
//  fx_release   : top 4 bits | 1 → rel_shift 1..15
//                 small value = fast release (gain recovers quickly)
//
//  Implementation notes
//  ─────────────────────
//  • Gain is expressed in Q(DATA_W-1) = Q15 format: 0x7FFF ≈ 1.0, 0x0000 = 0.0
//  • The one combinational division ((comp_level << 15) / env) produces a
//    standard divider in Quartus; at 50 MHz with ~1 000 cycles/sample it
//    comfortably meets timing.
//  • Both stereo channels share one sidechain (peak of L/R) and one gain
//    coefficient, keeping L/R in balance under compression.
// ============================================================

module fx_compressor #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                          clk,
    input  logic                          reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,
    output logic signed [1:0][DATA_W-1:0] audio_out,
    input  logic [PARAM_W-1:0]            fx_threshold,
    input  logic [PARAM_W-1:0]            fx_ratio,
    input  logic [PARAM_W-1:0]            fx_attack,
    input  logic [PARAM_W-1:0]            fx_release,
    input  logic                          sample_en
);

    // ─── Local constants ────────────────────────────────────────
    localparam GAIN_W = DATA_W;           // Q(GAIN_W-1) gain word (Q15 for DATA_W=16)
    localparam PROD_W = DATA_W + GAIN_W;  // multiply result width (32-bit)

    // Maximum unity gain in Q15 (0x7FFF ≈ 1.0)
    localparam logic [GAIN_W-1:0] GAIN_UNITY = {1'b0, {(GAIN_W-1){1'b1}}};

    // ─── Decode parameters ──────────────────────────────────────
    //  threshold_lin  16-bit unsigned, same scale as |audio|
    //  ratio_shift    0..7   (power-of-2 ratios: 1:1 → 128:1)
    //  atk_shift      1..15  (OR with 1 prevents shift-by-0 = instant jump)
    //  rel_shift      1..15
    logic [DATA_W-1:0] threshold_lin;
    logic [2:0]        ratio_shift;
    logic [3:0]        atk_shift;
    logic [3:0]        rel_shift;

    assign threshold_lin = {fx_threshold, {(DATA_W - PARAM_W){1'b0}}};
    assign ratio_shift   = fx_ratio [PARAM_W-1 -: 3];
    assign atk_shift     = fx_attack [PARAM_W-1 -: 4] | 4'd1;
    assign rel_shift     = fx_release[PARAM_W-1 -: 4] | 4'd1;

    // ─── Absolute value / peak detector ─────────────────────────
    //  Takes the louder of the two channels as the sidechain signal.
    //  Handles the two's-complement minimum (-32768) safely.
    logic [DATA_W-1:0] abs_l, abs_r, peak;

    always_comb begin : abs_and_peak
        // Left channel
        if (audio_in[0][DATA_W-1])
            // negative: negate; clamp min-int to max-positive
            abs_l = (audio_in[0] == {1'b1, {(DATA_W-1){1'b0}}})
                    ? {(DATA_W-1){1'b1}}
                    : DATA_W'(-audio_in[0]);
        else
            abs_l = DATA_W'(audio_in[0]);

        // Right channel
        if (audio_in[1][DATA_W-1])
            abs_r = (audio_in[1] == {1'b1, {(DATA_W-1){1'b0}}})
                    ? {(DATA_W-1){1'b1}}
                    : DATA_W'(-audio_in[1]);
        else
            abs_r = DATA_W'(audio_in[1]);

        peak = (abs_l > abs_r) ? abs_l : abs_r;
    end

    // ─── Envelope follower ───────────────────────────────────────
    //  Exponential attack / release using bit-shift coefficients.
    //  env ← env + (peak − env) >> atk_shift   (when peak > env)
    //  env ← env − (env − peak) >> rel_shift   (when peak < env)
    //
    //  Effective time constant τ ≈ (2^shift) / fs
    //  At fs = 48 kHz, shift=1 → ~21 µs, shift=15 → ~0.68 s
    logic [DATA_W-1:0] env;

    always_ff @(posedge clk or negedge reset_n) begin : envelope_ff
        if (!reset_n) begin
            env <= '0;
        end else if (sample_en) begin
            if (peak > env)
                env <= env + ((peak - env) >> atk_shift);
            else
                env <= env - ((env - peak) >> rel_shift);
        end
    end

    // ─── Target gain computation (combinatorial) ─────────────────
    //  Runs from the env register updated on the *previous* sample_en,
    //  so results are stable well before the next sample_en edge.
    //
    //  If env > threshold:
    //    excess       = env − threshold
    //    comp_level   = threshold + (excess >> ratio_shift)   ← compressed level
    //    gain_target  = (comp_level << 15) / env              ← Q15 gain
    //  Else:
    //    gain_target  = GAIN_UNITY (0x7FFF)
    //
    //  Division note: comp_level ≤ env always, so result ≤ 0x7FFF.
    //  Numerator max: 65535 × 32768 = 2^31 – 32768  (fits in PROD_W=32 bits)
    logic [DATA_W-1:0] excess_env;
    logic [DATA_W-1:0] comp_level;
    logic [PROD_W-1:0] numerator;
    logic [GAIN_W-1:0] gain_target;

    always_comb begin : gain_compute
        if (env == '0 || env <= threshold_lin) begin
            // Signal below threshold: unity gain
            excess_env  = '0;
            comp_level  = '0;
            numerator   = '0;
            gain_target = GAIN_UNITY;
        end else begin
            excess_env  = env - threshold_lin;
            comp_level  = threshold_lin + (excess_env >> ratio_shift);
            numerator   = PROD_W'(comp_level) << (GAIN_W - 1);  // << 15
            gain_target = GAIN_W'(numerator / PROD_W'(env));
        end
    end

    // ─── Gain smoother ───────────────────────────────────────────
    //  Applies separate time constants to gain changes:
    //    gain_target < gain_smooth  → reducing gain  (attack  path, fast)
    //    gain_target > gain_smooth  → recovering gain (release path, slow)
    //
    //  This mirrors the attack/release semantics of the envelope follower
    //  but operates on the gain word in Q15 space.
    logic [GAIN_W-1:0] gain_smooth;

    always_ff @(posedge clk or negedge reset_n) begin : gain_smooth_ff
        if (!reset_n) begin
            gain_smooth <= GAIN_UNITY;
        end else if (sample_en) begin
            if (gain_target < gain_smooth)
                // Compress: fast attack → gain clamps quickly
                gain_smooth <= gain_smooth
                               - ((gain_smooth - gain_target) >> atk_shift);
            else
                // Recover: slow release → gain comes back gradually
                gain_smooth <= gain_smooth
                               + ((gain_target - gain_smooth) >> rel_shift);
        end
    end

    // ─── Apply gain ──────────────────────────────────────────────
    //  audio_out = audio_in × (gain_smooth / 2^(GAIN_W-1))
    //
    //  prod = signed(audio_in) × signed({0, gain_smooth})   [PROD_W bits]
    //  out  = prod >>> (GAIN_W-1)                           [DATA_W bits]
    //
    //  Overflow proof (DATA_W=16):
    //    |audio_in| ≤ 32768, gain_smooth ≤ 32767
    //    |prod|     ≤ 32768 × 32767 < 2^30  →  fits in 31 bits + sign = 32 bits
    //    |out|      ≤ 32768 × 32767 / 32768 < 32768  →  fits in 16-bit signed ✓
    logic signed [PROD_W-1:0] prod_l, prod_r;

    always_ff @(posedge clk or negedge reset_n) begin : apply_gain_ff
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            prod_l = $signed(audio_in[0]) * $signed({1'b0, gain_smooth});
            prod_r = $signed(audio_in[1]) * $signed({1'b0, gain_smooth});
            // Arithmetic shift right by 15; truncate to DATA_W (safe, no overflow)
            audio_out[0] <= DATA_W'(prod_l >>> (GAIN_W - 1));
            audio_out[1] <= DATA_W'(prod_r >>> (GAIN_W - 1));
        end
    end

endmodule