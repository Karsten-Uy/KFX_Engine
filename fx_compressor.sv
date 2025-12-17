
module fx_compressor #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                          clk,
    input  logic                          reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,
    output logic signed [1:0][DATA_W-1:0] audio_out,
    input  logic [PARAM_W-1:0]            fx_threshold,
    input  logic [PARAM_W-1:0]            fx_ratio,
    input  logic [PARAM_W-1:0]            fx_attack,
    input  logic [PARAM_W-1:0]            fx_release,
    input  logic                          sample_en
);

    // ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;

    // -----------------------------
    // AUDIO LOOKAHEAD DELAY LINE
    // -----------------------------
    logic signed [1:0][DATA_W-1:0] audio_delay [0:COMP_LOOKAHEAD];

    integer i;
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            for (i = 0; i <= COMP_LOOKAHEAD; i = i + 1)
                audio_delay[i] <= '0;
        end else if (sample_en) begin
            audio_delay[0] <= audio_in;
            for (i = 1; i <= COMP_LOOKAHEAD; i = i + 1)
                audio_delay[i] <= audio_delay[i-1];
        end
    end

    // -----------------------------
    // PEAK LEVEL DETECTOR (Stereo-linked)
    // -----------------------------
    logic [15:0] abs_l, abs_r;
    logic [15:0] peak_level;

    always_comb begin
        abs_l = audio_in[0][15] ? -audio_in[0] : audio_in[0];
        abs_r = audio_in[1][15] ? -audio_in[1] : audio_in[1];
        peak_level = (abs_l > abs_r) ? abs_l : abs_r;  // Max of stereo
    end

    // -----------------------------
    // ENVELOPE FOLLOWER
    // -----------------------------
    logic [15:0] envelope;
    logic [15:0] att_step, rel_step;

    always_comb begin
        att_step = 16'd512 + ({8'd0, fx_attack} << 4);
        rel_step = 16'd16  + ({8'd0, fx_release} << 2);
    end

    always_ff @(posedge clk) begin
        if (!reset_n)
            envelope <= 16'd0;
        else if (sample_en) begin
            if (peak_level > envelope)
                envelope <= (peak_level - envelope > att_step) ? envelope + att_step : peak_level;
            else if (peak_level < envelope)
                envelope <= (envelope - peak_level > rel_step) ? envelope - rel_step : peak_level;
        end
    end

    // -----------------------------
    // GAIN COMPUTATION (SAFE)
    // -----------------------------
    logic [15:0] threshold_scaled;
    logic signed [16:0] over_threshold;
    logic [15:0] target_gain;

    // assign threshold_scaled = {fx_threshold, 7'd0};
    assign threshold_scaled = ({8'd0, fx_threshold} * 16'd96);  // 0-255 -> 0-24480

    assign over_threshold  = $signed({1'b0, envelope}) - $signed({1'b0, threshold_scaled});

    // Fix 2: Simplify compression factor calculation
    // For ratio R, we want: gain_reduction = (level_over_threshold) * (1 - 1/R)
    always_comb begin
        if (over_threshold <= 0) begin
            target_gain = UNITY_Q15;
        end else begin
            logic [31:0] reduction_amount;
            
            // Calculate: reduction = over_threshold * (ratio - 1) / ratio
            // In Q15: multiply by (32768 * (ratio-1) / ratio)
            if (fx_ratio <= 8'd1) begin
                // No compression (ratio 1:1)
                target_gain = UNITY_Q15;
            end else begin
                // Simplified: gain_reduction_factor in Q15
                logic [15:0] comp_factor;
                comp_factor = UNITY_Q15 - (UNITY_Q15 / {8'd0, fx_ratio});
                
                reduction_amount = ($unsigned(over_threshold) * comp_factor) >> 15;
                
                if (reduction_amount >= UNITY_Q15)
                    target_gain = MIN_GAIN;
                else
                    target_gain = UNITY_Q15 - reduction_amount[15:0];
            end
        end
    end

    // -----------------------------
    // GAIN SMOOTHING (CLAMPED)
    // -----------------------------
    logic [15:0] gain;

    always_ff @(posedge clk) begin
        if (!reset_n)
            gain <= UNITY_Q15;
        else if (sample_en) begin
            if (gain < target_gain)
                gain <= (gain + 16'd32 > UNITY_Q15) ? UNITY_Q15 : gain + 16'd32;
            else if (gain > target_gain)
                gain <= (gain - target_gain > 16'd128) ? gain - 16'd128 : target_gain;
        end
    end

    // assign gain = 16'h7FFF;

    // -----------------------------
    // APPLY GAIN TO DELAYED AUDIO
    // -----------------------------
    logic signed [31:0] prod_l, prod_r;

    always_comb begin
        // Multiply delayed audio by gain (both Q15)
        prod_l = $signed(audio_delay[COMP_LOOKAHEAD][0]) * $signed({1'b0,gain});
        prod_r = $signed(audio_delay[COMP_LOOKAHEAD][1]) * $signed({1'b0,gain});

    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            // Shift down by 15 bits and saturate
            audio_out[0] <= sat16(prod_l >>> 15);
            audio_out[1] <= sat16(prod_r >>> 15);

            // audio_out <= audio_in;
        end
    end

endmodule