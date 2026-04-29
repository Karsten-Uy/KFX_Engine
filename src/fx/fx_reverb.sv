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
 *   A first-order DC blocker follows the LP state output in the feedback
 *   path.  This imposes a true zero at DC inside every comb loop, so DC
 *   bias in the input cannot charge the delay line indefinitely.  The
 *   blocker pole sits at fc ≈ 5.5 Hz (R = 32764/32768, τ ≈ 170 ms) —
 *   well below the audible band, so the reverb tail's tonal character is
 *   unchanged.
 *
 *   Pipeline stages per comb (each advances on sample_en):
 *     Cycle N  : LP state update  → comb*_lp   (Q16 register)
 *     Cycle N+1: lp_out capture   → lp_out_*   (integer, Q16 >> LP_FRAC_BITS)
 *     Cycle N+1: DC blocker update→ dc*_x, dc*_y
 *     Cycle N+1: feedback         → dc*_y * FIXED_FB_GAIN >> 8
 *
 *   The one-cycle pipeline gap between LP and DC blocker is inaudible
 *   (20 µs at 48 kHz) and eliminates the combinational loop that would
 *   otherwise form if the DC blocker read lp[n] in the same cycle it
 *   was written.
 *
 *   lp_coef = max(16, 256 − fx_damping):
 *     fx_damping = 0   → lp_coef = 256 → LP fully open  (bright)
 *     fx_damping = 240 → lp_coef = 16  → LP narrow      (dark, clamped)
 *
 *   Comb feedback gain (fb_gain) is selected from four discrete constants
 *   by the upper two bits of fx_decay.  Keeping each branch a constant
 *   lets the synthesizer fold the multiplier into shifts/adds (the way
 *   the old single-literal 9'sd236 did) — a dynamic fb_gain forced full
 *   DSP-block multipliers and routing/timing on those didn't behave the
 *   same way, which broke the audio.
 *
 * Stage 2 — Three series all-pass filters per channel.
 *   g = 0.5 (ALLPASS_COEF = 128):  y[n] = −g·x[n] + x[n−d] + g·y[n−d]
 *
 * Comb filter delays  (prime numbers, avoid modal resonances)
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
 * Decay mapping  (fx_decay[7:6] selects the comb feedback gain)
 * -------------------------------------------------------------
 *   00 → fb = 200/256 ≈ 0.781   short tail   (~1–2 s at max delay)
 *   01 → fb = 220/256 ≈ 0.859   medium       (~3 s)
 *   10 → fb = 236/256 ≈ 0.922   original     (~7–8 s, default behaviour)
 *   11 → fb = 248/256 ≈ 0.969   long         (~15+ s)
 *
 * Parameter mapping  (all 8-bit, 0–255)
 * --------------------------------------
 *   fx_size    — room size               (scales all comb delays)
 *   fx_damping — HF damping              (0 = bright, 255 = dark)
 *   fx_decay   — tail length / RT60      (4 discrete steps via [7:6])
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
    input  logic                          flush,
    input  logic [PARAM_W-1:0]            fx_size,
    input  logic [PARAM_W-1:0]            fx_damping,
    input  logic [PARAM_W-1:0]            fx_decay,
    input  logic [PARAM_W-1:0]            fx_mix,
    input  logic                          sample_en
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Local Constants
    // ----------------------------------------------------------------

    localparam COMB1_BASE = 1557;
    localparam COMB2_BASE = 1617;
    localparam COMB3_BASE = 1871;
    localparam COMB4_BASE = 1997;

    localparam ALLPASS1_DELAY = 556;
    localparam ALLPASS2_DELAY = 441;
    localparam ALLPASS3_DELAY = 341;

    localparam MAX_COMB_DELAY = 3994;
    localparam COMB_ADDR_W    = $clog2(MAX_COMB_DELAY);
    localparam ALLPASS_ADDR_W = $clog2(ALLPASS1_DELAY);

    localparam ALLPASS_COEF  = 8'd128;
    localparam LP_FRAC_BITS  = 16;

    // Four discrete feedback-gain constants selected by fx_decay[7:6].
    // Keeping these as compile-time constants is what lets the synthesizer
    // fold the comb multipliers into shifts/adds — see header comment.
    localparam logic signed [8:0] FB_GAIN_SHORT  = 9'sd200;  // ~0.781
    localparam logic signed [8:0] FB_GAIN_MEDIUM = 9'sd220;  // ~0.859
    localparam logic signed [8:0] FB_GAIN_LONG   = 9'sd236;  // ~0.922 (original)
    localparam logic signed [8:0] FB_GAIN_HUGE   = 9'sd248;  // ~0.969

    // DC blocker: R = 32764/32768 ≈ 0.99988 → fc ≈ 5.5 Hz @ 48 kHz, τ ≈ 170 ms.
    // Increase R toward 32767 for slower/gentler DC clearance if needed.
    localparam DC_BLOCK_SHIFT = 15;
    localparam DC_BLOCK_R     = 32'd32764;

    // ----------------------------------------------------------------
    // Shared Delay & LP Coefficient (combinational)
    // ----------------------------------------------------------------

    logic [COMB_ADDR_W-1:0] comb1_delay, comb2_delay, comb3_delay, comb4_delay;
    logic [8:0]             lp_coef;

    always_comb begin
        comb1_delay = COMB1_BASE + ((COMB1_BASE * fx_size) >> 8);
        comb2_delay = COMB2_BASE + ((COMB2_BASE * fx_size) >> 8);
        comb3_delay = COMB3_BASE + ((COMB3_BASE * fx_size) >> 8);
        comb4_delay = COMB4_BASE + ((COMB4_BASE * fx_size) >> 8);
    end

    always_comb begin
        lp_coef = (9'd256 - {1'b0, fx_damping} < 9'd16)
                  ? 9'd16
                  : 9'd256 - {1'b0, fx_damping};
    end

    // ----------------------------------------------------------------
    // Comb Filter Signals
    // ----------------------------------------------------------------

    // LEFT
    logic signed [DATA_W-1:0]   comb1L_delayed, comb2L_delayed, comb3L_delayed, comb4L_delayed;
    logic signed [DATA_W-1:0]   comb1L_in,      comb2L_in,      comb3L_in,      comb4L_in;
    logic signed [DATA_W-1:0]   comb1L_out,     comb2L_out,     comb3L_out,     comb4L_out;
    // multstyle="logic" forces constant feedback multiplies into ALUTs
    // instead of DSP blocks — the four-case decay structure produces 32
    // constant multipliers and the device only has 87 DSPs total.
    (* multstyle = "logic" *) logic signed [31:0] comb1L_fb, comb2L_fb, comb3L_fb, comb4L_fb;
    logic signed [DATA_W+1:0]   comb_sum_L;
    logic signed [31:0]         comb1L_lp, comb2L_lp, comb3L_lp, comb4L_lp;  // Q16

    // RIGHT
    logic signed [DATA_W-1:0]   comb1R_delayed, comb2R_delayed, comb3R_delayed, comb4R_delayed;
    logic signed [DATA_W-1:0]   comb1R_in,      comb2R_in,      comb3R_in,      comb4R_in;
    logic signed [DATA_W-1:0]   comb1R_out,     comb2R_out,     comb3R_out,     comb4R_out;
    (* multstyle = "logic" *) logic signed [31:0] comb1R_fb, comb2R_fb, comb3R_fb, comb4R_fb;
    logic signed [DATA_W+1:0]   comb_sum_R;
    logic signed [31:0]         comb1R_lp, comb2R_lp, comb3R_lp, comb4R_lp;  // Q16

    // ----------------------------------------------------------------
    // LP Output Pipeline Register  (Stage B)
    //
    // Captures (comb*_lp >>> LP_FRAC_BITS) one cycle after the LP update.
    // The DC blocker reads these registers — never comb*_lp directly —
    // which is what breaks the combinational loop.
    //
    // Signal flow (each arrow = one sample_en clock edge):
    //   comb_delayed → [Stage A] → comb*_lp
    //                                  → [Stage B] → lp_out_*
    //                                                    → [Stage C] → dc*_y
    //                                                                      ↓
    //                              comb_in ← comb_fb ←──────────────────────
    //                                  ↓
    //                           delay_line → comb_delayed   (closes loop)
    //
    // Every segment crossing an arrow is a registered boundary — no
    // combinational cycle exists.
    // ----------------------------------------------------------------

    logic signed [31:0] lp_out_1L, lp_out_2L, lp_out_3L, lp_out_4L;
    logic signed [31:0] lp_out_1R, lp_out_2R, lp_out_3R, lp_out_4R;

    // ----------------------------------------------------------------
    // DC Blocker State  (Stage C)
    //
    // y[n] = x[n] - x[n-1] + (R * y[n-1]) >>> DC_BLOCK_SHIFT
    //   x[n]  = lp_out_*  (Stage B — clean registered value)
    //   dc*_x = previous x
    //   dc*_y = previous HPF output
    //
    // Range: lp_out ≤ ±32767, DC_BLOCK_R = 32764 → product < 2^30, safe in 32-bit signed.
    // ----------------------------------------------------------------

    logic signed [31:0] dc1L_x, dc2L_x, dc3L_x, dc4L_x;
    logic signed [31:0] dc1R_x, dc2R_x, dc3R_x, dc4R_x;
    logic signed [31:0] dc1L_y, dc2L_y, dc3L_y, dc4L_y;
    logic signed [31:0] dc1R_y, dc2R_y, dc3R_y, dc4R_y;

    // ----------------------------------------------------------------
    // All-Pass Filter Signals
    // ----------------------------------------------------------------

    // LEFT
    logic signed [DATA_W-1:0] allpass1L_in,  allpass1L_out,  allpass1L_delayed;
    logic signed [DATA_W-1:0] allpass2L_in,  allpass2L_out,  allpass2L_delayed;
    logic signed [DATA_W-1:0] allpass3L_in,  allpass3L_out,  allpass3L_delayed;
    logic signed [31:0]       ap1L_feed, ap1L_back;
    logic signed [31:0]       ap2L_feed, ap2L_back;
    logic signed [31:0]       ap3L_feed, ap3L_back;

    // RIGHT
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
    logic signed [31:0]       wet_scaled_L, wet_scaled_R;

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
    // Stage A — LP State Update  (registered, Q16)
    //
    // lp[n] = lp[n-1] + ((delta * lp_coef) >>> 8)
    // delta = (delayed << LP_FRAC_BITS) - lp  can reach ±0x7FFF_0000 (31-bit)
    // delta * lp_coef (max 256) needs 41 bits → cast to 48-bit signed first.
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n || flush) begin
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
    // Stage B — LP Output Pipeline  (registered, integer range)
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            lp_out_1L <= '0;  lp_out_2L <= '0;  lp_out_3L <= '0;  lp_out_4L <= '0;
            lp_out_1R <= '0;  lp_out_2R <= '0;  lp_out_3R <= '0;  lp_out_4R <= '0;
        end else if (sample_en) begin
            lp_out_1L <= $signed(comb1L_lp) >>> LP_FRAC_BITS;
            lp_out_2L <= $signed(comb2L_lp) >>> LP_FRAC_BITS;
            lp_out_3L <= $signed(comb3L_lp) >>> LP_FRAC_BITS;
            lp_out_4L <= $signed(comb4L_lp) >>> LP_FRAC_BITS;
            lp_out_1R <= $signed(comb1R_lp) >>> LP_FRAC_BITS;
            lp_out_2R <= $signed(comb2R_lp) >>> LP_FRAC_BITS;
            lp_out_3R <= $signed(comb3R_lp) >>> LP_FRAC_BITS;
            lp_out_4R <= $signed(comb4R_lp) >>> LP_FRAC_BITS;
        end
    end

    // ----------------------------------------------------------------
    // Stage C — DC Blocker Update  (registered)
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n || flush) begin
            dc1L_x <= '0;  dc2L_x <= '0;  dc3L_x <= '0;  dc4L_x <= '0;
            dc1R_x <= '0;  dc2R_x <= '0;  dc3R_x <= '0;  dc4R_x <= '0;
            dc1L_y <= '0;  dc2L_y <= '0;  dc3L_y <= '0;  dc4L_y <= '0;
            dc1R_y <= '0;  dc2R_y <= '0;  dc3R_y <= '0;  dc4R_y <= '0;
        end else if (sample_en) begin
            // LEFT
            dc1L_y <= lp_out_1L - dc1L_x + (($signed(32'(DC_BLOCK_R)) * dc1L_y) >>> DC_BLOCK_SHIFT);
            dc1L_x <= lp_out_1L;
            dc2L_y <= lp_out_2L - dc2L_x + (($signed(32'(DC_BLOCK_R)) * dc2L_y) >>> DC_BLOCK_SHIFT);
            dc2L_x <= lp_out_2L;
            dc3L_y <= lp_out_3L - dc3L_x + (($signed(32'(DC_BLOCK_R)) * dc3L_y) >>> DC_BLOCK_SHIFT);
            dc3L_x <= lp_out_3L;
            dc4L_y <= lp_out_4L - dc4L_x + (($signed(32'(DC_BLOCK_R)) * dc4L_y) >>> DC_BLOCK_SHIFT);
            dc4L_x <= lp_out_4L;
            // RIGHT
            dc1R_y <= lp_out_1R - dc1R_x + (($signed(32'(DC_BLOCK_R)) * dc1R_y) >>> DC_BLOCK_SHIFT);
            dc1R_x <= lp_out_1R;
            dc2R_y <= lp_out_2R - dc2R_x + (($signed(32'(DC_BLOCK_R)) * dc2R_y) >>> DC_BLOCK_SHIFT);
            dc2R_x <= lp_out_2R;
            dc3R_y <= lp_out_3R - dc3R_x + (($signed(32'(DC_BLOCK_R)) * dc3R_y) >>> DC_BLOCK_SHIFT);
            dc3R_x <= lp_out_3R;
            dc4R_y <= lp_out_4R - dc4R_x + (($signed(32'(DC_BLOCK_R)) * dc4R_y) >>> DC_BLOCK_SHIFT);
            dc4R_x <= lp_out_4R;
        end
    end

    // ----------------------------------------------------------------
    // Comb Filter Combinational Logic  (feedback from dc*_y)
    //
    // dc*_y is already in the ±32767 integer range (LP_FRAC_BITS stripped
    // in Stage B), so apply FIXED_FB_GAIN directly.
    // ----------------------------------------------------------------

    // Comb feedback — explicit per-decay-step multiplications so each
    // branch keeps a constant operand and gets constant-folded by the
    // synthesizer (same pattern that worked with the original FIXED
    // literal).  fx_decay[7:6] picks one of the four constants.
    always_comb begin
        case (fx_decay[7:6])
            2'b00: begin
                comb1L_fb = (dc1L_y * FB_GAIN_SHORT) >>> 8;
                comb2L_fb = (dc2L_y * FB_GAIN_SHORT) >>> 8;
                comb3L_fb = (dc3L_y * FB_GAIN_SHORT) >>> 8;
                comb4L_fb = (dc4L_y * FB_GAIN_SHORT) >>> 8;
                comb1R_fb = (dc1R_y * FB_GAIN_SHORT) >>> 8;
                comb2R_fb = (dc2R_y * FB_GAIN_SHORT) >>> 8;
                comb3R_fb = (dc3R_y * FB_GAIN_SHORT) >>> 8;
                comb4R_fb = (dc4R_y * FB_GAIN_SHORT) >>> 8;
            end
            2'b01: begin
                comb1L_fb = (dc1L_y * FB_GAIN_MEDIUM) >>> 8;
                comb2L_fb = (dc2L_y * FB_GAIN_MEDIUM) >>> 8;
                comb3L_fb = (dc3L_y * FB_GAIN_MEDIUM) >>> 8;
                comb4L_fb = (dc4L_y * FB_GAIN_MEDIUM) >>> 8;
                comb1R_fb = (dc1R_y * FB_GAIN_MEDIUM) >>> 8;
                comb2R_fb = (dc2R_y * FB_GAIN_MEDIUM) >>> 8;
                comb3R_fb = (dc3R_y * FB_GAIN_MEDIUM) >>> 8;
                comb4R_fb = (dc4R_y * FB_GAIN_MEDIUM) >>> 8;
            end
            2'b10: begin
                comb1L_fb = (dc1L_y * FB_GAIN_LONG) >>> 8;
                comb2L_fb = (dc2L_y * FB_GAIN_LONG) >>> 8;
                comb3L_fb = (dc3L_y * FB_GAIN_LONG) >>> 8;
                comb4L_fb = (dc4L_y * FB_GAIN_LONG) >>> 8;
                comb1R_fb = (dc1R_y * FB_GAIN_LONG) >>> 8;
                comb2R_fb = (dc2R_y * FB_GAIN_LONG) >>> 8;
                comb3R_fb = (dc3R_y * FB_GAIN_LONG) >>> 8;
                comb4R_fb = (dc4R_y * FB_GAIN_LONG) >>> 8;
            end
            2'b11: begin
                comb1L_fb = (dc1L_y * FB_GAIN_HUGE) >>> 8;
                comb2L_fb = (dc2L_y * FB_GAIN_HUGE) >>> 8;
                comb3L_fb = (dc3L_y * FB_GAIN_HUGE) >>> 8;
                comb4L_fb = (dc4L_y * FB_GAIN_HUGE) >>> 8;
                comb1R_fb = (dc1R_y * FB_GAIN_HUGE) >>> 8;
                comb2R_fb = (dc2R_y * FB_GAIN_HUGE) >>> 8;
                comb3R_fb = (dc3R_y * FB_GAIN_HUGE) >>> 8;
                comb4R_fb = (dc4R_y * FB_GAIN_HUGE) >>> 8;
            end
        endcase
    end

    always_comb begin
        // LEFT
        comb1L_in  = flush ? '0 : sat16($signed(audio_in[0]) + comb1L_fb);
        comb2L_in  = flush ? '0 : sat16($signed(audio_in[0]) + comb2L_fb);
        comb3L_in  = flush ? '0 : sat16($signed(audio_in[0]) + comb3L_fb);
        comb4L_in  = flush ? '0 : sat16($signed(audio_in[0]) + comb4L_fb);
        comb1L_out = comb1L_delayed;
        comb2L_out = comb2L_delayed;
        comb3L_out = comb3L_delayed;
        comb4L_out = comb4L_delayed;
        comb_sum_L = $signed(comb1L_out) + $signed(comb2L_out) +
                     $signed(comb3L_out) + $signed(comb4L_out);

        // RIGHT
        comb1R_in  = flush ? '0 : sat16($signed(audio_in[1]) + comb1R_fb);
        comb2R_in  = flush ? '0 : sat16($signed(audio_in[1]) + comb2R_fb);
        comb3R_in  = flush ? '0 : sat16($signed(audio_in[1]) + comb3R_fb);
        comb4R_in  = flush ? '0 : sat16($signed(audio_in[1]) + comb4R_fb);
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
    // y[n] = −g·x[n] + x[n−d] + g·y[n−d],  g = ALLPASS_COEF/256 = 0.5
    // Comb sum divided by 4 to prevent overload from 4 parallel outputs.
    // ----------------------------------------------------------------

    // LEFT
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

    // RIGHT
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
    // dry + (wet − dry) * fx_mix / 256
    // fx_mix = 0 → full dry,  fx_mix = 255 → 99.6 % wet
    // ----------------------------------------------------------------

    always_comb begin
        wet_L        = allpass3L_out;
        wet_R        = allpass3R_out;
        wet_scaled_L = $signed(wet_L) - $signed(audio_in[0]);
        wet_scaled_R = $signed(wet_R) - $signed(audio_in[1]);
        mixed_L = $signed(audio_in[0]) + ((wet_scaled_L * $signed({1'b0, fx_mix})) >>> 8);
        mixed_R = $signed(audio_in[1]) + ((wet_scaled_R * $signed({1'b0, fx_mix})) >>> 8);
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