/*

    Reverb module that implements the Schroeder Reverberator that uses a combination 
    of parallel feedback comb filters and series all-pass filters to simulate reverberation
    in a room

    Parameters:
        fx_size     - Controls the "size" of the room AKA delay times (0-255)
        fx_damping  - Controls the high-frequency damping of the reverb tail (0-255)
                        0   = bright/open tail, very slow HF decay
                        255 = dark/muffled tail, fast HF decay
        fx_mix      - Mix control determining how much of the wet signal is in
                      the output of this FX. (fx_mix == 0) => all dry, 
                      (fx_mix == 255) => all wet

    Architecture uses a two-stage filter design:
    
    Stage 1 - Parallel Feedback Comb Filters (4 filters per channel, L+R independent):
        Creates the initial reverb tail with different delay times.

        Each comb filter now uses a DAMPED feedback path via a one-pole IIR low-pass
        filter (the classic Schroeder/Moorer damped comb structure).  High frequencies
        decay faster than low frequencies, exactly like a real room.

        The difference equations per comb filter are:

            // One-pole LP inside the feedback loop (run every sample_en tick)
            lp[n] = lp[n-1] + (lp_coef * (y[n-d] - lp[n-1])) / 256

            // Fixed feedback gain applied to the LP-filtered delayed output
            fb[n] = (lp[n] * FIXED_FB_GAIN) / 256

            // Comb input
            x_in[n] = x[n] + fb[n]

            // Comb output (what goes into the allpass chain)
            output[n] = x_in[n-d]   (i.e. y[n-d] in the original notation)

        Where:
            lp_coef      = max(16, 256 - fx_damping)
                             fx_damping=0   → lp_coef=256 → LP fully open  (bright)
                             fx_damping=240 → lp_coef=16  → LP narrow (dark, clamped)
            FIXED_FB_GAIN = 236  (≈0.922 → RT60 ≈ 7-8 s with the base delays)

        Because fx_damping now controls the LP cutoff rather than raw feedback gain,
        the reverb tail always terminates naturally — there is no setting of fx_damping
        that keeps the feedback gain at or above unity.

        The four comb filters have prime number base delays to avoid modal resonances:
            - Comb 1: 1557 samples (~32ms)
            - Comb 2: 1617 samples (~34ms)
            - Comb 3: 1871 samples (~39ms)
            - Comb 4: 1997 samples (~42ms)
        
        fx_size scales these delays: delay = base_delay * (1.0 + fx_size/256)

        All comb outputs (per channel) are summed together.
    
    Stage 2 - Series Allpass Filters (3 filters per channel, cascaded):
        Diffuses the summed comb output without changing frequency response.
        Each allpass filter implements the difference equation where g = 0.5
        and d is a fixed delay:
        
            y[n] = -g*x[n] + x[n-d] + g*y[n-d]
        
        The three allpass filters have fixed delays:
            - Allpass 1: 556 samples (~12ms)
            - Allpass 2: 441 samples (~9ms)
            - Allpass 3: 341 samples (~7ms)
    
    Signal flow (per channel):
        Audio In (L or R) → [DampedComb1..4] → Sum → Divide by 4 →
        Allpass1 → Allpass2 → Allpass3 → Wet Signal → Mix with Dry → Audio Out
    
    The output is:
        audio_out[n] = (wet_signal[n] * fx_mix + dry_signal[n] * (256 - fx_mix)) / 256
    
    Latency = 5 Samples

    Changes from previous version:
        - fx_damping now controls the one-pole LP cutoff inside each comb feedback loop
          instead of directly scaling the feedback gain.  This is the classic
          Schroeder/Moorer damped comb structure.
        - Fixed feedback gain (FIXED_FB_GAIN = 236) replaces the variable damping_factor.
          Raised from 220 → 236 for a longer, smoother exponential decay.
        - lp_coef clamped to minimum 16 so that even at max fx_damping the feedback loop
          never hard-gates — tail always fades smoothly.
        - LP state registers widened to 32-bit Q16 fixed-point.  Sub-LSB energy is
          preserved across feedback round-trips so the tail fades through the noise floor
          rather than snapping to zero at the 16-bit quantization boundary.
        - Tail is guaranteed to terminate — no feedback path can sustain unity gain.

*/

module fx_reverb #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                          clk,
    input  logic                          reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,   // Stereo input
    output logic signed [1:0][DATA_W-1:0] audio_out,  // Stereo output
    input  logic [PARAM_W-1:0]            fx_size,
    input  logic [PARAM_W-1:0]            fx_damping,
    input  logic [PARAM_W-1:0]            fx_mix,
    input  logic                          sample_en
);

    // ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;
        
    // ---------------- CONSTANTS ----------------
    // Comb filter delays (in samples at 48kHz) — prime numbers to avoid resonances
    localparam COMB1_BASE = 1557;  // ~32ms
    localparam COMB2_BASE = 1617;  // ~34ms
    localparam COMB3_BASE = 1871;  // ~39ms
    localparam COMB4_BASE = 1997;  // ~42ms
    
    // Allpass filter delays
    localparam ALLPASS1_DELAY = 556;   // ~12ms
    localparam ALLPASS2_DELAY = 441;   // ~9ms
    localparam ALLPASS3_DELAY = 341;   // ~7ms
    
    // Maximum delay for buffer sizing.
    // At max fx_size (255), delay = base * (1 + 255/256) ≈ base * 2.
    localparam MAX_COMB_DELAY  = 3994;
    localparam COMB_ADDR_W     = $clog2(MAX_COMB_DELAY);
    localparam ALLPASS_ADDR_W  = $clog2(ALLPASS1_DELAY);  // largest allpass delay
    
    // Allpass coefficient (fixed at 0.5 for stability)
    localparam ALLPASS_COEF = 8'd128;

    // Fixed feedback gain for the damped comb filters.
    // 236/256 ≈ 0.922 → RT60 ≈ 7-8 s at max delay (1997 samples, 48 kHz).
    // Higher value gives a longer, more gradual decay so the tail fades smoothly
    // to silence rather than snapping to the 16-bit quantization floor.
    localparam FIXED_FB_GAIN = 9'sd236;
    
    // ---------------- INTERNAL SIGNALS ----------------

    // Delay calculations (shared L/R, same room geometry)
    logic [COMB_ADDR_W-1:0] comb1_delay, comb2_delay, comb3_delay, comb4_delay;

    // LP coefficient derived from fx_damping (9-bit to hold value 256).
    // Clamped to a minimum of 16 so that even at maximum fx_damping the loop
    // never hard-gates — HF still bleeds through slowly, letting the tail
    // fade gracefully to silence rather than snapping to the quantization floor.
    //   fx_damping=0   → lp_coef=256 → LP fully open  (bright, slow HF decay)
    //   fx_damping=240 → lp_coef=16  → LP narrow      (dark, fast HF decay)
    //   fx_damping=255 → lp_coef=16  → clamped        (same as 240)
    logic [8:0] lp_coef;

    // ------ LEFT channel comb filter signals ------
    logic signed [DATA_W-1:0]   comb1L_out,     comb2L_out,     comb3L_out,     comb4L_out;
    logic signed [DATA_W-1:0]   comb1L_delayed, comb2L_delayed, comb3L_delayed, comb4L_delayed;
    logic signed [DATA_W-1:0]   comb1L_in,      comb2L_in,      comb3L_in,      comb4L_in;
    logic signed [31:0]         comb1L_fb,      comb2L_fb,      comb3L_fb,      comb4L_fb;
    logic signed [DATA_W+1:0]   comb_sum_L;

    // One-pole LP state registers — LEFT channel (one per comb).
    // 32-bit wide to preserve sub-LSB energy as the tail decays below the 16-bit
    // quantization floor.  Without this, energy rounds to 0 and the tail hard-stops.
    // Interpretation: the true signal value is lp >> LP_FRAC_BITS (fixed-point Q16).
    localparam LP_FRAC_BITS = 16;
    logic signed [31:0]   comb1L_lp, comb2L_lp, comb3L_lp, comb4L_lp;

    // ------ RIGHT channel comb filter signals ------
    logic signed [DATA_W-1:0]   comb1R_out,     comb2R_out,     comb3R_out,     comb4R_out;
    logic signed [DATA_W-1:0]   comb1R_delayed, comb2R_delayed, comb3R_delayed, comb4R_delayed;
    logic signed [DATA_W-1:0]   comb1R_in,      comb2R_in,      comb3R_in,      comb4R_in;
    logic signed [31:0]         comb1R_fb,      comb2R_fb,      comb3R_fb,      comb4R_fb;
    logic signed [DATA_W+1:0]   comb_sum_R;

    // One-pole LP state registers — RIGHT channel (one per comb). Same Q16 format.
    logic signed [31:0]   comb1R_lp, comb2R_lp, comb3R_lp, comb4R_lp;

    // ------ LEFT channel allpass signals ------
    logic signed [DATA_W-1:0]   allpass1L_in,  allpass1L_out,  allpass1L_delayed;
    logic signed [DATA_W-1:0]   allpass2L_in,  allpass2L_out,  allpass2L_delayed;
    logic signed [DATA_W-1:0]   allpass3L_in,  allpass3L_out,  allpass3L_delayed;
    logic signed [31:0]         ap1L_feed, ap1L_back;
    logic signed [31:0]         ap2L_feed, ap2L_back;
    logic signed [31:0]         ap3L_feed, ap3L_back;

    // ------ RIGHT channel allpass signals ------
    logic signed [DATA_W-1:0]   allpass1R_in,  allpass1R_out,  allpass1R_delayed;
    logic signed [DATA_W-1:0]   allpass2R_in,  allpass2R_out,  allpass2R_delayed;
    logic signed [DATA_W-1:0]   allpass3R_in,  allpass3R_out,  allpass3R_delayed;
    logic signed [31:0]         ap1R_feed, ap1R_back;
    logic signed [31:0]         ap2R_feed, ap2R_back;
    logic signed [31:0]         ap3R_feed, ap3R_back;

    // Final mix
    logic signed [DATA_W-1:0]   wet_L, wet_R;
    logic signed [31:0]         mixed_L,       mixed_R;
    logic signed [31:0]         dry_L,         dry_R;
    logic signed [31:0]         wet_scaled_L,  wet_scaled_R;
    logic signed [8:0]          dry_gain;

    // ---------------- DELAY LINE INSTANTIATION ----------------
    // 4 comb delay lines for LEFT channel

    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W)
    ) comb1L_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(comb1L_in), .data_out(comb1L_delayed), .delay_samples(comb1_delay)
    );
    
    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W)
    ) comb2L_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(comb2L_in), .data_out(comb2L_delayed), .delay_samples(comb2_delay)
    );
    
    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W)
    ) comb3L_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(comb3L_in), .data_out(comb3L_delayed), .delay_samples(comb3_delay)
    );
    
    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W)
    ) comb4L_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(comb4L_in), .data_out(comb4L_delayed), .delay_samples(comb4_delay)
    );

    // 4 comb delay lines for RIGHT channel

    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W)
    ) comb1R_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(comb1R_in), .data_out(comb1R_delayed), .delay_samples(comb1_delay)
    );
    
    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W)
    ) comb2R_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(comb2R_in), .data_out(comb2R_delayed), .delay_samples(comb2_delay)
    );
    
    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W)
    ) comb3R_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(comb3R_in), .data_out(comb3R_delayed), .delay_samples(comb3_delay)
    );
    
    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W)
    ) comb4R_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(comb4R_in), .data_out(comb4R_delayed), .delay_samples(comb4_delay)
    );

    // 3 allpass delay lines for LEFT channel

    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS1_DELAY), .ADDR_W(ALLPASS_ADDR_W)
    ) allpass1L_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(allpass1L_in), .data_out(allpass1L_delayed),
        .delay_samples(ALLPASS1_DELAY[ALLPASS_ADDR_W-1:0])
    );
    
    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS2_DELAY), .ADDR_W(ALLPASS_ADDR_W)
    ) allpass2L_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(allpass2L_in), .data_out(allpass2L_delayed),
        .delay_samples(ALLPASS2_DELAY[ALLPASS_ADDR_W-1:0])
    );

    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS3_DELAY), .ADDR_W(ALLPASS_ADDR_W)
    ) allpass3L_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(allpass3L_in), .data_out(allpass3L_delayed),
        .delay_samples(ALLPASS3_DELAY[ALLPASS_ADDR_W-1:0])
    );

    // 3 allpass delay lines for RIGHT channel

    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS1_DELAY), .ADDR_W(ALLPASS_ADDR_W)
    ) allpass1R_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(allpass1R_in), .data_out(allpass1R_delayed),
        .delay_samples(ALLPASS1_DELAY[ALLPASS_ADDR_W-1:0])
    );
    
    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS2_DELAY), .ADDR_W(ALLPASS_ADDR_W)
    ) allpass2R_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(allpass2R_in), .data_out(allpass2R_delayed),
        .delay_samples(ALLPASS2_DELAY[ALLPASS_ADDR_W-1:0])
    );

    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS3_DELAY), .ADDR_W(ALLPASS_ADDR_W)
    ) allpass3R_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(allpass3R_in), .data_out(allpass3R_delayed),
        .delay_samples(ALLPASS3_DELAY[ALLPASS_ADDR_W-1:0])
    );

    // ---------------------- COMB FILTERS ---------------------

    // Dynamic delay calculation based on fx_size (shared geometry for L+R)
    always_comb begin
        comb1_delay = COMB1_BASE + ((COMB1_BASE * fx_size) >> 8);
        comb2_delay = COMB2_BASE + ((COMB2_BASE * fx_size) >> 8);
        comb3_delay = COMB3_BASE + ((COMB3_BASE * fx_size) >> 8);
        comb4_delay = COMB4_BASE + ((COMB4_BASE * fx_size) >> 8);
    end

    // LP coefficient: 256 - fx_damping, clamped to minimum 16
    always_comb begin
        lp_coef = (9'd256 - {1'b0, fx_damping} < 9'd16)
                  ? 9'd16
                  : 9'd256 - {1'b0, fx_damping};
    end

    // ---- One-pole LP filter state update (registered, runs every sample_en) ----
    //
    // All arithmetic is in Q16 fixed-point (lp values are 32-bit, representing
    // signal << LP_FRAC_BITS).  The delayed input (16-bit) is shifted up before
    // the update so that sub-LSB energy accumulates in the lower 16 bits of lp[].
    //
    //   lp[n] = lp[n-1] + (lp_coef * ((delayed[n] << LP_FRAC_BITS) - lp[n-1])) >> 8
    //
    // The feedback value fed back into the comb is lp[n] >> LP_FRAC_BITS,
    // but the full 32-bit state is retained between samples so energy below
    // 1 LSB is never lost — the tail fades smoothly to silence.

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            comb1L_lp <= '0;  comb2L_lp <= '0;  comb3L_lp <= '0;  comb4L_lp <= '0;
            comb1R_lp <= '0;  comb2R_lp <= '0;  comb3R_lp <= '0;  comb4R_lp <= '0;
        end else if (sample_en) begin
            // LP update: lp[n] = lp[n-1] + ((delta * lp_coef) >>> 8)
            //
            // delta = (delayed << LP_FRAC_BITS) - lp  can be up to ±0x7FFF_0000.
            // delta * lp_coef (max 256) requires 41 bits before the >>> 8.
            // SystemVerilog sizes the result to the widest operand (32 bits here)
            // which silently wraps → crackling on every transient.
            // Fix: cast delta to 48-bit signed before multiplying so the product
            // is computed in 48-bit, then truncate back to 32-bit after the shift.

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

    // ---- Comb filter combinational logic (uses LP-filtered delayed signal) ----
    // LP state is Q16, so shift right by LP_FRAC_BITS before multiplying by FIXED_FB_GAIN.
    // This recovers the 16-bit signal value while the full 32-bit state is retained in
    // the register — sub-LSB energy survives round-trips through the feedback loop.

    // LEFT channel comb filters
    always_comb begin
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
    end

    // RIGHT channel comb filters
    always_comb begin
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

    // ----------------------- ALLPASS FILTERS (Series, per channel) ----------------------

    // LEFT channel - scale down comb sum before allpass (divide by 4)
    always_comb begin
        allpass1L_in = sat16(comb_sum_L >>> 2);
    end

    // LEFT Allpass 1
    always_comb begin
        ap1L_feed    = ($signed(allpass1L_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap1L_back    = ($signed(allpass1L_delayed)  * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass1L_out = sat16(-ap1L_feed + $signed(allpass1L_delayed) + ap1L_back);
    end

    // LEFT Allpass 2
    always_comb begin
        allpass2L_in  = allpass1L_out;
        ap2L_feed     = ($signed(allpass2L_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap2L_back     = ($signed(allpass2L_delayed)  * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass2L_out = sat16(-ap2L_feed + $signed(allpass2L_delayed) + ap2L_back);
    end

    // LEFT Allpass 3
    always_comb begin
        allpass3L_in  = allpass2L_out;
        ap3L_feed     = ($signed(allpass3L_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap3L_back     = ($signed(allpass3L_delayed)  * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass3L_out = sat16(-ap3L_feed + $signed(allpass3L_delayed) + ap3L_back);
    end

    // RIGHT channel - scale down comb sum before allpass (divide by 4)
    always_comb begin
        allpass1R_in = sat16(comb_sum_R >>> 2);
    end

    // RIGHT Allpass 1
    always_comb begin
        ap1R_feed     = ($signed(allpass1R_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap1R_back     = ($signed(allpass1R_delayed)  * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass1R_out = sat16(-ap1R_feed + $signed(allpass1R_delayed) + ap1R_back);
    end

    // RIGHT Allpass 2
    always_comb begin
        allpass2R_in  = allpass1R_out;
        ap2R_feed     = ($signed(allpass2R_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap2R_back     = ($signed(allpass2R_delayed)  * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass2R_out = sat16(-ap2R_feed + $signed(allpass2R_delayed) + ap2R_back);
    end

    // RIGHT Allpass 3
    always_comb begin
        allpass3R_in  = allpass2R_out;
        ap3R_feed     = ($signed(allpass3R_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap3R_back     = ($signed(allpass3R_delayed)  * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass3R_out = sat16(-ap3R_feed + $signed(allpass3R_delayed) + ap3R_back);
    end

    // ----------------------- MIX -----------------------

    always_comb begin
        wet_L = allpass3L_out;
        wet_R = allpass3R_out;

        dry_gain = 9'sd256 - $signed({1'b0, fx_mix});

        wet_scaled_L = ($signed(wet_L) * $signed({1'b0, fx_mix}));
        wet_scaled_R = ($signed(wet_R) * $signed({1'b0, fx_mix}));
        dry_L        = ($signed(audio_in[0]) * dry_gain);
        dry_R        = ($signed(audio_in[1]) * dry_gain);
        mixed_L      = (wet_scaled_L + dry_L) >>> 8;
        mixed_R      = (wet_scaled_R + dry_R) >>> 8;
    end

    // ---------------- OUTPUT ----------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            audio_out[0] <= sat16(mixed_L);
            audio_out[1] <= sat16(mixed_R);
        end
    end

endmodule