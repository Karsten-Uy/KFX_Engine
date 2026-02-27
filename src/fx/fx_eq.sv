/*
 * fx_eq.sv
 *
 * Four-band parametric EQ: Sub, Low, Mid, High.
 *
 * Architecture
 * ------------
 * Three cascaded leaky-integrator (one-pole IIR) low-pass filters split the
 * signal into four bands using a subtractive crossover.  The difference
 * equation for each filter is:
 *
 *   y[n] = y[n-1] + a * (x[n] - y[n-1])
 *
 * where a is a Q16 fixed-point coefficient.  Band extraction:
 *
 *   band_high[n]    = audio_in[n] - filter_a[n]
 *   band_mid[n]     = filter_a[n] - filter_b[n]
 *   band_low[n]     = filter_b[n] - filter_c[n]
 *   band_sub[n]     = filter_c[n]
 *
 * This subtractive crossover has a flat magnitude response when all gains
 * are equal, so unity on all four bands = transparent pass-through.
 *
 * Filter coefficients  (Q16, derived for 48 kHz)
 * -----------------------------------------------
 *   COEFF_A = 18186  (high / mid split)
 *   COEFF_B =  2273  (mid / low split)
 *   COEFF_C =   142  (low / sub split)
 *
 * DSP optimisations
 * -----------------
 *   Coefficient multiplies use (* multstyle = "logic" *) to force Quartus
 *   into LUT shift-add trees rather than DSP blocks; safe because COEFF_x
 *   are compile-time constants.
 *
 *   Band gain multiplies are simplified from (band * (fx_gain<<7)) >> 15
 *   (16×16, 1 DSP each) to (band * fx_gain) >> 8 (16×8, fits in LUTs).
 *   Saves 8 DSP blocks total (4 bands × 2 channels).
 *
 *   Diff signals narrowed from 48-bit to 33-bit (true max for 32-bit
 *   subtraction), halving the coefficient multiply width seen by the fitter.
 *
 * Latency: 2 samples.
 *
 * Ports
 * -----
 *   audio_in      — stereo signed 16-bit input
 *   audio_out     — stereo signed 16-bit output
 *   fx_sub_gain   — sub band gain  (128 = unity)
 *   fx_low_gain   — low band gain  (128 = unity)
 *   fx_mid_gain   — mid band gain  (128 = unity)
 *   fx_high_gain  — high band gain (128 = unity)
 *   sample_en     — single-cycle sample strobe
 */

module fx_eq #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                          clk,
    input  logic                          reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,
    output logic signed [1:0][DATA_W-1:0] audio_out,
    input  logic [PARAM_W-1:0]            fx_sub_gain,
    input  logic [PARAM_W-1:0]            fx_low_gain,
    input  logic [PARAM_W-1:0]            fx_mid_gain,
    input  logic [PARAM_W-1:0]            fx_high_gain,
    input  logic                          sample_en
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Filter Coefficients  (Q16 fixed-point)
    //
    // Local to this module — these are algorithm parameters specific to
    // the leaky-integrator EQ design and do not belong in lab_pkg.
    // ----------------------------------------------------------------

    localparam signed [31:0] COEFF_A = 32'sd18186;
    localparam signed [31:0] COEFF_B = 32'sd2273;
    localparam signed [31:0] COEFF_C = 32'sd142;

    // ----------------------------------------------------------------
    // Internal Signals
    // ----------------------------------------------------------------

    // Filter state in Q16 (32-bit for precision)
    logic signed [31:0] a_state [1:0];
    logic signed [31:0] b_state [1:0];
    logic signed [31:0] c_state [1:0];

    logic signed [31:0] input_q16 [1:0];  // audio_in promoted to Q16

    // 33-bit differences: true bit-width of 32-bit subtraction.
    // Using 33 bits (vs the original 48) halves the coefficient multiply
    // width and allows Quartus to use shift-add trees instead of DSPs.
    logic signed [32:0] diff_a [1:0];
    logic signed [32:0] diff_b [1:0];
    logic signed [32:0] diff_c [1:0];

    // Coefficient multiply results — LUT fabric via multstyle hint
    (* multstyle = "logic" *) logic signed [63:0] mult_a [1:0];
    (* multstyle = "logic" *) logic signed [63:0] mult_b [1:0];
    (* multstyle = "logic" *) logic signed [63:0] mult_c [1:0];

    logic signed [31:0] a_next [1:0];
    logic signed [31:0] b_next [1:0];
    logic signed [31:0] c_next [1:0];

    // Band signals in Q15
    logic signed [15:0] a_q15 [1:0];
    logic signed [15:0] b_q15 [1:0];
    logic signed [15:0] c_q15 [1:0];
    logic signed [15:0] band_high    [1:0];
    logic signed [15:0] band_mid     [1:0];
    logic signed [15:0] band_low     [1:0];
    logic signed [15:0] band_lowpass [1:0];

    // Per-band gain products and output accumulator
    logic signed [31:0] temp_high    [1:0];
    logic signed [31:0] temp_mid     [1:0];
    logic signed [31:0] temp_low     [1:0];
    logic signed [31:0] temp_lowpass [1:0];
    logic signed [31:0] out_sum      [1:0];

    // Pipeline registers — delay audio_in and Q15 filter outputs by one
    // sample so they align with the band-extraction subtraction
    logic signed [1:0][DATA_W-1:0] audio_in_reg;
    logic signed [15:0] a_q15_reg [1:0];
    logic signed [15:0] b_q15_reg [1:0];
    logic signed [15:0] c_q15_reg [1:0];

    // ----------------------------------------------------------------
    // Filter and Band Computation  (combinational)
    // ----------------------------------------------------------------

    always_comb begin
        for (int ch = 0; ch < 2; ch++) begin
            // Promote 16-bit input to Q16 for filter arithmetic
            input_q16[ch] = {audio_in[ch], 16'd0};

            // 33-bit differences (prevents 32-bit overflow on subtraction)
            diff_a[ch] = 33'($signed(input_q16[ch])) - 33'($signed(a_state[ch]));
            diff_b[ch] = 33'($signed(input_q16[ch])) - 33'($signed(b_state[ch]));
            diff_c[ch] = 33'($signed(input_q16[ch])) - 33'($signed(c_state[ch]));

            // Leaky-integrator update: state += (diff * coeff) >> 16
            mult_a[ch] = $signed(diff_a[ch]) * COEFF_A;
            mult_b[ch] = $signed(diff_b[ch]) * COEFF_B;
            mult_c[ch] = $signed(diff_c[ch]) * COEFF_C;

            a_next[ch] = a_state[ch] + 32'($signed(mult_a[ch]) >>> 16);
            b_next[ch] = b_state[ch] + 32'($signed(mult_b[ch]) >>> 16);
            c_next[ch] = c_state[ch] + 32'($signed(mult_c[ch]) >>> 16);

            // Extract Q15 output (upper 16 bits of Q16 state)
            a_q15[ch] = a_next[ch][31:16];
            b_q15[ch] = b_next[ch][31:16];
            c_q15[ch] = c_next[ch][31:16];

            // Subtractive crossover (uses registered Q15 values for pipeline alignment)
            band_high[ch]    = audio_in_reg[ch] - a_q15_reg[ch];
            band_mid[ch]     = a_q15_reg[ch]    - b_q15_reg[ch];
            band_low[ch]     = b_q15_reg[ch]    - c_q15_reg[ch];
            band_lowpass[ch] = c_q15_reg[ch];

            // Band gain: (band * fx_gain) >> 8   (16x8-bit, fits in LUT fabric)
            temp_high[ch]    = ($signed(band_high[ch])    * $signed({1'b0, fx_high_gain})) >>> 8;
            temp_mid[ch]     = ($signed(band_mid[ch])     * $signed({1'b0, fx_mid_gain}))  >>> 8;
            temp_low[ch]     = ($signed(band_low[ch])     * $signed({1'b0, fx_low_gain}))  >>> 8;
            temp_lowpass[ch] = ($signed(band_lowpass[ch]) * $signed({1'b0, fx_sub_gain}))  >>> 8;

            out_sum[ch] = temp_high[ch] + temp_mid[ch] + temp_low[ch] + temp_lowpass[ch];
        end
    end

    // ----------------------------------------------------------------
    // State Update and Output Register
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
            for (int i = 0; i < 2; i++) begin
                a_state[i]      <= '0;
                b_state[i]      <= '0;
                c_state[i]      <= '0;
                a_q15_reg[i]    <= '0;
                b_q15_reg[i]    <= '0;
                c_q15_reg[i]    <= '0;
                audio_in_reg[i] <= '0;
            end
        end else if (sample_en) begin
            for (int i = 0; i < 2; i++) begin
                a_state[i] <= a_next[i];
                b_state[i] <= b_next[i];
                c_state[i] <= c_next[i];

                // Register audio and Q15 values to align with band subtraction
                audio_in_reg[i] <= audio_in[i];
                a_q15_reg[i]    <= a_q15[i];
                b_q15_reg[i]    <= b_q15[i];
                c_q15_reg[i]    <= c_q15[i];

                audio_out[i] <= sat16(out_sum[i]);
            end
        end
    end

endmodule