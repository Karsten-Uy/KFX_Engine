/*
 * fx_reverb.sv
 *
 * Stereo Schroeder reverberator: parallel damped comb filters into series
 * all-pass filters.
 *
 * Refactored with generate blocks and DC pop fixes:
 *   - Rounding in all multiplies + shifts
 *   - DC blocking filter at output
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

    localparam ALLPASS_COEF = 8'd128;
    localparam FIXED_FB_GAIN = 9'sd236;
    localparam LP_FRAC_BITS = 16;

    // DC blocker coefficient for ~1 Hz cutoff at 48 kHz (Q16)
    localparam DC_ALPHA = 16'd65504;   // (1 - 2π*1/48000) << 16 ≈ 0.99987

    localparam int COMB_BASE[4] = '{COMB1_BASE, COMB2_BASE, COMB3_BASE, COMB4_BASE};
    localparam int ALLPASS_BASE[3] = '{ALLPASS1_DELAY, ALLPASS2_DELAY, ALLPASS3_DELAY};

    // ----------------------------------------------------------------
    // Signal Declarations
    // ----------------------------------------------------------------

    logic signed [DATA_W-1:0] comb_delayed [1:0][3:0];
    logic signed [31:0]       comb_fb      [1:0][3:0];
    logic signed [31:0]       comb_lp      [1:0][3:0];
    logic signed [DATA_W-1:0] comb_in      [1:0][3:0];

    logic signed [DATA_W-1:0] allpass_delayed [1:0][2:0];
    logic signed [DATA_W-1:0] allpass_in      [1:0][2:0];
    logic signed [DATA_W-1:0] allpass_out     [1:0][2:0];
    logic signed [31:0]       ap_feed         [1:0][2:0];
    logic signed [31:0]       ap_back         [1:0][2:0];

    logic signed [DATA_W+1:0] comb_sum [1:0];
    logic [COMB_ADDR_W-1:0]   comb_delay [3:0];
    logic [8:0]               lp_coef;

    // Wet signals before DC blocker
    logic signed [DATA_W-1:0] wet_L, wet_R;

    // DC blocker state
    logic signed [DATA_W-1:0] wet_L_prev, wet_R_prev;
    logic signed [31:0]       dc_state_L, dc_state_R;
    logic signed [DATA_W-1:0] wet_L_filt, wet_R_filt;

    // Mixing intermediates
    logic signed [31:0]       wet_scaled_L, wet_scaled_R;
    logic signed [31:0]       mixed_L, mixed_R;

    // ----------------------------------------------------------------
    // Shared Delay Calculations
    // ----------------------------------------------------------------

    always_comb begin
        for (int i = 0; i < 4; i++) begin
            comb_delay[i] = COMB_BASE[i] + ((COMB_BASE[i] * fx_size) >> 8);
        end
    end

    always_comb begin
        lp_coef = (9'd256 - {1'b0, fx_damping} < 9'd16) ? 9'd16 : 9'd256 - {1'b0, fx_damping};
    end

    // ----------------------------------------------------------------
    // Generate Comb Filters (4 per channel)
    // ----------------------------------------------------------------

    genvar ch_comb, i_comb;
    generate
        for (ch_comb = 0; ch_comb < 2; ch_comb++) begin : g_comb_ch
            for (i_comb = 0; i_comb < 4; i_comb++) begin : g_comb

                delay_line #(
                    .DATA_W(DATA_W),
                    .MAX_DELAY_SAMPLES(MAX_COMB_DELAY),
                    .ADDR_W(COMB_ADDR_W)
                ) comb_delay_inst (
                    .clk           (clk),
                    .reset_n       (reset_n),
                    .sample_en     (sample_en),
                    .data_in       (comb_in[ch_comb][i_comb]),
                    .data_out      (comb_delayed[ch_comb][i_comb]),
                    .delay_samples (comb_delay[i_comb])
                );

                // One‑pole LP state update with rounding (Q16)
                always_ff @(posedge clk) begin
                    if (!reset_n)
                        comb_lp[ch_comb][i_comb] <= '0;
                    else if (sample_en) begin
                        comb_lp[ch_comb][i_comb] <= comb_lp[ch_comb][i_comb] +
                            32'( (48'($signed(($signed(comb_delayed[ch_comb][i_comb]) <<< LP_FRAC_BITS) - comb_lp[ch_comb][i_comb])
                                  * 48'($signed({1'b0, lp_coef})) + 48'(1 << 7)) >>> 8 ));
                    end
                end

                // Feedback path with rounding (>>8)
                always_comb begin
                    comb_fb[ch_comb][i_comb] = ((comb_lp[ch_comb][i_comb] >>> LP_FRAC_BITS) * $signed(FIXED_FB_GAIN) + 32'(1 << 7)) >>> 8;
                    comb_in[ch_comb][i_comb] = sat16($signed(audio_in[ch_comb]) + comb_fb[ch_comb][i_comb]);
                end
            end
        end
    endgenerate

    // ----------------------------------------------------------------
    // Sum Parallel Comb Outputs (per channel)
    // ----------------------------------------------------------------

    always_comb begin
        for (int ch = 0; ch < 2; ch++) begin
            comb_sum[ch] = $signed(comb_delayed[ch][0]) +
                           $signed(comb_delayed[ch][1]) +
                           $signed(comb_delayed[ch][2]) +
                           $signed(comb_delayed[ch][3]);
        end
    end

    // ----------------------------------------------------------------
    // Generate All‑Pass Filters (3 in series per channel)
    // ----------------------------------------------------------------

    genvar ch_ap, j_ap;
    generate
        for (ch_ap = 0; ch_ap < 2; ch_ap++) begin : g_ap_ch
            for (j_ap = 0; j_ap < 3; j_ap++) begin : g_ap

                delay_line #(
                    .DATA_W(DATA_W),
                    .MAX_DELAY_SAMPLES(ALLPASS_BASE[j_ap]),
                    .ADDR_W(ALLPASS_ADDR_W)
                ) ap_delay_inst (
                    .clk           (clk),
                    .reset_n       (reset_n),
                    .sample_en     (sample_en),
                    .data_in       (allpass_in[ch_ap][j_ap]),
                    .data_out      (allpass_delayed[ch_ap][j_ap]),
                    .delay_samples (ALLPASS_BASE[j_ap][ALLPASS_ADDR_W-1:0])
                );

                always_comb begin
                    if (j_ap == 0)
                        allpass_in[ch_ap][j_ap] = sat16(comb_sum[ch_ap] >>> 2);
                    else
                        allpass_in[ch_ap][j_ap] = allpass_out[ch_ap][j_ap-1];

                    // All‑pass feed/back terms with rounding (>>8)
                    ap_feed[ch_ap][j_ap] = ($signed(allpass_in[ch_ap][j_ap]) * $signed({1'b0, ALLPASS_COEF}) + 32'(1 << 7)) >>> 8;
                    ap_back[ch_ap][j_ap] = ($signed(allpass_delayed[ch_ap][j_ap]) * $signed({1'b0, ALLPASS_COEF}) + 32'(1 << 7)) >>> 8;
                    allpass_out[ch_ap][j_ap] = sat16(-ap_feed[ch_ap][j_ap] + $signed(allpass_delayed[ch_ap][j_ap]) + ap_back[ch_ap][j_ap]);
                end
            end
        end
    endgenerate

    // ----------------------------------------------------------------
    // Wet Signals (before DC blocker)
    // ----------------------------------------------------------------

    assign wet_L = allpass_out[0][2];
    assign wet_R = allpass_out[1][2];

    // ----------------------------------------------------------------
    // DC Blocker (first‑order high‑pass, cutoff ≈1 Hz)
    // State is kept in Q16 to preserve precision.
    // ----------------------------------------------------------------

    logic signed [31:0] dc_state_L, dc_state_R;
    logic signed [DATA_W-1:0] wet_L_prev, wet_R_prev;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            wet_L_prev  <= '0;
            wet_R_prev  <= '0;
            dc_state_L  <= '0;
            dc_state_R  <= '0;
        end else if (sample_en) begin
            // Compute difference (Q0) and convert to Q16 by shifting left
            // The difference is up to 17 bits, so after shift it becomes up to 33 bits.
            // We'll use a 48-bit intermediate to avoid overflow.
            dc_state_L <= 32'( (48'($signed(wet_L) - $signed(wet_L_prev)) <<< 16) +
                            (48'($signed(dc_state_L) * DC_ALPHA) + 48'(1 << 15)) >>> 16 );
            dc_state_R <= 32'( (48'($signed(wet_R) - $signed(wet_R_prev)) <<< 16) +
                            (48'($signed(dc_state_R) * DC_ALPHA) + 48'(1 << 15)) >>> 16 );

            wet_L_prev <= wet_L;
            wet_R_prev <= wet_R;
        end
    end

    // Convert Q16 state back to Q0 for output (with saturation)
    logic signed [DATA_W-1:0] wet_L_filt, wet_R_filt;
    assign wet_L_filt = sat16(dc_state_L >>> 16);
    assign wet_R_filt = sat16(dc_state_R >>> 16);
    // ----------------------------------------------------------------
    // Mix (wet/dry blend) with rounding
    // ----------------------------------------------------------------

    always_comb begin
        wet_scaled_L = $signed(wet_L_filt) - $signed(audio_in[0]);
        wet_scaled_R = $signed(wet_R_filt) - $signed(audio_in[1]);
        mixed_L      = $signed(audio_in[0]) + ((wet_scaled_L * $signed({1'b0, fx_mix}) + 32'(1 << 7)) >>> 8);
        mixed_R      = $signed(audio_in[1]) + ((wet_scaled_R * $signed({1'b0, fx_mix}) + 32'(1 << 7)) >>> 8);
    end

    // ----------------------------------------------------------------
    // Output Register
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n)
            audio_out <= '0;
        else if (sample_en) begin
            audio_out[0] <= sat16(mixed_L);
            audio_out[1] <= sat16(mixed_R);
        end
    end

endmodule