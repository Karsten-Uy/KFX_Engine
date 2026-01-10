/*

    Based of design described here:
        https://www.kvraudio.com/forum/viewtopic.php?t=112226

*/


module fx_eq #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                          clk,
    input  logic                          reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,
    output logic signed [1:0][DATA_W-1:0] audio_out,

    input  logic [PARAM_W-1:0]            fx_low_gain,
    input  logic [PARAM_W-1:0]            fx_mid_gain,
    input  logic [PARAM_W-1:0]            fx_high_gain,

    input  logic                          sample_en
);

    import lab_pkg::*; // sat16()

    // ------------------------------------------------------------
    // COEFFICIENTS (Q16 fixed-point for better precision on slow filter)
    // a: 13312/48000 = 0.277333 -> Q16 = 18186
    // b: 1664/48000  = 0.034667 -> Q16 = 2273
    // c: 104/48000   = 0.002167 -> Q16 = 142
    // ------------------------------------------------------------
    localparam signed [31:0] COEFF_A = 32'sd18186;
    localparam signed [31:0] COEFF_B = 32'sd2273;
    localparam signed [31:0] COEFF_C = 32'sd142;

    // ------------------------------------------------------------
    // FILTER STATE (Q16 internally for precision)
    // ------------------------------------------------------------
    logic signed [31:0] a_state[1:0];
    logic signed [31:0] b_state[1:0];
    logic signed [31:0] c_state[1:0];

    // Convert input to Q16
    logic signed [31:0] input_q16[1:0];

    // Intermediate calculations
    logic signed [47:0] diff_a[1:0];
    logic signed [47:0] diff_b[1:0]; 
    logic signed [47:0] diff_c[1:0];
    
    logic signed [47:0] mult_a[1:0];
    logic signed [47:0] mult_b[1:0];
    logic signed [47:0] mult_c[1:0];

    logic signed [31:0] a_next[1:0];
    logic signed [31:0] b_next[1:0];
    logic signed [31:0] c_next[1:0];

    // Band signals (extract from NEXT state, not current)
    logic signed [15:0] a_q15[1:0];
    logic signed [15:0] b_q15[1:0];
    logic signed [15:0] c_q15[1:0];
    
    logic signed [15:0] band_high[1:0];
    logic signed [15:0] band_mid[1:0];
    logic signed [15:0] band_low[1:0];
    logic signed [15:0] band_lowpass[1:0];

    // Gain (Q15, 128 = unity = 1.0)
    logic signed [15:0] g_high, g_mid, g_low;
    assign g_high = fx_high_gain << 7; // NOTE: has to be 7, not 8 to have 128 be unity
    assign g_mid  = fx_mid_gain  << 7; // NOTE: has to be 7, not 8 to have 128 be unity
    assign g_low  = fx_low_gain  << 7; // NOTE: has to be 7, not 8 to have 128 be unity

    // Output accumulator
    logic signed [31:0] temp_high[1:0];
    logic signed [31:0] temp_mid[1:0];
    logic signed [31:0] temp_low[1:0];
    logic signed [31:0] temp_lowpass[1:0];
    logic signed [31:0] out_sum[1:0];

    // Pipeline
    logic signed [1:0][DATA_W-1:0] audio_in_reg;
    logic signed [15:0] a_q15_reg[1:0];
    logic signed [15:0] b_q15_reg[1:0];
    logic signed [15:0] c_q15_reg[1:0];

    // ------------------------------------------------------------
    // FILTER UPDATE LOGIC
    // a += coeff * (input - a)
    // b += coeff * (input - b)  
    // c += coeff * (input - c)
    // ------------------------------------------------------------
    always_comb begin
        for (int ch = 0; ch < 2; ch++) begin
            // Convert input to Q16 (shift left by 1)
            input_q16[ch] = {audio_in[ch], 16'd0};

            // Calculate differences (Q16 - Q16)
            diff_a[ch] = input_q16[ch] - a_state[ch];
            diff_b[ch] = input_q16[ch] - b_state[ch];
            diff_c[ch] = input_q16[ch] - c_state[ch];

            // Multiply by coefficients (Q16 * Q16 = Q32)
            mult_a[ch] = diff_a[ch] * COEFF_A;
            mult_b[ch] = diff_b[ch] * COEFF_B;
            mult_c[ch] = diff_c[ch] * COEFF_C;

            // Calculate next state (shift right by 16 to get back to Q16)
            a_next[ch] = a_state[ch] + (mult_a[ch] >>> 16);
            b_next[ch] = b_state[ch] + (mult_b[ch] >>> 16);
            c_next[ch] = c_state[ch] + (mult_c[ch] >>> 16);

            // Convert states to Q15 for band extraction
            a_q15[ch] = a_next[ch][31:16];
            b_q15[ch] = b_next[ch][31:16];
            c_q15[ch] = c_next[ch][31:16];

            // // Extract frequency bands using NEXT state
            // band_high[ch]    = audio_in[ch] - a_q15[ch];
            // band_mid[ch]     = a_q15[ch] - b_q15[ch];
            // band_low[ch]     = b_q15[ch] - c_q15[ch];
            // band_lowpass[ch] = c_q15[ch];

            // Extract frequency bands using NEXT state
            // band_high[ch]    = audio_in[ch] - a_q15_reg[ch];
            band_high[ch]    = audio_in_reg[ch] - a_q15_reg[ch];
            band_mid[ch]     = a_q15_reg[ch] - b_q15_reg[ch];
            band_low[ch]     = b_q15_reg[ch] - c_q15_reg[ch];
            band_lowpass[ch] = c_q15_reg[ch];

            // Apply gains (Q15 * Q15 = Q30, shift to Q15)
            temp_high[ch]    = (band_high[ch] * g_high) >>> 15;
            temp_mid[ch]     = (band_mid[ch] * g_mid) >>> 15;
            temp_low[ch]     = (band_low[ch] * g_low) >>> 15;
            temp_lowpass[ch] = (band_lowpass[ch] * g_low) >>> 15;

            // Sum all bands
            out_sum[ch] = temp_high[ch] + temp_mid[ch] + temp_low[ch] + temp_lowpass[ch];
        end
    end

    // ------------------------------------------------------------
    // STATE UPDATE + OUTPUT
    // ------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
            for (int i = 0; i < 2; i++) begin
                a_state[i] <= 32'sd0;
                b_state[i] <= 32'sd0;
                c_state[i] <= 32'sd0;

                a_q15_reg[i] <= '0;
                b_q15_reg[i] <= '0;
                c_q15_reg[i] <= '0;
            end
        end
        else if (sample_en) begin
            for (int i = 0; i < 2; i++) begin
                // Update filter states
                a_state[i] <= a_next[i];
                b_state[i] <= b_next[i];
                c_state[i] <= c_next[i];

                // Output with saturation
                audio_out[i] <= sat16(out_sum[i]);
                audio_in_reg[i] <= audio_in[i];

                // Pipeline
                a_q15_reg <= a_q15;
                b_q15_reg <= b_q15;
                c_q15_reg <= c_q15;
            end
        end
    end

endmodule