/*
 * fx_distortion.sv
 *
 * Stereo amp-style distortion: pre-emphasis, asymmetric soft clipping,
 * speaker cabinet simulation, wet/dry mix, and makeup gain.
 *
 * Processing stages
 * -----------------
 *   1. Pre-emphasis     — first-difference high-shelf boosts presence band
 *                         (~3 kHz) before clipping to add bite and attack.
 *                         emph = x + (x - x_prev) >> 2  (0 DSPs)
 *
 *   2. Drive            — multiplies by drive_gain (1× to 32.875×).
 *                         1 DSP: sat16 narrows emph to 16-bit before the
 *                         multiply, reducing it from 32×16 to 16×16.
 *
 *   3. Asymmetric bias  — adds BIAS (+5% full scale) before clamping to ±1,
 *                         generating even-order harmonics (warmth).
 *
 *   4. Polynomial clip  — tanh(x) approximated by x − x³/3 inside (−1, 1),
 *                         hard-clamped to ±TWO_THRD outside.
 *                         0 DSPs: multstyle = "logic" on 16×16 and 32×16.
 *
 *   5. Wet/dry mix      — (dry + (wet − dry) * fx_mix) / 256  (0 DSPs)
 *
 *   6. Makeup gain      — unity at fx_makeup_gain = 128  (0 DSPs)
 *
 *   7. Cabinet sim      — two cascaded one-pole IIR LPs at ~4.4 kHz roll
 *                         off harsh ultrasonic content.  α = 7/16 implemented
 *                         as (delta>>1) − (delta>>4), 0 DSPs.
 *
 * DSP budget: ~1 DSP total (vs ~29 in the naive implementation).
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
 *   fx_drive       — distortion amount (0 = unity, 255 = 32.875×)
 *   fx_mix         — dry/wet blend     (0 = dry, 255 = full wet)
 *   fx_makeup_gain — output level      (128 = unity)
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
    input  logic [PARAM_W-1:0]            fx_mix,
    input  logic                          sample_en
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Constants  (Q15)
    //
    // Local to this module — specific to the tanh polynomial approximation.
    // ----------------------------------------------------------------

    localparam signed [15:0] ONE      =  16'sd32767;   // +1.0 in Q15
    localparam signed [15:0] NEG_ONE  = -16'sd32767;   // -1.0 in Q15
    localparam signed [15:0] TWO_THRD =  16'sd21845;   // +2/3 in Q15
    localparam signed [15:0] BIAS     =  16'sd1638;    // +5% full scale (asymmetric warmth)

    // ----------------------------------------------------------------
    // Drive Gain  (shared L+R)
    //
    // drive_gain = 256 + fx_drive * 32  →  range [256, 8416] ≈ [1×, 32.875×]
    // ----------------------------------------------------------------

    logic [15:0] drive_gain;
    assign drive_gain = 16'h0100 + ({8'h00, fx_drive} << 5);

    // ----------------------------------------------------------------
    // 1. Pre-Emphasis  (0 DSPs)
    //
    // emph = x + (x - x_prev) >> 2
    // Equivalent to a mild high-shelf boost; adds presence before clipping.
    // 17-bit to hold x ± 25% of delta without overflow.
    // ----------------------------------------------------------------

    logic signed [15:0] audio_prev [1:0];
    logic signed [16:0] emph       [1:0];

    always_comb begin
        for (int i = 0; i < 2; i++)
            emph[i] = $signed(audio_in[i]) +
                      ($signed($signed(audio_in[i]) - $signed(audio_prev[i])) >>> 2);
    end

    // ----------------------------------------------------------------
    // 2. Drive Stage  (1 DSP)
    //
    // sat16 narrows emph to 16-bit before the multiply, keeping it 16×16
    // instead of the 32×16 that would result from the wider emph signal.
    // ----------------------------------------------------------------

    logic signed [31:0] product     [1:0];
    logic signed [31:0] product_reg [1:0];
    logic signed [31:0] x_raw       [1:0];  // product_reg >> 8 (may exceed 16-bit)
    logic signed [15:0] x           [1:0];  // biased + clamped to ±ONE

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            product[i] = $signed(sat16(emph[i])) * $signed({1'b0, drive_gain});
            x_raw[i]   = product_reg[i] >>> 8;

            // Asymmetric bias shifts clipping threshold, generating even harmonics
            if      ($signed(x_raw[i]) + $signed(32'(BIAS)) >  $signed(32'(ONE)))   x[i] =  ONE;
            else if ($signed(x_raw[i]) + $signed(32'(BIAS)) < -$signed(32'(ONE)))   x[i] = NEG_ONE;
            else                                                                      x[i] = x_raw[i][15:0] + BIAS;
        end
    end

    // ----------------------------------------------------------------
    // 3. Polynomial Stage: x² and x³  (0 DSPs)
    //
    // multstyle = "logic" forces LUT shift-add trees.  Correct because:
    //   x is 16-bit  →  x_sq 32-bit  (16×16, small enough for LUTs)
    //   x_sq is 32-bit  →  x_cb 48-bit  (32×16, still fits in LUTs)
    // ----------------------------------------------------------------

    (* multstyle = "logic" *) logic signed [31:0] x_sq [1:0];
    (* multstyle = "logic" *) logic signed [47:0] x_cb [1:0];
    logic signed [31:0] x_sq_reg [1:0];
    logic signed [47:0] x_cb_reg [1:0];

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            x_sq[i] = $signed(x[i])        * $signed(x[i]);         // 16×16 → 32-bit
            x_cb[i] = $signed(x_sq_reg[i]) * $signed(x[i]);         // 32×16 → 48-bit
        end
    end

    // ----------------------------------------------------------------
    // 4. Nonlinearity: tanh approximation  (0 DSPs)
    //
    // cubic_term = x_cb_reg >>> 30  →  x³ in Q15 (provably fits 16-bit).
    // Division by 3 via shifts (error 0.39%, inaudible):
    //   x/3 ≈ (x + x>>2 + x>>4 + x>>6) >> 2  =  x × 85/256
    // ----------------------------------------------------------------

    logic signed [15:0] cubic_term [1:0];
    logic signed [17:0] cubic_sum  [1:0];  // 4 additions need 2 bits headroom
    logic signed [15:0] cubic_div3 [1:0];
    logic signed [15:0] distorted  [1:0];
    logic signed [15:0] distorted_reg [1:0];

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            cubic_term[i] = $signed(x_cb_reg[i]) >>> 30;

            cubic_sum[i]  = $signed(cubic_term[i])        +
                            ($signed(cubic_term[i]) >>> 2) +
                            ($signed(cubic_term[i]) >>> 4) +
                            ($signed(cubic_term[i]) >>> 6);
            cubic_div3[i] = $signed(cubic_sum[i]) >>> 2;

            if      (x[i] >=  ONE)   distorted[i] =  TWO_THRD;
            else if (x[i] <= NEG_ONE) distorted[i] = -TWO_THRD;
            else                      distorted[i]  = $signed(x[i]) - cubic_div3[i];
        end
    end

    // ----------------------------------------------------------------
    // 5. Wet/Dry Mix + Makeup Gain  (0 DSPs each)
    //
    // multstyle = "logic": both are 16×8-bit (param is 8-bit, signal is
    // 16-bit after saturation) — ~100 LUTs each, far cheaper than a DSP.
    // ----------------------------------------------------------------

    (* multstyle = "logic" *) logic signed [24:0] mix_product    [1:0];  // 17-bit × 8-bit
    (* multstyle = "logic" *) logic signed [23:0] makeup_product [1:0];  // 16-bit × 8-bit
    logic signed [15:0] mix_res [1:0];
    logic signed [15:0] mix_reg [1:0];
    logic signed [15:0] makeup  [1:0];

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            // Wet/dry mix: dry + (wet - dry) * mix / 256
            // mix=0 → full dry, mix=255 → 99.6% wet
            mix_product[i] = ($signed(distorted_reg[i]) - $signed(audio_in[i])) *
                             $signed({1'b0, fx_mix});
            mix_res[i]     = sat16($signed(audio_in[i]) + ($signed(mix_product[i]) >>> 8));

            // Makeup gain: unity at fx_makeup_gain = 128  (>> 7)
            makeup_product[i] = $signed(mix_reg[i]) * $signed({1'b0, fx_makeup_gain});
            makeup[i]          = sat16($signed(makeup_product[i]) >>> 7);
        end
    end

    // ----------------------------------------------------------------
    // 6. Speaker Cabinet Simulation  (two cascaded one-pole IIRs, 0 DSPs)
    //
    // α = 7/16: new_state = state + (delta>>1) − (delta>>4)
    // fc ≈ 4425 Hz @ 48 kHz (vs design target of 4500 Hz; −75 Hz inaudible).
    // delta is 17-bit signed; all states fit in 16-bit (overflow proof: both
    // state and input are bounded by ±32767, so new_state ≤ 32767).
    // ----------------------------------------------------------------

    logic signed [15:0] cab1 [1:0], cab2 [1:0];       // LP state registers
    logic signed [16:0] d1   [1:0],  d2  [1:0];       // delta (17-bit signed)
    logic signed [15:0] cab1_n [1:0], cab2_n [1:0];   // next-state (combinational)

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            // Pole 1: tracks makeup output
            d1[i]     = $signed(makeup[i]) - $signed(cab1[i]);
            cab1_n[i] = $signed(cab1[i]) + ($signed(d1[i]) >>> 1) - ($signed(d1[i]) >>> 4);

            // Pole 2: tracks pole-1 output combinationally → true two-pole in one FF stage
            d2[i]     = $signed(cab1_n[i]) - $signed(cab2[i]);
            cab2_n[i] = $signed(cab2[i]) + ($signed(d2[i]) >>> 1) - ($signed(d2[i]) >>> 4);
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
            end
        end
    end

    // ----------------------------------------------------------------
    // Output  (cab2_n is proven ≤ 16-bit; no saturation needed)
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) audio_out <= '0;
        else if (sample_en)
            for (int i = 0; i < 2; i++)
                audio_out[i] <= cab2_n[i];
    end

endmodule