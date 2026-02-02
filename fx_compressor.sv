/*

    Compressor that uses a peak envelope that reduces signals that exceed the 
    threshold by a ratio while leaving signals that are below the threshold unchanged.

    Parameters:
        fx_threshold - Threshold for signal that is scaled to have a range
                       of 0-24480 in relation to audio_in
        fx_ratio     - Ratio of gain reduction spanning from 1:1 (fx_ratio = 0) to 20:1
                       (fx_ratio = 255)
        fx_attack    - Time it takes for the compressor to apply gain reduction. 
                       Higher value means it takes longer to start gain reduction
                       once the envelope exceeds the threshold
        fx_release   - Time it takes for the compressor to release gain reduction. 
                       Higher value means it takes longer to release gain reduction
                       once the envelope drops below the threshold

    Latency = COMP_LOOKAHEAD + 1 = 17 Samples

 */

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

    // ---------------- INTERNAL SIGNALS ----------------

    // Delay Line for Lookahead
    logic signed [1:0][DATA_W-1:0] comp_delay_line [0:COMP_LOOKAHEAD-1];

    // Peak Detection
    logic [15:0] abs_l, abs_r;
    logic [15:0] peak_level;

    // Envelope
    logic [15:0] envelope;
    logic [15:0] att_step, rel_step;

    // Threshold + Gain Reduction
    logic [15:0] threshold_scaled;
    logic [15:0] comp_factor;
    logic signed [16:0] over_threshold;
    logic [31:0] reduction_amount;
    logic [15:0] target_gain;
    logic [15:0] gain;
    logic signed [31:0] prod_l, prod_r;
    logic [15:0] reduction;

    // ---------------- MAIN LOGIC -------------------

    // Deplay Line for "lookahead"  
    integer i;
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            for (i = 0; i < COMP_LOOKAHEAD; i = i + 1)
                comp_delay_line[i] <= '0;
        end else if (sample_en) begin
            comp_delay_line[0] <= audio_in;
            for (i = 1; i < COMP_LOOKAHEAD; i = i + 1)
                comp_delay_line[i] <= comp_delay_line[i-1];
        end
    end

    // Peak detection
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            peak_level <= '0;
        end else if (sample_en) begin
            abs_l = audio_in[0][15] ? -audio_in[0] : audio_in[0];
            abs_r = audio_in[1][15] ? -audio_in[1] : audio_in[1];
            peak_level <= (abs_l > abs_r) ? abs_l : abs_r;
        end
    end

    // Attack/Release Calculation
    always_comb begin
        att_step = 16'd512 + ({8'd0, fx_attack} << 4);
        rel_step = 16'd16  + ({8'd0, fx_release} << 2);
    end

    // Peak triggered envelope
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            envelope <= 16'd0;
        end else if (sample_en) begin
            if (peak_level > envelope)
                envelope <= (peak_level - envelope > att_step) ? envelope + att_step : peak_level;
            else if (peak_level < envelope)
                envelope <= (envelope - peak_level > rel_step) ? envelope - rel_step : peak_level;
        end
    end

    // Pre-calculated threshold and compression factor
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            threshold_scaled <= '0;
            comp_factor <= '0;
        end else begin
            // 1. Calculate threshold: fx_threshold (0-255) * 96 ≈ 0-24480
            threshold_scaled <= ({8'd0, fx_threshold} * 16'd96);
            
            // 2. Map fx_ratio (0-255) to comp_factor (1-0.5)
            comp_factor <= {8'd0, fx_ratio} * 16'd122;
        end
    end

    // Threshold Comparison  
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            over_threshold <= '0;
        end else if (sample_en) begin
            over_threshold <= $signed({1'b0, envelope}) - $signed({1'b0, threshold_scaled});
        end
    end

    // Gain reduction
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            reduction_amount <= '0;
        end else if (sample_en) begin
            if (over_threshold > 0)
                reduction_amount <= $unsigned(over_threshold) * comp_factor;
            else
                reduction_amount <= '0;
        end
    end

    // Target Gain calculation
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            target_gain <= UNITY_Q15;
        end else if (sample_en) begin
            if (over_threshold <= 0) begin
                target_gain <= UNITY_Q15;
            end else begin
                reduction = reduction_amount[30:15];                
                if (reduction >= UNITY_Q15)
                    target_gain <= MIN_GAIN;
                else
                    target_gain <= UNITY_Q15 - reduction;
            end
        end
    end

    // Gain Smoothing
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            gain <= UNITY_Q15;
        end else if (sample_en) begin
            if (gain < target_gain) begin
                if (target_gain - gain > 16'd32)
                    gain <= gain + 16'd32;
                else
                    gain <= target_gain;
            end else if (gain > target_gain) begin
                if (gain - target_gain > 16'd128)
                    gain <= gain - 16'd128;
                else
                    gain <= target_gain;
            end
        end
    end

    // Pipelined Application
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            prod_l <= '0;
            prod_r <= '0;
        end else if (sample_en) begin
            prod_l <= $signed(comp_delay_line[COMP_LOOKAHEAD-1][0]) * $signed({1'b0, gain});
            prod_r <= $signed(comp_delay_line[COMP_LOOKAHEAD-1][1]) * $signed({1'b0, gain});
        end
    end

    // -------------------- OUTPUT -------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            audio_out[0] <= sat16(prod_l >>> 15);
            audio_out[1] <= sat16(prod_r >>> 15);
        end
    end

endmodule

