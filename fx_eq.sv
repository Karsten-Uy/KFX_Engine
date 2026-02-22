/*

    4 Band EQ that splits the signals into High, Mid, Low, and Sub bands and then
    applies a gain to each band

    Parameters:
        fx_low_gain  - gain multiplier for the low band where 128 => UNITY
        fx_mid_gain  - gain multiplier for the mid band where 128 => UNITY
        fx_high_gain - gain multiplier for the high band where 128 => UNITY

    Based of design described here:
        https://www.kvraudio.com/forum/viewtopic.php?t=112226

    Made from 3 "Leaky Integrator" low pass filters that are used to split the audio 
    into 4 bands and have the following difference equation where a is a coefficent, y[n] is
    the output at sample n, and x[n] is the input at sample n:

        y[n] = y[n-1] + a(x[n] - y[n-1])

    The 3 bands are split in a subtractive crossover method that has a flat impulse response 
    when the gain of all of them are the same when summed up. From here on the filters
    outputs are going to be referenced as filter_a and filter_b. The bands are split in the
    following way:

        - band_high[n] = audio_in[n] - filter_a[n]
        - band_mid[n]  = filter_a[n] - filter_b[n]
        - band_low[n]  = filter_b[n] - filter_c[n]
        - band_sub[n]  = filter_c[n]

    The output is then following:

        - audio_out[n] = (band_high[n]*fx_high_gain) + (band_mid[n]*fx_mid_gain) + (band_low[n]*fx_low_gain) + (band_sub[n]*fx_sub_gain) 
        
    Latency = 2 Samples

    DSP reduction vs original:
        - Gain multiplies: old form was (band * (fx_gain<<7)) >> 15 — a 16x16
          multiply. Simplified to (band * fx_gain) >> 8 which is a 16x8 multiply.
          Quartus fits 16x8 entirely in LUT fabric. Saves 8 DSPs (4 bands x 2 ch).
        - diff signals narrowed from 48-bit to 33-bit (the true max width of a
          32-bit minus 32-bit difference). This halves the multiplier width seen
          by the coefficient multiplies, reducing their DSP cost.
        - Coefficient multiplies marked (* multstyle = "logic" *) so Quartus
          implements them as shift-add trees rather than DSP blocks. The
          coefficients are compile-time constants so this is lossless.

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

    // ---------------- CONSTANTS ----------------
    // COEFFICIENTS (Q16 fixed-point)
    localparam signed [31:0] COEFF_A = 32'sd18186;
    localparam signed [31:0] COEFF_B = 32'sd2273;
    localparam signed [31:0] COEFF_C = 32'sd142;

    // ---------------- INTERNAL SIGNALS ----------------

    // Filter state (Q16 internally for precision)
    logic signed [31:0] a_state [1:0];
    logic signed [31:0] b_state [1:0];
    logic signed [31:0] c_state [1:0];

    // Convert input to Q16
    logic signed [31:0] input_q16 [1:0];

    // Narrowed diff signals: 32-bit - 32-bit = 33-bit max.
    // Original declared these as 48-bit which made the coefficient
    // multiplier appear as a 48x32 operation to the fitter.
    logic signed [32:0] diff_a [1:0];
    logic signed [32:0] diff_b [1:0];
    logic signed [32:0] diff_c [1:0];

    // Coefficient multiply results. (* multstyle = "logic" *) forces Quartus
    // to use a shift-add tree rather than a DSP block. Safe because COEFF_x
    // are compile-time constants -- no runtime information is lost.
    (* multstyle = "logic" *) logic signed [63:0] mult_a [1:0];
    (* multstyle = "logic" *) logic signed [63:0] mult_b [1:0];
    (* multstyle = "logic" *) logic signed [63:0] mult_c [1:0];

    logic signed [31:0] a_next [1:0];
    logic signed [31:0] b_next [1:0];
    logic signed [31:0] c_next [1:0];

    // Band signals (Q15)
    logic signed [15:0] a_q15 [1:0];
    logic signed [15:0] b_q15 [1:0];
    logic signed [15:0] c_q15 [1:0];
    logic signed [15:0] band_high    [1:0];
    logic signed [15:0] band_mid     [1:0];
    logic signed [15:0] band_low     [1:0];
    logic signed [15:0] band_lowpass [1:0];

    // Output accumulator
    logic signed [31:0] temp_high    [1:0];
    logic signed [31:0] temp_mid     [1:0];
    logic signed [31:0] temp_low     [1:0];
    logic signed [31:0] temp_lowpass [1:0];
    logic signed [31:0] out_sum      [1:0];

    // Pipeline
    logic signed [1:0][DATA_W-1:0] audio_in_reg;
    logic signed [15:0] a_q15_reg [1:0];
    logic signed [15:0] b_q15_reg [1:0];
    logic signed [15:0] c_q15_reg [1:0];

    // ---------------- FILTER + BAND LOGIC ----------------
    always_comb begin
        for (int ch = 0; ch < 2; ch++) begin
            // Convert input to Q16
            input_q16[ch] = {audio_in[ch], 16'd0};

            // 33-bit differences (true bit-width of 32-bit subtraction)
            diff_a[ch] = 33'($signed(input_q16[ch])) - 33'($signed(a_state[ch]));
            diff_b[ch] = 33'($signed(input_q16[ch])) - 33'($signed(b_state[ch]));
            diff_c[ch] = 33'($signed(input_q16[ch])) - 33'($signed(c_state[ch]));

            // Coefficient multiplies: 33x32 constant -> LUT shift-add trees
            mult_a[ch] = $signed(diff_a[ch]) * COEFF_A;
            mult_b[ch] = $signed(diff_b[ch]) * COEFF_B;
            mult_c[ch] = $signed(diff_c[ch]) * COEFF_C;

            // Next filter states (shift right 16 to stay in Q16)
            a_next[ch] = a_state[ch] + 32'($signed(mult_a[ch]) >>> 16);
            b_next[ch] = b_state[ch] + 32'($signed(mult_b[ch]) >>> 16);
            c_next[ch] = c_state[ch] + 32'($signed(mult_c[ch]) >>> 16);

            // Extract Q15 from Q16 state
            a_q15[ch] = a_next[ch][31:16];
            b_q15[ch] = b_next[ch][31:16];
            c_q15[ch] = c_next[ch][31:16];

            // Subtractive crossover band extraction
            band_high[ch]    = audio_in_reg[ch] - a_q15_reg[ch];
            band_mid[ch]     = a_q15_reg[ch]    - b_q15_reg[ch];
            band_low[ch]     = b_q15_reg[ch]    - c_q15_reg[ch];
            band_lowpass[ch] = c_q15_reg[ch];

            // KEY DSP SAVING: gain multiply simplified from:
            //   (band * (fx_gain << 7)) >> 15   [16x16 = 1 DSP each]
            // to:
            //   (band * fx_gain) >> 8            [16x8  = LUT fabric]
            // These are mathematically identical. Saves 8 DSPs total.
            temp_high[ch]    = ($signed(band_high[ch])    * $signed({1'b0, fx_high_gain})) >>> 8;
            temp_mid[ch]     = ($signed(band_mid[ch])     * $signed({1'b0, fx_mid_gain}))  >>> 8;
            temp_low[ch]     = ($signed(band_low[ch])     * $signed({1'b0, fx_low_gain}))  >>> 8;
            temp_lowpass[ch] = ($signed(band_lowpass[ch]) * $signed({1'b0, fx_sub_gain}))  >>> 8;

            // Sum all bands
            out_sum[ch] = temp_high[ch] + temp_mid[ch] + temp_low[ch] + temp_lowpass[ch];
        end
    end

    // ------------------ STATE UPDATE + OUTPUT ------------------
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
            for (int i = 0; i < 2; i++) begin
                a_state[i] <= '0;
                b_state[i] <= '0;
                c_state[i] <= '0;
                a_q15_reg[i] <= '0;
                b_q15_reg[i] <= '0;
                c_q15_reg[i] <= '0;
                audio_in_reg[i] <= '0;
            end
        end else if (sample_en) begin
            for (int i = 0; i < 2; i++) begin
                a_state[i] <= a_next[i];
                b_state[i] <= b_next[i];
                c_state[i] <= c_next[i];

                audio_in_reg[i] <= audio_in[i];
                a_q15_reg[i]    <= a_q15[i];
                b_q15_reg[i]    <= b_q15[i];
                c_q15_reg[i]    <= c_q15[i];

                audio_out[i] <= sat16(out_sum[i]);
            end
        end
    end

endmodule