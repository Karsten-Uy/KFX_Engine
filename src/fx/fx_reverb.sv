/*
 * fx_reverb.sv
 *
 * Stereo Feedback Delay Network (FDN) reverberator with modulated delay
 * lines, input pre-delay, and variable input diffusion.
 *
 * Why an FDN
 * ----------
 * The previous design was a Schroeder/Moorer reverb (4 parallel combs ->
 * 3 series all-passes per channel).  With only 4 comb modes per channel the
 * tail's echo density is low and periodic, which the ear hears as a ringing
 * "metallic" coloration — worst on long, high-decay swells.  An FDN cross-
 * couples N delay lines through a lossless mixing matrix every sample, so
 * echo density grows multiplicatively and the tail becomes dense and smooth.
 *
 * Architecture
 * ------------
 *   in[L] -> predelayL -> diffuseL (2 allpass) ─┐ inject ±1
 *   in[R] -> predelayR -> diffuseR (2 allpass) ─┤
 *                                               ▼
 *     ┌───────────────────────────────────────────────────────────────┐
 *     │ 8 fractional delay lines (delay_line_li)  d_0..d_7             │
 *     │   length_i = scale(base_i, fx_size) + mod_i(LFO, fx_moddepth)  │
 *     │   s_i = line_i out  (2-sample latency)                         │
 *     │ Stage A: per-line one-pole LP damping  lp_i  (registered, Q16) │
 *     │ Stage B: lp_out_i = lp_i >>> 16  (registered, integer range)   │
 *     │ Hadamard mix (3 butterfly stages, ± only):  m = H · lp_out     │
 *     │ feedback:  fb_i = (m_i * g_eff) >>> 8   (1/√8 folded into g_eff)│
 *     │ line_in_i = sat16( inject_i + fb_i )                           │
 *     └───────────────────────────────────────────────────────────────┘
 *                                               │ taps (±)
 *                                               ▼
 *            mid/side -> width -> DC blocker -> wet -> dry/wet mix -> out
 *
 * No combinational loop: both loop endpoints — the lp/lp_out registers and
 * the delay-line RAM — are registers; the Hadamard butterfly and the feedback
 * gain are combinational between them.
 *
 * DSP budget (the design runs at 87/87 DSP — zero new multipliers allowed)
 * -----------------------------------------------------------------------
 *   - Hadamard matrix is multiplier-free (24 add/subtract).
 *   - Feedback gain, modulation, diffusion and width multiplies are all
 *     forced into ALUTs via (* multstyle = "logic" *).
 *   - Only the 8 per-line damping LPs (wide Q16) and the 2 wet/dry mix
 *     multiplies remain on DSP — same count as the comb LPs they replace,
 *     and the per-comb DC blockers drop from 8 to 2, so the FDN uses fewer
 *     DSP blocks than the old Schroeder reverb.
 *
 * Modulation (Lexicon-style anti-metallic movement)
 * -------------------------------------------------
 *   A 24-bit phase accumulator drives a triangle LFO; each line takes a
 *   decorrelated phase (phase + i·2^21).  The depth-scaled triangle perturbs
 *   each delay length by a few samples; a per-line Q16.16 slew accumulator
 *   (>>10) smooths the change to avoid zipper clicks (same scheme as the
 *   chorus).  The fractional delay (delay_line_li) interpolates sub-sample so
 *   the moving read does not quantise-buzz.
 *
 * Parameter mapping  (all 8-bit, 0–255)
 * --------------------------------------
 *   fx_size      — room size       (scales all FDN delay lengths)
 *   fx_damping   — HF damping       (0 = bright, 255 = dark)
 *   fx_decay     — tail length/RT60 (4 discrete steps via [7:6])
 *   fx_moddepth  — tail modulation depth (0 = static, 255 = max wobble)
 *   fx_diffusion — input diffusion  (0 = none, 255 = max smear)
 *   fx_predelay  — pre-delay        (0 ≈ 0 ms, 255 ≈ 80 ms)
 *   fx_width     — stereo width     (0 = mono tail, 255 = fully decorrelated)
 *   fx_mix       — dry/wet blend    (0 = dry, 255 = full wet)
 *
 * Decay mapping  (fx_decay[7:6] selects the per-line round-trip gain g;
 * g_eff = round(g · 256 / √8) bakes in the Hadamard 1/√8 normalisation)
 *   00 → g ≈ 0.781 → g_eff = 71   short
 *   01 → g ≈ 0.859 → g_eff = 78   medium
 *   10 → g ≈ 0.922 → g_eff = 83   long (default / reset)
 *   11 → g ≈ 0.969 → g_eff = 88   huge
 *
 * Latency: dry path 1 sample (audio_in -> mixed combinational -> output reg).
 *   The wet branch adds its own intentional reverb group delay.
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
    input  logic [PARAM_W-1:0]            fx_moddepth,
    input  logic [PARAM_W-1:0]            fx_diffusion,
    input  logic [PARAM_W-1:0]            fx_predelay,
    input  logic [PARAM_W-1:0]            fx_width,
    input  logic [PARAM_W-1:0]            fx_mix,
    input  logic                          sample_en
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Local Constants
    // ----------------------------------------------------------------

    localparam int N      = 8;          // FDN order
    localparam int FRAC_W = 4;          // fractional bits for delay_line_li

    // Eight mutually-prime base delays (~20–33 ms @ 48 kHz).  fx_size scales
    // them up to ×2 → max ≈ 3194 samples, bounding the (dual-read) RAM cost.
    localparam int BASE [0:N-1] = '{997, 1097, 1213, 1289, 1381, 1453, 1531, 1597};

    localparam int MAX_FDN_DELAY = 3300;
    localparam int FDN_ADDR_W    = $clog2(MAX_FDN_DELAY);   // 12

    // Pre-delay: 0..~80 ms (fx_predelay × 15 ≈ 0..3825 samples).
    localparam int PREDELAY_MAX = 3840;
    localparam int PRE_ADDR_W   = $clog2(PREDELAY_MAX);     // 12

    // Input diffusers: two series all-passes per channel, short coprime lengths.
    localparam int DIFF_LEN [0:3] = '{142, 107, 379, 277};
    localparam int DIFF_MAX     = 384;
    localparam int DIFF_ADDR_W  = $clog2(DIFF_MAX);         // 9

    localparam LP_FRAC_BITS  = 16;

    // DC blocker: R = 32764/32768 ≈ 0.99988 → fc ≈ 5.5 Hz @ 48 kHz.
    localparam DC_BLOCK_SHIFT = 15;
    localparam DC_BLOCK_R     = 32'sd32764;

    // Feedback gain = g · 256 / √8 (folds the Hadamard 1/√8 normalisation).
    localparam logic signed [8:0] GEFF_SHORT  = 9'sd71;   // g ≈ 0.781
    localparam logic signed [8:0] GEFF_MEDIUM = 9'sd78;   // g ≈ 0.859
    localparam logic signed [8:0] GEFF_LONG   = 9'sd83;   // g ≈ 0.922 (default)
    localparam logic signed [8:0] GEFF_HUGE   = 9'sd88;   // g ≈ 0.969

    // LFO: ~0.86 Hz triangle (inc = round(2^24 / 48000 · 0.86)).  MOD_SHIFT
    // sets the depth scale — at fx_moddepth = 255 the swing is ≈ ±15 samples.
    localparam logic [23:0] LFO_INC   = 24'd300;
    localparam int          MOD_SHIFT = 19;

    // ----------------------------------------------------------------
    // Shared combinational coefficients
    // ----------------------------------------------------------------

    logic [8:0]  lp_coef;       // one-pole damping coefficient
    logic [8:0]  diff_g;        // diffusion all-pass coefficient (Q8, 0..~0.70)

    always_comb begin
        lp_coef = (9'd256 - {1'b0, fx_damping} < 9'd16)
                  ? 9'd16
                  : 9'd256 - {1'b0, fx_damping};
        // 0..255 → 0..179 (Q8) → g up to ≈ 0.70, safely < 1 for stability.
        diff_g  = 9'((fx_diffusion * 8'd180) >> 8);
    end

    // ----------------------------------------------------------------
    // Feedback Gain  (registered once per sample, as in the old design)
    // ----------------------------------------------------------------

    logic signed [8:0] g_eff;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) g_eff <= GEFF_LONG;
        else if (sample_en) begin
            case (fx_decay[7:6])
                2'b00: g_eff <= GEFF_SHORT;
                2'b01: g_eff <= GEFF_MEDIUM;
                2'b10: g_eff <= GEFF_LONG;
                2'b11: g_eff <= GEFF_HUGE;
            endcase
        end
    end

    // ----------------------------------------------------------------
    // Pre-Delay  (one integer delay_line per channel)
    // ----------------------------------------------------------------

    logic [PRE_ADDR_W-1:0]    predelay_samp;
    logic signed [DATA_W-1:0] pre_in_L, pre_in_R;
    logic signed [DATA_W-1:0] pre_L, pre_R;

    always_comb begin
        predelay_samp = (PRE_ADDR_W)'(fx_predelay * 8'd15);
        pre_in_L      = flush ? '0 : audio_in[0];
        pre_in_R      = flush ? '0 : audio_in[1];
    end

    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(PREDELAY_MAX), .ADDR_W(PRE_ADDR_W))
    PREDELAY_L (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
                .data_in(pre_in_L), .data_out(pre_L), .delay_samples(predelay_samp));
    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(PREDELAY_MAX), .ADDR_W(PRE_ADDR_W))
    PREDELAY_R (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
                .data_in(pre_in_R), .data_out(pre_R), .delay_samples(predelay_samp));

    // ----------------------------------------------------------------
    // Input Diffusion  (2 series true all-passes per channel)
    //
    //   w[n]   = x[n] + g·w[n-d]         (stored in the delay line)
    //   y[n]   = w[n-d] - g·w[n]         (= -g·x[n] + (1-g²)·w[n-d])
    //
    // Multiplies are forced into logic — g is runtime (fx_diffusion).
    // ----------------------------------------------------------------

    logic signed [DATA_W-1:0] dif_del   [0:3];   // delay-line outputs (w[n-d])
    logic signed [DATA_W-1:0] dif_wn    [0:3];   // w[n] (written to the lines)
    logic signed [DATA_W-1:0] dif_y     [0:3];   // stage outputs
    logic signed [DATA_W-1:0] dif_x     [0:3];   // stage inputs
    (* multstyle = "logic" *) logic signed [31:0] dif_gx [0:3];
    (* multstyle = "logic" *) logic signed [31:0] dif_gw [0:3];
    logic signed [DATA_W-1:0] diff_L, diff_R;    // diffused channel outputs

    // Stage inputs: L = stages 0→1, R = stages 2→3.  Assigned in dependency
    // order below so each stage's input is final before it is consumed.
    always_comb begin
        dif_x[0] = pre_L;       dif_x[1] = dif_y[0];   // L chain
        dif_x[2] = pre_R;       dif_x[3] = dif_y[2];   // R chain

        // Unrolled in order 0,1,2,3 — stage 1 needs y[0], stage 3 needs y[2].
        dif_gx[0] = ($signed({1'b0, diff_g}) * $signed(dif_del[0])) >>> 8;
        dif_wn[0] = flush ? '0 : sat16($signed(dif_x[0]) + dif_gx[0]);
        dif_gw[0] = ($signed({1'b0, diff_g}) * $signed(dif_wn[0])) >>> 8;
        dif_y[0]  = sat16($signed(dif_del[0]) - dif_gw[0]);

        dif_gx[1] = ($signed({1'b0, diff_g}) * $signed(dif_del[1])) >>> 8;
        dif_wn[1] = flush ? '0 : sat16($signed(dif_x[1]) + dif_gx[1]);
        dif_gw[1] = ($signed({1'b0, diff_g}) * $signed(dif_wn[1])) >>> 8;
        dif_y[1]  = sat16($signed(dif_del[1]) - dif_gw[1]);

        dif_gx[2] = ($signed({1'b0, diff_g}) * $signed(dif_del[2])) >>> 8;
        dif_wn[2] = flush ? '0 : sat16($signed(dif_x[2]) + dif_gx[2]);
        dif_gw[2] = ($signed({1'b0, diff_g}) * $signed(dif_wn[2])) >>> 8;
        dif_y[2]  = sat16($signed(dif_del[2]) - dif_gw[2]);

        dif_gx[3] = ($signed({1'b0, diff_g}) * $signed(dif_del[3])) >>> 8;
        dif_wn[3] = flush ? '0 : sat16($signed(dif_x[3]) + dif_gx[3]);
        dif_gw[3] = ($signed({1'b0, diff_g}) * $signed(dif_wn[3])) >>> 8;
        dif_y[3]  = sat16($signed(dif_del[3]) - dif_gw[3]);

        diff_L = dif_y[1];
        diff_R = dif_y[3];
    end

    genvar gd;
    generate
        for (gd = 0; gd < 4; gd++) begin : DIFFUSER
            delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(DIFF_MAX), .ADDR_W(DIFF_ADDR_W))
            U_DIFF (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
                    .data_in(dif_wn[gd]), .data_out(dif_del[gd]),
                    .delay_samples((DIFF_ADDR_W)'(DIFF_LEN[gd])));
        end
    endgenerate

    // ----------------------------------------------------------------
    // FDN Delay Lines  (8 modulated fractional lines)
    // ----------------------------------------------------------------

    logic signed [DATA_W-1:0]        s        [0:N-1];   // line outputs
    logic signed [DATA_W-1:0]        line_in  [0:N-1];   // line inputs
    logic [FDN_ADDR_W+FRAC_W-1:0]    len_fix  [0:N-1];   // Q(ADDR).(FRAC) length

    genvar gi;
    generate
        for (gi = 0; gi < N; gi++) begin : FDN_LINE
            delay_line_li #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_FDN_DELAY), .FRAC_W(FRAC_W))
            U_LINE (.clk(clk), .reset_n(reset_n), .sample_en(sample_en),
                    .data_in(line_in[gi]), .data_out(s[gi]), .delay_samples(len_fix[gi]));
        end
    endgenerate

    // ----------------------------------------------------------------
    // LFO + Modulated Length  (Stage 0)
    // ----------------------------------------------------------------

    logic [23:0]        lfo_phase;
    logic [23:0]        ph        [0:N-1];
    logic signed [15:0] lfo_tri   [0:N-1];
    (* multstyle = "logic" *) logic signed [31:0] mod_smp [0:N-1];
    (* multstyle = "logic" *) logic signed [31:0] scaled_base [0:N-1];
    logic signed [31:0] target_len  [0:N-1];
    logic signed [31:0] len_acc     [0:N-1];   // Q16.16 slew accumulator

    always_comb begin
        for (int i = 0; i < N; i++) begin
            ph[i]      = lfo_phase + 24'(i * 24'h20_0000);     // decorrelated phase
            lfo_tri[i] = ph[i][23] ? $signed(~ph[i][22:7]) : $signed(ph[i][22:7]);
            mod_smp[i] = ($signed(lfo_tri[i]) * $signed({1'b0, fx_moddepth})) >>> MOD_SHIFT;
            scaled_base[i] = BASE[i] + (($signed(32'(BASE[i])) * $signed({1'b0, fx_size})) >>> 8);
            target_len[i]  = (scaled_base[i] + mod_smp[i]) <<< 16;   // Q16.16
            len_fix[i]     = len_acc[i][16+FDN_ADDR_W-1 : 16-FRAC_W];
        end
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            lfo_phase <= '0;
            for (int i = 0; i < N; i++)
                len_acc[i] <= $signed(32'(BASE[i])) <<< 16;
        end else if (sample_en) begin
            lfo_phase <= lfo_phase + LFO_INC;
            for (int i = 0; i < N; i++)
                len_acc[i] <= len_acc[i] + ((target_len[i] - len_acc[i]) >>> 10);
        end
    end

    // ----------------------------------------------------------------
    // Stage A — per-line one-pole LP damping  (registered, Q16)
    //
    //   lp[n] = lp[n-1] + ((delta · lp_coef) >>> 8)
    //   delta = (s << 16) - lp   (31-bit);  delta·lp_coef needs 48-bit.
    // ----------------------------------------------------------------

    logic signed [31:0] lp     [0:N-1];   // Q16
    logic signed [31:0] lp_out [0:N-1];   // Stage B — integer range

    always_ff @(posedge clk) begin
        if (!reset_n || flush) begin
            for (int i = 0; i < N; i++) begin
                lp[i]     <= '0;
                lp_out[i] <= '0;
            end
        end else if (sample_en) begin
            for (int i = 0; i < N; i++) begin
                lp[i] <= lp[i] +
                    32'( 48'($signed(($signed(s[i]) <<< LP_FRAC_BITS) - lp[i]))
                         * 48'($signed({1'b0, lp_coef})) >>> 8 );
                lp_out[i] <= $signed(lp[i]) >>> LP_FRAC_BITS;
            end
        end
    end

    // ----------------------------------------------------------------
    // Hadamard Mix  (fast Walsh–Hadamard butterfly, ± only, 0 DSP)
    //   m = H · lp_out   (H entries ±1; the 1/√8 lives in g_eff)
    // ----------------------------------------------------------------

    logic signed [31:0] a [0:N-1];
    logic signed [31:0] b [0:N-1];
    logic signed [31:0] m [0:N-1];
    (* multstyle = "logic" *) logic signed [31:0] fb [0:N-1];

    always_comb begin
        // stage 1
        a[0] = lp_out[0] + lp_out[1];  a[1] = lp_out[0] - lp_out[1];
        a[2] = lp_out[2] + lp_out[3];  a[3] = lp_out[2] - lp_out[3];
        a[4] = lp_out[4] + lp_out[5];  a[5] = lp_out[4] - lp_out[5];
        a[6] = lp_out[6] + lp_out[7];  a[7] = lp_out[6] - lp_out[7];
        // stage 2
        b[0] = a[0] + a[2];  b[1] = a[1] + a[3];  b[2] = a[0] - a[2];  b[3] = a[1] - a[3];
        b[4] = a[4] + a[6];  b[5] = a[5] + a[7];  b[6] = a[4] - a[6];  b[7] = a[5] - a[7];
        // stage 3
        m[0] = b[0] + b[4];  m[1] = b[1] + b[5];  m[2] = b[2] + b[6];  m[3] = b[3] + b[7];
        m[4] = b[0] - b[4];  m[5] = b[1] - b[5];  m[6] = b[2] - b[6];  m[7] = b[3] - b[7];

        for (int i = 0; i < N; i++)
            fb[i] = (m[i] * g_eff) >>> 8;
    end

    // ----------------------------------------------------------------
    // Stereo Injection  +  Line Input
    //
    // L feeds lines {0,2,4,6}, R feeds {1,3,5,7}, with alternating signs to
    // decorrelate.  Injected at half level to leave feedback headroom.
    // ----------------------------------------------------------------

    logic signed [31:0] inj [0:N-1];

    always_comb begin
        inj[0] =  $signed(diff_L) >>> 1;  inj[2] = -($signed(diff_L) >>> 1);
        inj[4] =  $signed(diff_L) >>> 1;  inj[6] = -($signed(diff_L) >>> 1);
        inj[1] =  $signed(diff_R) >>> 1;  inj[3] = -($signed(diff_R) >>> 1);
        inj[5] =  $signed(diff_R) >>> 1;  inj[7] = -($signed(diff_R) >>> 1);

        for (int i = 0; i < N; i++)
            line_in[i] = flush ? '0 : sat16(inj[i] + fb[i]);
    end

    // ----------------------------------------------------------------
    // Output Taps  +  Stereo Width
    //
    //   tapL/tapR : signed sums of the L-fed / R-fed line outputs (>>2 head-
    //               room).  mid/side decode, width scales the side component.
    // ----------------------------------------------------------------

    logic signed [31:0] tapL, tapR, mid, side;
    (* multstyle = "logic" *) logic signed [31:0] scaled_side;
    logic signed [31:0] wetL_pre, wetR_pre;

    always_comb begin
        tapL = ($signed(s[0]) - $signed(s[2]) + $signed(s[4]) - $signed(s[6])) >>> 2;
        tapR = ($signed(s[1]) - $signed(s[3]) + $signed(s[5]) - $signed(s[7])) >>> 2;
        mid  = (tapL + tapR) >>> 1;
        side = (tapL - tapR) >>> 1;
        scaled_side = (side * $signed({1'b0, fx_width})) >>> 8;
        // Saturate to ±32767 before the DC blocker so R·y stays within the
        // 32-bit product (matches the old design's safe range).
        wetL_pre = sat16(mid + scaled_side);
        wetR_pre = sat16(mid - scaled_side);
    end

    // ----------------------------------------------------------------
    // DC Blockers  (one per output channel)
    //   y[n] = x[n] - x[n-1] + (R · y[n-1]) >>> 15
    //   x = wetL_pre/wetR_pre ≤ ±32767 → R·y < 2^30, safe in 32-bit signed.
    // ----------------------------------------------------------------

    logic signed [31:0] dcL_x, dcL_y, dcR_x, dcR_y;

    always_ff @(posedge clk) begin
        if (!reset_n || flush) begin
            dcL_x <= '0;  dcL_y <= '0;
            dcR_x <= '0;  dcR_y <= '0;
        end else if (sample_en) begin
            dcL_y <= $signed(wetL_pre) - dcL_x + ((DC_BLOCK_R * dcL_y) >>> DC_BLOCK_SHIFT);
            dcL_x <= $signed(wetL_pre);
            dcR_y <= $signed(wetR_pre) - dcR_x + ((DC_BLOCK_R * dcR_y) >>> DC_BLOCK_SHIFT);
            dcR_x <= $signed(wetR_pre);
        end
    end

    // ----------------------------------------------------------------
    // Wet/Dry Mix  +  Output Register
    //   dry + (wet - dry) · fx_mix / 256
    // ----------------------------------------------------------------

    logic signed [DATA_W-1:0] wet_L, wet_R;
    logic signed [31:0]       wet_scaled_L, wet_scaled_R;
    logic signed [31:0]       mixed_L, mixed_R;

    always_comb begin
        wet_L        = sat16(dcL_y);
        wet_R        = sat16(dcR_y);
        wet_scaled_L = $signed(wet_L) - $signed(audio_in[0]);
        wet_scaled_R = $signed(wet_R) - $signed(audio_in[1]);
        mixed_L = $signed(audio_in[0]) + ((wet_scaled_L * $signed({1'b0, fx_mix})) >>> 8);
        mixed_R = $signed(audio_in[1]) + ((wet_scaled_R * $signed({1'b0, fx_mix})) >>> 8);
    end

    always_ff @(posedge clk) begin
        if (!reset_n) audio_out <= '0;
        else if (sample_en) begin
            audio_out[0] <= sat16(mixed_L);
            audio_out[1] <= sat16(mixed_R);
        end
    end

endmodule
