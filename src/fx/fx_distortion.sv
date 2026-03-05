/*

    Distortion of a signal using a non-linear 3rd-order-polynomial approximation
    of the tanh(x) function:

               { 2/3       , x >= 1  }
        f(x) = { x - x^3/3 , -1 < x < 1 }
               {-2/3       , x <= -1 }

    Three additions over the original to make the distortion sound like a real amp
    rather than a digital clipper:

    1. PRE-EMPHASIS — boosts presence band (~3 kHz) before the gain stage.
       emph[n] = x[n] + (x[n] - x_prev[n]) >> 2  (adds 25% of first difference)
       Implemented as a pure shift (0 DSPs).

    2. ASYMMETRIC SOFT CLIPPING — bias before the polynomial adds even-order
       harmonics (warmth) by making positive/negative clips hit different thresholds.
       BIAS = +5% of full scale (1638 in Q15).

    3. SPEAKER CABINET SIMULATION — two cascaded one-pole IIR LP filters at
       ~4.4 kHz roll off the harsh ultrasonic content that hard clipping generates.
       Implemented with shift arithmetic (0 DSPs).

    DSP Block Budget
    ─────────────────────────────────────────────────────────────────────────────
    Operation               Before   After   Technique
    ─────────────────────────────────────────────────────────────────────────────
    Pre-emphasis * EMPH_K      1       0     Replaced with >>> 2 (EMPH_K = 64 = 2^6)
    Drive: emph * drive_gain   2       1     Narrow emph to 16-bit before multiply
    x * x  (polynomial)        4       0     Narrow x to 16-bit; multstyle = "logic"
    x_sq * x  (polynomial)     8       0     32x16; multstyle = "logic"
    cubic_term * ONE_THRD      4       0     Replaced with shift-based /3
    (wet-dry) * fx_mix         1       0     multstyle = "logic"  (8-bit param x 16-bit)
    mix_res * fx_makeup_gain   1       0     multstyle = "logic"  (8-bit param x 16-bit)
    Cabinet delta * CAB_ALPHA  8       0     (delta>>1) - (delta>>4) = delta * 7/16
    ─────────────────────────────────────────────────────────────────────────────
    TOTAL                     ~29      1
    ─────────────────────────────────────────────────────────────────────────────

    Notes on polynomial narrowing
        x is clamped to ±32767 so it fits exactly in signed 16-bit.
        16-bit x  × 16-bit x  → x_sq  32-bit   (fits in LUT fabric with multstyle)
        32-bit x_sq × 16-bit x → x_cb 48-bit   (fits in LUT fabric with multstyle)
        x_cb >>> 30             → cubic_term ≤ 32767  (provably fits in 16-bit)
        Division by 3 via shifts — error 0.39%, inaudible:
            x/3  ≈  (x + x>>2 + x>>4 + x>>6) >> 2  =  x × 85/256

    Notes on cabinet shift alpha
        α = (delta>>1) − (delta>>4) = delta × 7/16 = 0.4375
        fc ≈ 48000 × (−ln(1−0.4375)) / (2π) ≈ 4425 Hz  (vs original 4500 Hz)
        The 75 Hz difference is inaudible; −12 dB/oct slope is identical.

    Parameters:
        fx_drive       - (fx_drive == 0) => UNITY, (fx_drive == 255) => 32.875x
        fx_mix         - (fx_mix == 0) => all dry, (fx_mix == 255) => all wet
        fx_makeup_gain - (fx_makeup_gain == 128) => UNITY

    Latency = 6 Samples

*/

module fx_distortion #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                             clk,
    input  logic                             reset_n,
    input  logic signed [1:0][DATA_W-1:0]   audio_in,
    output logic signed [1:0][DATA_W-1:0]   audio_out,
    input  logic [PARAM_W-1:0]              fx_drive,
    input  logic [PARAM_W-1:0]              fx_makeup_gain,
    input  logic [PARAM_W-1:0]              fx_mix,
    input  logic                            sample_en
);

    import lab_pkg::*;

    // -----------------------------------------------------------------------
    // CONSTANTS  —  Q15, kept 16-bit to avoid widening downstream signals
    // -----------------------------------------------------------------------

    localparam signed [15:0] ONE      =  16'sd32767;
    localparam signed [15:0] NEG_ONE  = -16'sd32767;
    localparam signed [15:0] TWO_THRD =  16'sd21845;
    localparam signed [15:0] BIAS     =  16'sd1638;   // +5% of full scale

    // -----------------------------------------------------------------------
    // DRIVE GAIN  (shared L+R)
    // -----------------------------------------------------------------------

    logic [15:0] drive_gain;
    assign drive_gain = 16'h0100 + ({8'h00, fx_drive} << 5);  // 1x–32.875x

    // -----------------------------------------------------------------------
    // PRE-EMPHASIS  —  0 DSPs
    // emph = x + (x - x_prev) >> 2   (identical to old * EMPH_K(64) >> 8)
    // -----------------------------------------------------------------------

    logic signed [15:0] audio_prev[1:0];  // x[n-1]
    logic signed [16:0] emph[1:0];        // 17-bit: audio_in ± 25% of delta

    always_comb begin
        for (int i = 0; i < 2; i++)
            emph[i] = $signed(audio_in[i]) +
                      ($signed($signed(audio_in[i]) - $signed(audio_prev[i])) >>> 2);
    end

    // -----------------------------------------------------------------------
    // STAGE 1 — DRIVE
    // 1 DSP: sat16 narrows emph to 16-bit before the multiply → 16x16 = 1 DSP.
    // Without sat16 the input would be 32-bit → 32×16 = 2 DSPs.
    // -----------------------------------------------------------------------

    logic signed [31:0] product[1:0];
    logic signed [31:0] product_reg[1:0];
    logic signed [31:0] x_raw[1:0];   // product_reg >>> 8, can exceed 16-bit range
    logic signed [15:0] x[1:0];       // biased + clamped to ±ONE

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            product[i] = $signed(sat16(emph[i])) * $signed({1'b0, drive_gain});
            x_raw[i]   = product_reg[i] >>> 8;

            // Asymmetric bias + clamp (comparisons in 32-bit, result assigned 16-bit)
            if      ($signed(x_raw[i]) + $signed(32'(BIAS)) >  $signed(32'(ONE)))    x[i] =  ONE;
            else if ($signed(x_raw[i]) + $signed(32'(BIAS)) < -$signed(32'(ONE)))    x[i] = NEG_ONE;
            else                                                                       x[i] = x_raw[i][15:0] + BIAS;
        end
    end

    // -----------------------------------------------------------------------
    // STAGE 2 — POLYNOMIAL  x² and x³
    //
    // (* multstyle = "logic" *) tells Quartus to implement these in LUT fabric
    // rather than DSP blocks.  Correct because:
    //   x   is 16-bit  →  x_sq 32-bit  (16×16)
    //   x_sq is 32-bit  →  x_cb 48-bit  (32×16)
    // Both are small enough that a few hundred LUTs is cheaper than 4–8 DSPs.
    // -----------------------------------------------------------------------

    (* multstyle = "logic" *) logic signed [31:0] x_sq[1:0];
    (* multstyle = "logic" *) logic signed [47:0] x_cb[1:0];
    logic signed [31:0] x_sq_reg[1:0];
    logic signed [47:0] x_cb_reg[1:0];

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            x_sq[i] = $signed(x[i])        * $signed(x[i]);        // 16×16 → 32-bit
            x_cb[i] = $signed(x_sq_reg[i]) * $signed(x[i]);        // 32×16 → 48-bit
        end
    end

    // -----------------------------------------------------------------------
    // STAGE 3 — NONLINEARITY
    //
    // cubic_term = x_cb_reg >>> 30  →  x³/32768² in Q15.
    // x is clamped to ±32767, so x³ ≤ 32767³ and x³>>>30 ≤ 32767: fits in 16-bit.
    //
    // Shift-based divide by 3 — 0 DSPs, error 0.39% (inaudible):
    //   x/3  ≈  (x + x>>2 + x>>4 + x>>6) >> 2  =  x × 85/256
    // -----------------------------------------------------------------------

    logic signed [15:0] cubic_term[1:0];
    logic signed [17:0] cubic_sum[1:0];   // 4 additions need 2 bits of headroom
    logic signed [15:0] cubic_div3[1:0];
    logic signed [15:0] distorted[1:0];
    logic signed [15:0] distorted_reg[1:0];

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

    // -----------------------------------------------------------------------
    // MIX + MAKEUP GAIN  —  0 DSPs each
    //
    // (* multstyle = "logic" *) keeps these in LUTs.  Both are 16×8-bit
    // multiplies (param is 8-bit, signal is 16-bit after saturation) which
    // synthesise to ~100 LUTs each — far cheaper than wasting a DSP block.
    // -----------------------------------------------------------------------

    (* multstyle = "logic" *) logic signed [24:0] mix_product[1:0];    // 17-bit × 8-bit
    (* multstyle = "logic" *) logic signed [23:0] makeup_product[1:0]; // 16-bit × 8-bit
    logic signed [15:0] mix_res[1:0];
    logic signed [15:0] mix_reg[1:0];
    logic signed [15:0] makeup[1:0];

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            // Blend: dry + (wet - dry) * mix / 256
            mix_product[i] = ($signed(distorted_reg[i]) - $signed(audio_in[i])) *
                             $signed({1'b0, fx_mix});
            mix_res[i]     = sat16($signed(audio_in[i]) + ($signed(mix_product[i]) >>> 8));

            // Makeup gain: unity at fx_makeup_gain = 128
            makeup_product[i] = $signed(mix_reg[i]) * $signed({1'b0, fx_makeup_gain});
            makeup[i]          = sat16($signed(makeup_product[i]) >>> 7);
        end
    end

    // -----------------------------------------------------------------------
    // SPEAKER CABINET  —  two cascaded one-pole IIR LPs, 0 DSPs
    //
    // α = 7/16 = (delta >> 1) − (delta >> 4):
    //     new_state = state + alpha * (input - state)
    //               = state + (delta>>1) - (delta>>4)
    //
    // Overflow proof: new_state = (1−α)×state + α×input.
    // Both state and input are bounded by ±32767, so new_state ≤ 32767. ✓
    // delta needs 17-bit signed; everything else fits in 16-bit.
    // -----------------------------------------------------------------------

    logic signed [15:0] cab1[1:0], cab2[1:0];     // LP state registers
    logic signed [16:0] d1[1:0],   d2[1:0];       // delta = input − state (17-bit)
    logic signed [15:0] cab1_n[1:0], cab2_n[1:0]; // next-state (combinational)

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            // Pole 1: tracks makeup
            d1[i]     = $signed(makeup[i])  - $signed(cab1[i]);
            cab1_n[i] = $signed(cab1[i]) + ($signed(d1[i]) >>> 1) - ($signed(d1[i]) >>> 4);

            // Pole 2: tracks cab1_n combinationally → true 2-pole in 1 FF stage
            d2[i]     = $signed(cab1_n[i]) - $signed(cab2[i]);
            cab2_n[i] = $signed(cab2[i]) + ($signed(d2[i]) >>> 1) - ($signed(d2[i]) >>> 4);
        end
    end

    // -----------------------------------------------------------------------
    // PIPELINE REGISTERS
    // -----------------------------------------------------------------------

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

    // -----------------------------------------------------------------------
    // OUTPUT
    // cab2_n is already ≤ 16-bit (proved in overflow proof above), no sat needed.
    // -----------------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            for (int i = 0; i < 2; i++)
                audio_out[i] <= cab2_n[i];
        end
    end

endmodule