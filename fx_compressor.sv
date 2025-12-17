
/*

    debug
        - tested
            - unity gain at end



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
    // PEAK ENVELOPE FOLLOWER
    // -----------------------------
    logic [15:0] envelope;
    logic [15:0] att_step, rel_step;

    // Convert attack/release parameters to step sizes
    always_comb begin
        // Faster attack = larger step
        att_step = 16'd256 + ({8'd0, fx_attack} << 3);  // Range: 256-2304
        // Slower release = smaller step  
        rel_step = 16'd8 + ({8'd0, fx_release} << 1);   // Range: 8-518
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            envelope <= 16'd0;
        end else if (sample_en) begin
            if (peak_level > envelope) begin
                // Attack: rise quickly toward peak
                if ((peak_level - envelope) > att_step)
                    envelope <= envelope + att_step;
                else
                    envelope <= peak_level;
            end else if (peak_level < envelope) begin
                // Release: fall slowly toward peak
                if ((envelope - peak_level) > rel_step)
                    envelope <= envelope - rel_step;
                else
                    envelope <= peak_level;
            end
            // If equal, envelope stays the same
        end
    end

    // -----------------------------
    // GAIN COMPUTATION (Hard Knee)
    // -----------------------------
    // Scale threshold from 0-255 to 0-32767
    logic [15:0] threshold_scaled;
    assign threshold_scaled = {fx_threshold, 7'd0} + {7'd0, fx_threshold, 1'b0};

    // Calculate how much signal exceeds threshold
    logic signed [16:0] over_threshold;
    assign over_threshold = $signed({1'b0, envelope}) - $signed({1'b0, threshold_scaled});

    // Calculate target gain
    logic [15:0] target_gain;
    
    always_comb begin
        if (over_threshold <= 0) begin
            // Below threshold: unity gain (1.0 in Q15)
            target_gain = 16'd32767;
        end else begin
            // Above threshold: apply compression ratio
            // Formula: gain_reduction = over * (1 - 1/ratio)
            
            logic [15:0] compression_factor;
            logic [31:0] reduction_amount;
            
            // Calculate (1 - 1/ratio) in Q15 fixed-point
            if (fx_ratio <= 8'd1) begin
                compression_factor = 16'd0;  // No compression (ratio 1:1)
            end else if (fx_ratio >= 8'd100) begin
                compression_factor = 16'd32440;  // Near-infinite ratio
            end else begin
                // compression_factor = 1 - 1/ratio = (ratio-1)/ratio
                // In Q15: 32768 * (ratio-1)/ratio = 32768 - 32768/ratio
                compression_factor = 16'd32768 - (16'd32768 / {8'd0, fx_ratio});
            end
            
            // Calculate gain reduction
            reduction_amount = $unsigned(over_threshold) * compression_factor;
            
            // Subtract from unity gain
            if (reduction_amount[30:15] >= 16'd32767) begin
                target_gain = 16'd100;  // Minimum gain floor
            end else begin
                target_gain = 16'd32767 - reduction_amount[30:15];
            end
        end
    end

    // -----------------------------
    // GAIN SMOOTHING
    // -----------------------------
    logic [15:0] gain;

    // always_ff @(posedge clk) begin
    //     if (!reset_n) begin
    //         gain <= 16'd32767;  // Unity gain
    //     end else if (sample_en) begin
    //         if (gain < target_gain) begin
    //             // Release: gain increasing (slower)
    //             if ((target_gain - gain) > 16'd32)
    //                 gain <= gain + 16'd32;
    //             else
    //                 gain <= target_gain;
    //         end else if (gain > target_gain) begin
    //             // Attack: gain decreasing (faster)
    //             if ((gain - target_gain) > 16'd128)
    //                 gain <= gain - 16'd128;
    //             else
    //                 gain <= target_gain;
    //         end
    //     end
    // end

    assign gain = 16'h7FFF;

    // -----------------------------
    // APPLY GAIN TO DELAYED AUDIO
    // -----------------------------
    logic signed [31:0] prod_l, prod_r;

    always_comb begin
        // Multiply delayed audio by gain (both Q15)
        // prod_l = audio_delay[COMP_LOOKAHEAD][0] * $signed({1'b0, gain});
        // prod_r = audio_delay[COMP_LOOKAHEAD][1] * $signed({1'b0, gain});

        prod_l = audio_in[0] * $signed({1'b0, gain});
        prod_r = audio_in[1] * $signed({1'b0, gain});
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            // Shift down by 15 bits and saturate
            audio_out[0] <= sat16(prod_l >>> 15);
            audio_out[1] <= sat16(prod_r >>> 15);
        end
    end

endmodule