/*
 * fx_distortion.sv
 *
 * Stereo amp-style distortion: pre-emphasis, asymmetric soft clipping,
 * speaker cabinet simulation, presence shelf, tone control, wet/dry mix,
 * and makeup gain.
 *
 * Processing stages
 * -----------------
 *   1. Pre-emphasis     — first-difference high-shelf boosts presence band
 *                         before clipping to add bite and attack.
 *                         emph = x + (x - x_prev) >> 1  (0 DSPs)
 *
 *   2. Drive            — multiplies by drive_gain (1× to 32.875×).
 *                         1 DSP: sat16 narrows emph to 16-bit before the
 *                         multiply, reducing it from 32×16 to 16×16.
 *
 *   3. Asymmetric bias  — adds bias (0–25% full scale, set by fx_bias)
 *                         before clamping to ±1, generating even-order
 *                         harmonics (warmth/octave character).
 *
 *   4. Polynomial clip  — tanh(x) approximated by x − x³/3 inside (−1, 1),
 *                         hard-clamped to ±TWO_THRD outside.
 *                         0 DSPs: multstyle = "logic" on 16×16 and 32×16.
 *
 *   5. Wet/dry mix      — (dry + (wet − dry) * fx_mix) / 256  (0 DSPs)
 *
 *   6. Makeup gain      — unity at fx_makeup_gain = 128  (0 DSPs)
 *
 *   7. Cabinet sim      — two cascaded one-pole IIR LPs at ~6 kHz roll
 *                         off harsh ultrasonic content.  α = 9/16.
 *                         0 DSPs.
 *
 *   8. Tone control     — one-pole LP after cabinet, cutoff controlled by
 *                         fx_tone (0 = darkest ~1 kHz, 255 = bypassed).
 *                         0 DSPs: multstyle = "logic", 17×8.
 *
 *   9. Presence shelf   — one-pole high-shelf adds 0–6 dB at 3–6 kHz,
 *                         amount controlled by fx_presence. Equivalent to
 *                         the presence knob on a Marshall.
 *                         0 DSPs: multstyle = "logic", 17×8.
 *
 * DSP budget: ~1 DSP total.
 *
 * Polynomial notes
 * ----------------
 *   x is clamped to ±32767, so x³ ≤ 32767³ and x³>>>30 ≤ 32767 (fits 16-bit).
 *   Division by 3 via shifts: x/3 ≈ (x + x>>2 + x>>4 + x>>6) >> 2 = x×85/256.
 *   Error 0.39% — inaudible.
 *
 * Latency: 6 samples.
 *
 * Parameter mapping  (all 8-bit, 0–255)
 * --------------------------------------
 *   fx_drive       — distortion amount   (0 = unity,   255 = 32.875×)
 *   fx_mix         — dry/wet blend       (0 = dry,     255 = full wet)
 *   fx_makeup_gain — output level        (128 = unity)
 *   fx_bias        — asymmetric bias     (0 = symmetric clip,
 *                                         255 = 25% bias, max warmth)
 *   fx_tone        — post-dist tone      (0 = dark ~1 kHz,
 *                                         255 = tone control bypassed)
 *   fx_presence    — presence shelf amt  (0 = flat, 255 = max boost)
 *
 * Ports
 * -----
 *   audio_in  — stereo signed 16-bit input
 *   audio_out — stereo signed 16-bit output
 *   sample_en — single-cycle sample strobe
 */

module fx_distortion #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                          clk,
    input  logic                          reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,
    output logic signed [1:0][DATA_W-1:0] audio_out,
    input  logic [PARAM_W-1:0]            fx_drive,
    input  logic [PARAM_W-1:0]            fx_makeup_gain,
    input  logic [PARAM_W-1:0]            fx_bias,
    input  logic [PARAM_W-1:0]            fx_tone,
    input  logic [PARAM_W-1:0]            fx_presence,
    input  logic [PARAM_W-1:0]            fx_mix,
    input  logic                          sample_en
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Constants  (Q15)
    // ----------------------------------------------------------------

    localparam signed [15:0] ONE      =  16'sd32767;   // +1.0 in Q15
    localparam signed [15:0] NEG_ONE  = -16'sd32767;   // -1.0 in Q15
    localparam signed [15:0] TWO_THRD =  16'sd21845;   // +2/3 in Q15

    // ----------------------------------------------------------------
    // Drive Gain  (shared L+R)
    //
    // drive_gain = 256 + fx_drive * 32  →  range [256, 8416] ≈ [1×, 32.875×]
    // ----------------------------------------------------------------

    logic [15:0] drive_gain;
    assign drive_gain = 16'h0100 + ({8'h00, fx_drive} << 5);

    // ----------------------------------------------------------------
    // Bias (parameterised)
    //
    // bias = fx_bias << 5  →  range [0, 8160] = [0%, 24.9%] of full scale.
    // fx_bias = 0   → no bias, symmetric clipping (clean/tight)
    // fx_bias = 102 → ~10% bias (mild tube warmth)
    // fx_bias = 255 → ~25% bias (heavy even-harmonic saturation)
    // ----------------------------------------------------------------

    logic signed [15:0] bias;
    assign bias = $signed({1'b0, fx_bias}) << 5;   // always positive, max 8160

    // ----------------------------------------------------------------
    // 1. Pre-Emphasis  (0 DSPs)
    //
    // emph = x + (x - x_prev) >> 1
    // Strong high-shelf boost before clipping adds pick attack and
    // articulation, like a bright-switched amp input.
    // 17-bit to hold x ± 50% of delta without overflow.
    // ----------------------------------------------------------------

    logic signed [15:0] audio_prev [1:0];
    logic signed [16:0] emph       [1:0];

    always_comb begin
        for (int i = 0; i < 2; i++)
            emph[i] = $signed(audio_in[i]) +
                      ($signed($signed(audio_in[i]) - $signed(audio_prev[i])) >>> 1);
    end

    // ----------------------------------------------------------------
    // 2. Drive Stage  (1 DSP)
    //
    // sat16 narrows emph to 16-bit before the multiply, keeping it 16×16.
    // ----------------------------------------------------------------

    logic signed [31:0] product     [1:0];
    logic signed [31:0] product_reg [1:0];
    logic signed [31:0] x_raw       [1:0];  // product_reg >> 8 (may exceed 16-bit)
    logic signed [15:0] x           [1:0];  // biased + clamped to ±ONE

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            product[i] = $signed(sat16(emph[i])) * $signed({1'b0, drive_gain});
            x_raw[i]   = product_reg[i] >>> 8;

            // Asymmetric bias — amount set by fx_bias parameter.
            if      ($signed(x_raw[i]) + $signed(32'(bias)) >  $signed(32'(ONE)))   x[i] =  ONE;
            else if ($signed(x_raw[i]) + $signed(32'(bias)) < -$signed(32'(ONE)))   x[i] = NEG_ONE;
            else                                                                      x[i] = x_raw[i][15:0] + bias;
        end
    end

    // ----------------------------------------------------------------
    // 3. Polynomial Stage: x² and x³  (0 DSPs)
    //
    // multstyle = "logic" forces LUT shift-add trees.
    //   x is 16-bit  →  x_sq 32-bit  (16×16)
    //   x_sq is 32-bit  →  x_cb 48-bit  (32×16)
    // ----------------------------------------------------------------

    (* multstyle = "logic" *) logic signed [31:0] x_sq [1:0];
    (* multstyle = "logic" *) logic signed [47:0] x_cb [1:0];
    logic signed [31:0] x_sq_reg [1:0];
    logic signed [47:0] x_cb_reg [1:0];

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            x_sq[i] = $signed(x[i])        * $signed(x[i]);
            x_cb[i] = $signed(x_sq_reg[i]) * $signed(x[i]);
        end
    end

    // ----------------------------------------------------------------
    // 4. Nonlinearity: tanh approximation  (0 DSPs)
    //
    // cubic_term = x_cb_reg >>> 30  →  x³ in Q15 (fits 16-bit).
    // Division by 3 via shifts (error 0.39%, inaudible).
    // ----------------------------------------------------------------

    logic signed [15:0] cubic_term    [1:0];
    logic signed [17:0] cubic_sum     [1:0];
    logic signed [15:0] cubic_div3    [1:0];
    logic signed [15:0] distorted     [1:0];
    logic signed [15:0] distorted_reg [1:0];

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            cubic_term[i] = $signed(x_cb_reg[i]) >>> 30;

            cubic_sum[i]  = $signed(cubic_term[i])        +
                            ($signed(cubic_term[i]) >>> 2) +
                            ($signed(cubic_term[i]) >>> 4) +
                            ($signed(cubic_term[i]) >>> 6);
            cubic_div3[i] = $signed(cubic_sum[i]) >>> 2;

            if      (x[i] >=  ONE)    distorted[i] =  TWO_THRD;
            else if (x[i] <= NEG_ONE) distorted[i] = -TWO_THRD;
            else                      distorted[i]  = $signed(x[i]) - cubic_div3[i];
        end
    end

    // ----------------------------------------------------------------
    // 5. Wet/Dry Mix + Makeup Gain  (0 DSPs each)
    //
    // multstyle = "logic": 16×8-bit — ~100 LUTs, cheaper than a DSP.
    // ----------------------------------------------------------------

    (* multstyle = "logic" *) logic signed [24:0] mix_product    [1:0];
    (* multstyle = "logic" *) logic signed [23:0] makeup_product [1:0];
    logic signed [15:0] mix_res [1:0];
    logic signed [15:0] mix_reg [1:0];
    logic signed [15:0] makeup  [1:0];

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            // Wet/dry: dry + (wet - dry) * fx_mix / 256
            mix_product[i] = ($signed(distorted_reg[i]) - $signed(audio_in[i])) *
                             $signed({1'b0, fx_mix});
            mix_res[i]     = sat16($signed(audio_in[i]) + ($signed(mix_product[i]) >>> 8));

            // Makeup gain: unity at fx_makeup_gain = 128
            makeup_product[i] = $signed(mix_reg[i]) * $signed({1'b0, fx_makeup_gain});
            makeup[i]          = sat16($signed(makeup_product[i]) >>> 7);
        end
    end

    // ----------------------------------------------------------------
    // 6. Speaker Cabinet Simulation  (two cascaded one-pole IIRs, 0 DSPs)
    //
    // α = 9/16: fc ≈ 6000 Hz @ 48 kHz.
    // Rolls off ultrasonics while keeping the top end open and present.
    // ----------------------------------------------------------------

    logic signed [15:0] cab1   [1:0], cab2   [1:0];
    logic signed [16:0] d1     [1:0], d2     [1:0];
    logic signed [15:0] cab1_n [1:0], cab2_n [1:0];

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            d1[i]     = $signed(makeup[i])  - $signed(cab1[i]);
            cab1_n[i] = $signed(cab1[i]) + ($signed(d1[i]) >>> 1) + ($signed(d1[i]) >>> 4);

            d2[i]     = $signed(cab1_n[i]) - $signed(cab2[i]);
            cab2_n[i] = $signed(cab2[i]) + ($signed(d2[i]) >>> 1) + ($signed(d2[i]) >>> 4);
        end
    end

    // ----------------------------------------------------------------
    // 7. Tone Control  (one-pole LP, 0 DSPs)
    //
    // Post-distortion tone stack — like the tone knob on a real amp.
    // Cutoff is set by fx_tone:
    //   fx_tone = 0   → α ≈ 0:   output barely tracks input → ~1 kHz  (dark)
    //   fx_tone = 128 → α = 0.5: fc ≈ 7.6 kHz              (mid-bright)
    //   fx_tone = 255 → α ≈ 1.0: nearly bypassed            (full bright)
    //
    // new_state = state + (cab2_n - state) * fx_tone / 256
    // out       = new_state
    //
    // multstyle = "logic": 17×8 multiply — fits in LUTs.
    // ----------------------------------------------------------------

    logic signed [15:0] tone_state [1:0];
    logic signed [16:0] tone_delta [1:0];
    (* multstyle = "logic" *) logic signed [24:0] tone_product [1:0];
    logic signed [15:0] tone_n     [1:0];
    logic signed [15:0] tone_out   [1:0];

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            tone_delta[i]   = $signed(cab2_n[i]) - $signed(tone_state[i]);
            tone_product[i] = $signed(tone_delta[i]) * $signed({1'b0, fx_tone});
            tone_n[i]       = $signed(tone_state[i]) + ($signed(tone_product[i]) >>> 8);
            tone_out[i]     = tone_n[i];
        end
    end

    // ----------------------------------------------------------------
    // 8. Presence Shelf  (one-pole high-shelf, 0 DSPs)
    //
    // Adds 0–6 dB at 3–6 kHz after cabinet and tone stack.
    // Equivalent to the presence knob on a Marshall — puts the pick
    // attack and sizzle back in so lead guitar cuts through a mix.
    //
    // LP pole at ~8 kHz (α = 13/16) tracks tone_out.
    // HP component = tone_out - LP_state  (= dp, already computed).
    // Shelf: out = tone_out + HP * fx_presence / 256
    //
    // fx_presence = 0   → no shelf (flat response after tone)
    // fx_presence = 128 → moderate presence boost (~+3 dB at shelf freq)
    // fx_presence = 255 → full boost (~+6 dB at shelf freq)
    //
    // multstyle = "logic": 17×8 multiply — fits in LUTs.
    // ----------------------------------------------------------------

    logic signed [15:0] pres_state [1:0];
    logic signed [16:0] dp         [1:0];
    logic signed [15:0] pres_n     [1:0];
    (* multstyle = "logic" *) logic signed [24:0] pres_product [1:0];
    logic signed [15:0] pres       [1:0];

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            // LP tracking tone_out at ~8 kHz: α = 13/16
            dp[i]     = $signed(tone_out[i]) - $signed(pres_state[i]);
            pres_n[i] = $signed(pres_state[i]) +
                        ($signed(dp[i]) >>> 1) +
                        ($signed(dp[i]) >>> 2) +
                        ($signed(dp[i]) >>> 4);

            // High-shelf: signal + HP_component * fx_presence / 256
            pres_product[i] = $signed(dp[i]) * $signed({1'b0, fx_presence});
            pres[i]         = sat16($signed(tone_out[i]) + ($signed(pres_product[i]) >>> 8));
        end
    end

    // ----------------------------------------------------------------
    // Pipeline Registers
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            for (int i = 0; i < 2; i++) begin
                audio_prev[i]    <= '0;
                product_reg[i]   <= '0;
                x_sq_reg[i]      <= '0;
                x_cb_reg[i]      <= '0;
                distorted_reg[i] <= '0;
                mix_reg[i]       <= '0;
                cab1[i]          <= '0;
                cab2[i]          <= '0;
                tone_state[i]    <= '0;
                pres_state[i]    <= '0;
            end
        end else if (sample_en) begin
            for (int i = 0; i < 2; i++) begin
                audio_prev[i]    <= audio_in[i];
                product_reg[i]   <= product[i];
                x_sq_reg[i]      <= x_sq[i];
                x_cb_reg[i]      <= x_cb[i];
                distorted_reg[i] <= distorted[i];
                mix_reg[i]       <= mix_res[i];
                cab1[i]          <= cab1_n[i];
                cab2[i]          <= cab2_n[i];
                tone_state[i]    <= tone_n[i];
                pres_state[i]    <= pres_n[i];
            end
        end
    end

    // ----------------------------------------------------------------
    // Output
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) audio_out <= '0;
        else if (sample_en)
            for (int i = 0; i < 2; i++)
                audio_out[i] <= pres[i];
    end

endmodule