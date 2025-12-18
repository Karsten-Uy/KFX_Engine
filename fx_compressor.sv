
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

    import lab_pkg::*;

    // ========================================
    // STAGE 1: INPUT + DELAY LINE
    // ========================================
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

    // ========================================
    // STAGE 2: PEAK DETECTION (Registered)
    // ========================================
    logic [15:0] abs_l, abs_r;
    logic [15:0] peak_level;
    
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            peak_level <= '0;
        end else if (sample_en) begin
            abs_l = audio_in[0][15] ? -audio_in[0] : audio_in[0];
            abs_r = audio_in[1][15] ? -audio_in[1] : audio_in[1];
            peak_level <= (abs_l > abs_r) ? abs_l : abs_r;
        end
    end

    // ========================================
    // STAGE 3: ENVELOPE FOLLOWER (Registered)
    // ========================================
    logic [15:0] envelope;
    logic [15:0] att_step, rel_step;

    always_comb begin
        att_step = 16'd512 + ({8'd0, fx_attack} << 4);
        rel_step = 16'd16  + ({8'd0, fx_release} << 2);
    end

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

    // ========================================
    // PARAMETER PRE-CALCULATION (Registered)
    // Avoid division in critical path!
    // ========================================
    logic [15:0] threshold_scaled;
    logic [15:0] comp_factor;  // Pre-calculated compression factor
    
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            threshold_scaled <= '0;
            comp_factor <= '0;
        end else begin
            // Calculate once when parameters change (not in sample_en path)
            threshold_scaled <= ({8'd0, fx_threshold} * 16'd96);
            
            // Pre-calculate compression factor using LOOKUP TABLE
            // This avoids expensive division!
            case (fx_ratio)
                8'd0, 8'd1: comp_factor <= 16'd0;      // 1:1 (no compression)
                8'd2: comp_factor <= 16'd16384;        // 2:1 (0.5)
                8'd3: comp_factor <= 16'd21845;        // 3:1 (0.667)
                8'd4: comp_factor <= 16'd24576;        // 4:1 (0.75)
                8'd5: comp_factor <= 16'd26214;        // 5:1 (0.8)
                8'd6: comp_factor <= 16'd27306;        // 6:1 (0.833)
                8'd8: comp_factor <= 16'd28672;        // 8:1 (0.875)
                8'd10: comp_factor <= 16'd29491;       // 10:1 (0.9)
                8'd12: comp_factor <= 16'd29989;       // 12:1 (0.916)
                8'd16: comp_factor <= 16'd30720;       // 16:1 (0.9375)
                8'd20: comp_factor <= 16'd31129;       // 20:1 (0.95)
                default: begin
                    // Approximation for other values
                    if (fx_ratio < 8'd10)
                        comp_factor <= 16'd28000;      // ~8:1
                    else
                        comp_factor <= 16'd30000;      // ~15:1
                end
            endcase
        end
    end

    // ========================================
    // STAGE 4: THRESHOLD COMPARISON (Registered)
    // ========================================
    logic signed [16:0] over_threshold;
    
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            over_threshold <= '0;
        end else if (sample_en) begin
            over_threshold <= $signed({1'b0, envelope}) - $signed({1'b0, threshold_scaled});
        end
    end

    // ========================================
    // STAGE 5: GAIN REDUCTION (Registered multiply)
    // ========================================
    logic [31:0] reduction_amount;
    
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

    // ========================================
    // STAGE 6: TARGET GAIN CALCULATION (Registered)
    // ========================================
    logic [15:0] target_gain;
    
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            target_gain <= UNITY_Q15;
        end else if (sample_en) begin
            if (over_threshold <= 0) begin
                target_gain <= UNITY_Q15;
            end else begin
                logic [15:0] reduction;
                reduction = reduction_amount[30:15];  // Extract Q15 result
                
                if (reduction >= UNITY_Q15)
                    target_gain <= MIN_GAIN;
                else
                    target_gain <= UNITY_Q15 - reduction;
            end
        end
    end

    // ========================================
    // STAGE 7: GAIN SMOOTHING (Registered)
    // ========================================
    logic [15:0] gain;

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

    // assign gain = UNITY_Q15;

    // ========================================
    // STAGE 8: APPLY GAIN (Registered multiply)
    // ========================================
    logic signed [31:0] prod_l, prod_r;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            prod_l <= '0;
            prod_r <= '0;
        end else if (sample_en) begin
            prod_l <= $signed(audio_delay[COMP_LOOKAHEAD][0]) * $signed({1'b0, gain});
            prod_r <= $signed(audio_delay[COMP_LOOKAHEAD][1]) * $signed({1'b0, gain});
        end
    end

    // ========================================
    // STAGE 9: OUTPUT (Registered)
    // ========================================
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            audio_out[0] <= sat16(prod_l >>> 15);
            audio_out[1] <= sat16(prod_r >>> 15);
        end
    end

endmodule

