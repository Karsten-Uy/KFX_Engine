// EQ (FX 2)
module fx_eq #(
    parameter DATA_W  = 16,
    PARAM_W = 8
)(
    input  logic                      clk,
    input  logic                      reset_n,
    input  logic [1:0][DATA_W-1:0]    audio_in,   // Stereo input
    output logic [1:0][DATA_W-1:0]    audio_out,  // Stereo output
    input  logic [PARAM_W-1:0]        fx_low_gain,   // Low frequency gain
    input  logic [PARAM_W-1:0]        fx_mid_gain,   // Mid frequency gain
    input  logic [PARAM_W-1:0]        fx_high_gain,  // High frequency gain
    input  logic [PARAM_W-1:0]        fx_presence,    // Presence control
    input  logic                      sample_en
);    
    
    // ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;

    // ========================================
    // FIRST-ORDER LOW SHELF (~200 Hz)
    // ========================================
    logic signed [15:0] low_y [1:0];    // Output
    logic signed [15:0] low_x1 [1:0];   // Previous input
    logic signed [15:0] low_y1 [1:0];   // Previous output
    
    // Convert gain parameter (0-255, center=32) to gain multiplier
    logic signed [15:0] low_gain_mult;
    assign low_gain_mult = $signed({1'b0, fx_low_gain}) - 16'sd32;  // -32 to +223
    
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            for (int ch = 0; ch < 2; ch++) begin
                low_y[ch] <= '0;
                low_x1[ch] <= '0;
                low_y1[ch] <= '0;
            end
        end else if (sample_en) begin
            for (int ch = 0; ch < 2; ch++) begin
                logic signed [31:0] acc;
                
                // Basic filter: y[n] = b0*x[n] + b1*x[n-1] - a1*y[n-1]
                acc = (LOW_B0 * audio_in[ch]) + 
                      (LOW_B1 * low_x1[ch]) - 
                      (LOW_A1 * low_y1[ch]);
                
                low_y[ch] <= sat16(acc >>> 15);
                low_x1[ch] <= audio_in[ch];
                low_y1[ch] <= low_y[ch];
            end
        end
    end

    // ========================================
    // FIRST-ORDER HIGH SHELF (~3 kHz)
    // ========================================
    logic signed [15:0] high_y [1:0];
    logic signed [15:0] high_x1 [1:0];
    logic signed [15:0] high_y1 [1:0];
    
    logic signed [15:0] high_gain_mult;
    assign high_gain_mult = $signed({1'b0, fx_high_gain}) - 16'sd32;
    
    
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            for (int ch = 0; ch < 2; ch++) begin
                high_y[ch] <= '0;
                high_x1[ch] <= '0;
                high_y1[ch] <= '0;
            end
        end else if (sample_en) begin
            for (int ch = 0; ch < 2; ch++) begin
                logic signed [31:0] acc;
                
                acc = (HIGH_B0 * audio_in[ch]) + 
                      (HIGH_B1 * high_x1[ch]) - 
                      (HIGH_A1 * high_y1[ch]);
                
                high_y[ch] <= sat16(acc >>> 15);
                high_x1[ch] <= audio_in[ch];
                high_y1[ch] <= high_y[ch];
            end
        end
    end

    // ========================================
    // MID BAND (Simple gain on original signal)
    // ========================================
    logic signed [15:0] mid_y [1:0];
    logic signed [15:0] mid_gain_mult;
    assign mid_gain_mult = $signed({1'b0, fx_mid_gain}) - 16'sd32;
    
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            mid_y <= '{default: '0};
        end else if (sample_en) begin
            for (int ch = 0; ch < 2; ch++) begin
                // Simple gain on input (represents midrange)
                logic signed [31:0] prod;
                prod = audio_in[ch] * mid_gain_mult;
                mid_y[ch] <= sat16(prod >>> 6);  // Scale appropriately
            end
        end
    end

    // ========================================
    // PRESENCE BOOST (~4-5 kHz peaking)
    // ========================================
    logic signed [15:0] presence_y [1:0];
    logic signed [15:0] presence_x1 [1:0];
    logic signed [15:0] presence_x2 [1:0];
    logic signed [15:0] presence_y1 [1:0];
    logic signed [15:0] presence_y2 [1:0];
    
    // Simple peaking filter coefficients (second-order)

    
    logic signed [15:0] presence_gain;
    assign presence_gain = {8'd0, fx_presence};
    
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            for (int ch = 0; ch < 2; ch++) begin
                presence_y[ch] <= '0;
                presence_x1[ch] <= '0;
                presence_x2[ch] <= '0;
                presence_y1[ch] <= '0;
                presence_y2[ch] <= '0;
            end
        end else if (sample_en) begin
            for (int ch = 0; ch < 2; ch++) begin
                logic signed [31:0] acc;
                
                // y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
                acc = (PRES_B0 * audio_in[ch]) + 
                      (PRES_B1 * presence_x1[ch]) +
                      (PRES_B2 * presence_x2[ch]) -
                      (PRES_A1 * presence_y1[ch]) -
                      (PRES_A2 * presence_y2[ch]);
                
                presence_y[ch] <= sat16(acc >>> 15);
                
                presence_x2[ch] <= presence_x1[ch];
                presence_x1[ch] <= audio_in[ch];
                presence_y2[ch] <= presence_y1[ch];
                presence_y1[ch] <= presence_y[ch];
            end
        end
    end

    // ========================================
    // MIX ALL BANDS
    // ========================================
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            // for (int ch = 0; ch < 2; ch++) begin
            //     logic signed [31:0] sum;
            //     logic signed [31:0] low_contrib, high_contrib, mid_contrib, pres_contrib;
                
            //     // Scale each band by its gain
            //     low_contrib = (low_y[ch] * low_gain_mult) >>> 5;
            //     high_contrib = (high_y[ch] * high_gain_mult) >>> 5;
            //     mid_contrib = mid_y[ch];
            //     pres_contrib = (presence_y[ch] * presence_gain) >>> 8;
                
            //     // Sum: original + band contributions
            //     sum = audio_in[ch] + low_contrib + high_contrib + mid_contrib + pres_contrib;
                
            //     // Saturate and output
            //     audio_out[ch] <= sat16(sum);
            // end

            audio_out = audio_in;
        end
    end

    // always_ff @(posedge clk) begin
    //     if (!reset_n) begin
    //         audio_out <= '0;
    //     end else if (sample_en) begin
    //         audio_out = audio_in;
    //     end
    // end


endmodule