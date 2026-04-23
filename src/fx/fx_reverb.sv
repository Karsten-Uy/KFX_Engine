/*
 * fx_reverb.sv
 *
 * Stereo Schroeder reverberator: parallel damped comb filters into series
 * all-pass filters.
 *
 * Architecture
 * ------------
 * Stage 1 — Four parallel damped feedback comb filters per channel.
 *   Each comb filter embeds a one-pole IIR low-pass in its feedback path
 *   (the classic Schroeder/Moorer structure): high frequencies decay faster
 *   than lows, mimicking natural room acoustics.
 *
 *   Per-filter equations (run every sample_en):
 *     lp[n] = lp[n-1] + (lp_coef * ((delayed[n] << LP_FRAC_BITS) - lp[n-1])) >> 8
 *     fb[n] = (lp[n] >> LP_FRAC_BITS) * FIXED_FB_GAIN / 256
 *     x_in  = audio_in + fb[n]            (fed into the delay line)
 *
 *   lp is 32-bit Q16 to preserve sub-LSB energy so the tail fades smoothly
 *   through the noise floor rather than snapping to zero at 16-bit boundaries.
 *
 *   lp_coef = max(16, 256 − fx_damping):
 *     fx_damping = 0   → lp_coef = 256 → LP fully open  (bright)
 *     fx_damping = 240 → lp_coef = 16  → LP narrow      (dark, clamped minimum)
 *
 *   FIXED_FB_GAIN = 236 / 256 ≈ 0.922 → RT60 ≈ 7–8 s at max delay.
 *   The LP cutoff governs tonal character; FIXED_FB_GAIN sets decay length.
 *   No combination of fx_damping can raise the loop gain to unity — the tail
 *   always terminates.
 *
 * Stage 2 — Three series all-pass filters per channel.
 *   Diffuse the comb output without altering the frequency magnitude response.
 *   g = 0.5  (ALLPASS_COEF = 128):
 *     y[n] = −g·x[n] + x[n−d] + g·y[n−d]
 *
 * Comb filter delays  (prime numbers avoid modal resonances)
 * ----------------------------------------------------------
 *   Comb 1: 1557 samples (~32 ms)    Comb 2: 1617 samples (~34 ms)
 *   Comb 3: 1871 samples (~39 ms)    Comb 4: 1997 samples (~42 ms)
 *   fx_size scales all four: delay = base × (1 + fx_size/256)
 *   Maximum delay at fx_size=255: base × 2  → MAX_COMB_DELAY = 3994
 *
 * All-pass delays  (fixed)
 * ------------------------
 *   Allpass 1: 556 samples (~12 ms)
 *   Allpass 2: 441 samples (~9 ms)
 *   Allpass 3: 341 samples (~7 ms)
 *
 * Latency: 5 samples.
 *
 * Parameter mapping  (all 8-bit, 0–255)
 * --------------------------------------
 *   fx_size    — room size / decay time  (scales all comb delays)
 *   fx_damping — HF damping              (0 = bright, 255 = dark)
 *   fx_mix     — dry/wet blend           (0 = dry, 255 = full wet)
 *
 * Ports
 * -----
 *   audio_in  — stereo signed 16-bit input
 *   audio_out — stereo signed 16-bit output
 *   sample_en — single-cycle sample strobe
 */

module fx_reverb #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                          clk,
    input  logic                          reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,
    output logic signed [1:0][DATA_W-1:0] audio_out,
    input  logic [PARAM_W-1:0]            fx_size,
    input  logic [PARAM_W-1:0]            fx_damping,
    input  logic [PARAM_W-1:0]            fx_mix,
    input  logic                          sample_en
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Local Constants  (reverb algorithm — not shared with other modules)
    // ----------------------------------------------------------------

    // Comb filter base delays in samples at 48 kHz (prime to avoid resonances)
    localparam COMB1_BASE = 1557;  // ~32 ms
    localparam COMB2_BASE = 1617;  // ~34 ms
    localparam COMB3_BASE = 1871;  // ~39 ms
    localparam COMB4_BASE = 1997;  // ~42 ms

    // All-pass filter delays (fixed — not modulated by fx_size)
    localparam ALLPASS1_DELAY = 556;   // ~12 ms
    localparam ALLPASS2_DELAY = 441;   // ~9 ms
    localparam ALLPASS3_DELAY = 341;   // ~7 ms

    // Buffer sizes: at fx_size=255, comb delay ≈ base × 2
    localparam MAX_COMB_DELAY = 3994;
    localparam COMB_ADDR_W    = $clog2(MAX_COMB_DELAY);
    localparam ALLPASS_ADDR_W = $clog2(ALLPASS1_DELAY);  // largest all-pass delay

    // All-pass coefficient g = 0.5 (128/256); fixed for stability
    localparam ALLPASS_COEF = 8'd128;

    // Fixed feedback gain: 236/256 ≈ 0.922
    // Higher than the previous 220/256 for a longer, smoother exponential tail.
    localparam FIXED_FB_GAIN = 9'sd236;

    // LP state is Q16; this is the fractional shift applied before/after LP update
    localparam LP_FRAC_BITS = 16;

    // ----------------------------------------------------------------
    // Shared Delay Calculations
    // ----------------------------------------------------------------

    logic [COMB_ADDR_W-1:0] comb1_delay, comb2_delay, comb3_delay, comb4_delay;

    // LP coefficient — controls HF decay rate; clamped to minimum 16 so the
    // tail always bleeds through rather than hard-gating at maximum fx_damping
    logic [8:0] lp_coef;

    // ----------------------------------------------------------------
    // Per-Channel Comb Filter Signals
    // ----------------------------------------------------------------

    // LEFT channel
    logic signed [DATA_W-1:0]   comb1L_out,     comb2L_out,     comb3L_out,     comb4L_out;
    logic signed [DATA_W-1:0]   comb1L_delayed, comb2L_delayed, comb3L_delayed, comb4L_delayed;
    logic signed [DATA_W-1:0]   comb1L_in,      comb2L_in,      comb3L_in,      comb4L_in;
    logic signed [31:0]         comb1L_fb,      comb2L_fb,      comb3L_fb,      comb4L_fb;
    logic signed [DATA_W+1:0]   comb_sum_L;
    logic signed [31:0]         comb1L_lp, comb2L_lp, comb3L_lp, comb4L_lp;  // Q16 LP state

    // RIGHT channel
    logic signed [DATA_W-1:0]   comb1R_out,     comb2R_out,     comb3R_out,     comb4R_out;
    logic signed [DATA_W-1:0]   comb1R_delayed, comb2R_delayed, comb3R_delayed, comb4R_delayed;
    logic signed [DATA_W-1:0]   comb1R_in,      comb2R_in,      comb3R_in,      comb4R_in;
    logic signed [31:0]         comb1R_fb,      comb2R_fb,      comb3R_fb,      comb4R_fb;
    logic signed [DATA_W+1:0]   comb_sum_R;
    logic signed [31:0]         comb1R_lp, comb2R_lp, comb3R_lp, comb4R_lp;  // Q16 LP state

    // ----------------------------------------------------------------
    // Per-Channel All-Pass Filter Signals
    // ----------------------------------------------------------------

    // LEFT channel
    logic signed [DATA_W-1:0] allpass1L_in,  allpass1L_out,  allpass1L_delayed;
    logic signed [DATA_W-1:0] allpass2L_in,  allpass2L_out,  allpass2L_delayed;
    logic signed [DATA_W-1:0] allpass3L_in,  allpass3L_out,  allpass3L_delayed;
    logic signed [31:0]       ap1L_feed, ap1L_back;
    logic signed [31:0]       ap2L_feed, ap2L_back;
    logic signed [31:0]       ap3L_feed, ap3L_back;

    // RIGHT channel
    logic signed [DATA_W-1:0] allpass1R_in,  allpass1R_out,  allpass1R_delayed;
    logic signed [DATA_W-1:0] allpass2R_in,  allpass2R_out,  allpass2R_delayed;
    logic signed [DATA_W-1:0] allpass3R_in,  allpass3R_out,  allpass3R_delayed;
    logic signed [31:0]       ap1R_feed, ap1R_back;
    logic signed [31:0]       ap2R_feed, ap2R_back;
    logic signed [31:0]       ap3R_feed, ap3R_back;

    // ----------------------------------------------------------------
    // Final Mix
    // ----------------------------------------------------------------

    logic signed [DATA_W-1:0] wet_L, wet_R;
    logic signed [31:0]       mixed_L,      mixed_R;
    logic signed [31:0]       wet_scaled_L, wet_scaled_R;  // (wet - dry) before mix multiply

    // ----------------------------------------------------------------
    // Delay Line Instantiation — Comb Filters (8 total: 4L + 4R)
    // ----------------------------------------------------------------

    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W))
    COMB1_L (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
             .data_in(comb1L_in), .data_out(comb1L_delayed), .delay_samples(comb1_delay));
    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W))
    COMB2_L (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
             .data_in(comb2L_in), .data_out(comb2L_delayed), .delay_samples(comb2_delay));
    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W))
    COMB3_L (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
             .data_in(comb3L_in), .data_out(comb3L_delayed), .delay_samples(comb3_delay));
    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W))
    COMB4_L (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
             .data_in(comb4L_in), .data_out(comb4L_delayed), .delay_samples(comb4_delay));

    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W))
    COMB1_R (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
             .data_in(comb1R_in), .data_out(comb1R_delayed), .delay_samples(comb1_delay));
    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W))
    COMB2_R (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
             .data_in(comb2R_in), .data_out(comb2R_delayed), .delay_samples(comb2_delay));
    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W))
    COMB3_R (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
             .data_in(comb3R_in), .data_out(comb3R_delayed), .delay_samples(comb3_delay));
    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W))
    COMB4_R (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
             .data_in(comb4R_in), .data_out(comb4R_delayed), .delay_samples(comb4_delay));

    // ----------------------------------------------------------------
    // Delay Line Instantiation — All-Pass Filters (6 total: 3L + 3R)
    // ----------------------------------------------------------------

    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS1_DELAY), .ADDR_W(ALLPASS_ADDR_W))
    ALLPASS1_L (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
                .data_in(allpass1L_in), .data_out(allpass1L_delayed),
                .delay_samples(ALLPASS1_DELAY[ALLPASS_ADDR_W-1:0]));
    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS2_DELAY), .ADDR_W(ALLPASS_ADDR_W))
    ALLPASS2_L (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
                .data_in(allpass2L_in), .data_out(allpass2L_delayed),
                .delay_samples(ALLPASS2_DELAY[ALLPASS_ADDR_W-1:0]));
    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS3_DELAY), .ADDR_W(ALLPASS_ADDR_W))
    ALLPASS3_L (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
                .data_in(allpass3L_in), .data_out(allpass3L_delayed),
                .delay_samples(ALLPASS3_DELAY[ALLPASS_ADDR_W-1:0]));

    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS1_DELAY), .ADDR_W(ALLPASS_ADDR_W))
    ALLPASS1_R (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
                .data_in(allpass1R_in), .data_out(allpass1R_delayed),
                .delay_samples(ALLPASS1_DELAY[ALLPASS_ADDR_W-1:0]));
    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS2_DELAY), .ADDR_W(ALLPASS_ADDR_W))
    ALLPASS2_R (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
                .data_in(allpass2R_in), .data_out(allpass2R_delayed),
                .delay_samples(ALLPASS2_DELAY[ALLPASS_ADDR_W-1:0]));
    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS3_DELAY), .ADDR_W(ALLPASS_ADDR_W))
    ALLPASS3_R (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
                .data_in(allpass3R_in), .data_out(allpass3R_delayed),
                .delay_samples(ALLPASS3_DELAY[ALLPASS_ADDR_W-1:0]));

    // ----------------------------------------------------------------
    // Comb Delay Calculation  (combinational, shared L+R)
    // ----------------------------------------------------------------

    always_comb begin
        comb1_delay = COMB1_BASE + ((COMB1_BASE * fx_size) >> 8);
        comb2_delay = COMB2_BASE + ((COMB2_BASE * fx_size) >> 8);
        comb3_delay = COMB3_BASE + ((COMB3_BASE * fx_size) >> 8);
        comb4_delay = COMB4_BASE + ((COMB4_BASE * fx_size) >> 8);
    end

    // LP coefficient: 256 − fx_damping, clamped to minimum 16
    always_comb begin
        lp_coef = (9'd256 - {1'b0, fx_damping} < 9'd16)
                  ? 9'd16
                  : 9'd256 - {1'b0, fx_damping};
    end

    // ----------------------------------------------------------------
    // One-Pole LP State Update  (registered, Q16)
    //
    // lp[n] = lp[n-1] + ((delta * lp_coef) >>> 8)
    // where delta = (delayed << LP_FRAC_BITS) - lp
    //
    // delta can reach ±0x7FFF_0000 (31-bit); delta * lp_coef (max 256) needs
    // 41 bits.  Cast to 48-bit before multiplying to prevent silent wrap.
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            comb1L_lp <= '0;  comb2L_lp <= '0;  comb3L_lp <= '0;  comb4L_lp <= '0;
            comb1R_lp <= '0;  comb2R_lp <= '0;  comb3R_lp <= '0;  comb4R_lp <= '0;
        end else if (sample_en) begin
            // LEFT
            comb1L_lp <= comb1L_lp + 32'(48'($signed(($signed(comb1L_delayed) <<< LP_FRAC_BITS) - comb1L_lp))
                          * 48'($signed({1'b0, lp_coef})) >>> 8);
            comb2L_lp <= comb2L_lp + 32'(48'($signed(($signed(comb2L_delayed) <<< LP_FRAC_BITS) - comb2L_lp))
                          * 48'($signed({1'b0, lp_coef})) >>> 8);
            comb3L_lp <= comb3L_lp + 32'(48'($signed(($signed(comb3L_delayed) <<< LP_FRAC_BITS) - comb3L_lp))
                          * 48'($signed({1'b0, lp_coef})) >>> 8);
            comb4L_lp <= comb4L_lp + 32'(48'($signed(($signed(comb4L_delayed) <<< LP_FRAC_BITS) - comb4L_lp))
                          * 48'($signed({1'b0, lp_coef})) >>> 8);
            // RIGHT
            comb1R_lp <= comb1R_lp + 32'(48'($signed(($signed(comb1R_delayed) <<< LP_FRAC_BITS) - comb1R_lp))
                          * 48'($signed({1'b0, lp_coef})) >>> 8);
            comb2R_lp <= comb2R_lp + 32'(48'($signed(($signed(comb2R_delayed) <<< LP_FRAC_BITS) - comb2R_lp))
                          * 48'($signed({1'b0, lp_coef})) >>> 8);
            comb3R_lp <= comb3R_lp + 32'(48'($signed(($signed(comb3R_delayed) <<< LP_FRAC_BITS) - comb3R_lp))
                          * 48'($signed({1'b0, lp_coef})) >>> 8);
            comb4R_lp <= comb4R_lp + 32'(48'($signed(($signed(comb4R_delayed) <<< LP_FRAC_BITS) - comb4R_lp))
                          * 48'($signed({1'b0, lp_coef})) >>> 8);
        end
    end

    // ----------------------------------------------------------------
    // Comb Filter Combinational Logic  (feedback from LP state)
    //
    // LP state is Q16, so shift right by LP_FRAC_BITS to recover the
    // 16-bit signal value before applying FIXED_FB_GAIN.
    // ----------------------------------------------------------------

    always_comb begin
        // LEFT
        comb1L_fb = ((comb1L_lp >>> LP_FRAC_BITS) * FIXED_FB_GAIN) >>> 8;
        comb2L_fb = ((comb2L_lp >>> LP_FRAC_BITS) * FIXED_FB_GAIN) >>> 8;
        comb3L_fb = ((comb3L_lp >>> LP_FRAC_BITS) * FIXED_FB_GAIN) >>> 8;
        comb4L_fb = ((comb4L_lp >>> LP_FRAC_BITS) * FIXED_FB_GAIN) >>> 8;
        comb1L_in = sat16($signed(audio_in[0]) + comb1L_fb);
        comb2L_in = sat16($signed(audio_in[0]) + comb2L_fb);
        comb3L_in = sat16($signed(audio_in[0]) + comb3L_fb);
        comb4L_in = sat16($signed(audio_in[0]) + comb4L_fb);
        comb1L_out = comb1L_delayed;
        comb2L_out = comb2L_delayed;
        comb3L_out = comb3L_delayed;
        comb4L_out = comb4L_delayed;
        comb_sum_L = $signed(comb1L_out) + $signed(comb2L_out) +
                     $signed(comb3L_out) + $signed(comb4L_out);

        // RIGHT
        comb1R_fb = ((comb1R_lp >>> LP_FRAC_BITS) * FIXED_FB_GAIN) >>> 8;
        comb2R_fb = ((comb2R_lp >>> LP_FRAC_BITS) * FIXED_FB_GAIN) >>> 8;
        comb3R_fb = ((comb3R_lp >>> LP_FRAC_BITS) * FIXED_FB_GAIN) >>> 8;
        comb4R_fb = ((comb4R_lp >>> LP_FRAC_BITS) * FIXED_FB_GAIN) >>> 8;
        comb1R_in = sat16($signed(audio_in[1]) + comb1R_fb);
        comb2R_in = sat16($signed(audio_in[1]) + comb2R_fb);
        comb3R_in = sat16($signed(audio_in[1]) + comb3R_fb);
        comb4R_in = sat16($signed(audio_in[1]) + comb4R_fb);
        comb1R_out = comb1R_delayed;
        comb2R_out = comb2R_delayed;
        comb3R_out = comb3R_delayed;
        comb4R_out = comb4R_delayed;
        comb_sum_R = $signed(comb1R_out) + $signed(comb2R_out) +
                     $signed(comb3R_out) + $signed(comb4R_out);
    end

    // ----------------------------------------------------------------
    // All-Pass Filters  (series, 3 per channel)
    //
    // Equation: y[n] = −g·x[n] + x[n−d] + g·y[n−d]
    // g = ALLPASS_COEF / 256 = 0.5
    // The comb sum is divided by 4 before entering the all-pass chain
    // to prevent accumulation of the four parallel comb outputs from
    // overloading the 16-bit range.
    // ----------------------------------------------------------------

    // LEFT channel
    always_comb begin
        allpass1L_in  = sat16(comb_sum_L >>> 2);
        ap1L_feed     = ($signed(allpass1L_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap1L_back     = ($signed(allpass1L_delayed) * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass1L_out = sat16(-ap1L_feed + $signed(allpass1L_delayed) + ap1L_back);

        allpass2L_in  = allpass1L_out;
        ap2L_feed     = ($signed(allpass2L_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap2L_back     = ($signed(allpass2L_delayed) * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass2L_out = sat16(-ap2L_feed + $signed(allpass2L_delayed) + ap2L_back);

        allpass3L_in  = allpass2L_out;
        ap3L_feed     = ($signed(allpass3L_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap3L_back     = ($signed(allpass3L_delayed) * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass3L_out = sat16(-ap3L_feed + $signed(allpass3L_delayed) + ap3L_back);
    end

    // RIGHT channel
    always_comb begin
        allpass1R_in  = sat16(comb_sum_R >>> 2);
        ap1R_feed     = ($signed(allpass1R_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap1R_back     = ($signed(allpass1R_delayed) * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass1R_out = sat16(-ap1R_feed + $signed(allpass1R_delayed) + ap1R_back);

        allpass2R_in  = allpass1R_out;
        ap2R_feed     = ($signed(allpass2R_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap2R_back     = ($signed(allpass2R_delayed) * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass2R_out = sat16(-ap2R_feed + $signed(allpass2R_delayed) + ap2R_back);

        allpass3R_in  = allpass2R_out;
        ap3R_feed     = ($signed(allpass3R_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap3R_back     = ($signed(allpass3R_delayed) * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass3R_out = sat16(-ap3R_feed + $signed(allpass3R_delayed) + ap3R_back);
    end

    // ----------------------------------------------------------------
    // Mix  (wet/dry blend)
    //
    // Wet/dry mix: dry + (wet - dry) * mix / 256
    // mix=0 → full dry, mix=255 → 99.6% wet
    // ----------------------------------------------------------------

    always_comb begin
        wet_L = allpass3L_out;
        wet_R = allpass3R_out;

        wet_scaled_L = $signed(wet_L) - $signed(audio_in[0]);
        wet_scaled_R = $signed(wet_R) - $signed(audio_in[1]);
        mixed_L      = $signed(audio_in[0]) + ((wet_scaled_L * $signed({1'b0, fx_mix})) >>> 8);
        mixed_R      = $signed(audio_in[1]) + ((wet_scaled_R * $signed({1'b0, fx_mix})) >>> 8);
    end

    // ----------------------------------------------------------------
    // Output Register
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) audio_out <= '0;
        else if (sample_en) begin
            audio_out[0] <= sat16(mixed_L);
            audio_out[1] <= sat16(mixed_R);
        end
    end

endmodule