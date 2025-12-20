
// TODO: learn math to implement this\


/*

    Structure
    
    // 1. Split bands
    low  = lowpass(x);
    high = highpass(x);
    mid  = x - low - high;

    // 2. Apply gains
    low_g  = low  * low_gain;
    mid_g  = mid  * mid_gain;
    high_g = high * high_gain;

    // 3. Recombine
    y = low_g + mid_g + high_g;





*/

module fx_eq #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                          clk,
    input  logic                          reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,
    output logic signed [1:0][DATA_W-1:0] audio_out,

    input  logic [PARAM_W-1:0] fx_low_gain,
    input  logic [PARAM_W-1:0] fx_mid_gain,
    input  logic [PARAM_W-1:0] fx_high_gain,

    input  logic                          sample_en
);

    // ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;

    // ------------------------------------------------------------
    // Q15 FILTER COEFFICIENTS (EXAMPLE VALUES)
    // Replace with Python-generated coefficients
    // ------------------------------------------------------------

    // Low shelf (~200 Hz)
    localparam signed [15:0] LOW_A1 = -16'sd64122;
    localparam signed [15:0] LOW_A2 = 16'sd31384;
    localparam signed [15:0] LOW_B0 = 16'sd32810;
    localparam signed [15:0] LOW_B1 = -16'sd64120;
    localparam signed [15:0] LOW_B2 = 16'sd31343;

    // High shelf (~2000 Hz)
    localparam signed [15:0] HIGH_A1 = -16'sd50747;
    localparam signed [15:0] HIGH_A2 = 16'sd20750;
    localparam signed [15:0] HIGH_B0 = 16'sd36305;
    localparam signed [15:0] HIGH_B1 = -16'sd57108;
    localparam signed [15:0] HIGH_B2 = 16'sd23574;

    // ------------------------------------------------------------
    // FILTER STATE (UNCLIPPED)
    // ------------------------------------------------------------
    logic signed [15:0] low_x0  [1:0];
    logic signed [15:0] low_x1  [1:0];
    logic signed [15:0] low_x2  [1:0];
    logic signed [15:0] low_y0  [1:0];
    logic signed [31:0] low_y0_tmp [1:0];
    logic signed [15:0] low_y1  [1:0];
    logic signed [15:0] low_y2  [1:0];

    logic signed [15:0] high_x0  [1:0];
    logic signed [15:0] high_x1  [1:0];
    logic signed [15:0] high_x2  [1:0];
    logic signed [15:0] high_y0  [1:0];
    logic signed [31:0] high_y0_tmp [1:0];
    logic signed [15:0] high_y1  [1:0];
    logic signed [15:0] high_y2  [1:0];

    logic signed [15:0] mid_y0  [1:0];

    // ------------------------------------------------------------
    // Gain mapping: 0–255 → -1.0 to +1.0 (Q15)
    // ------------------------------------------------------------
    function automatic signed [15:0] gain_q15(input logic [7:0] g);
        gain_q15 = ($signed({1'b0, g}) - 16'sd128) <<< 8;
    endfunction

    // ------------------------------------------------------------
    // Processing
    // ------------------------------------------------------------
    integer ch;

    logic signed [31:0] low_scaled  [1:0];
    logic signed [31:0] high_scaled [1:0];
    logic signed [31:0] mid_scaled  [1:0];
    logic signed [31:0] mix         [1:0];

    // ------------------------------------------------------------
    // Sample Register 
    // ------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            for (ch = 0; ch < 2; ch++) begin
                low_x1[ch]  <= 'd0;
                low_x2[ch]  <= 'd0;
                low_y1[ch]  <= 'd0;
                low_y2[ch]  <= 'd0;

                high_x1[ch] <= 'd0;
                high_x2[ch] <= 'd0;
                high_y1[ch] <= 'd0;
                high_y2[ch] <= 'd0;

            end
        end
        else if (sample_en) begin
            for (ch = 0; ch < 2; ch++) begin

                // ================= LOW SHELF =================

                low_x1[ch] <= low_x0[ch];
                low_x2[ch] <= low_x1[ch];                
                low_y1[ch] <= low_y0[ch];
                low_y2[ch] <= low_y1[ch];

                // ================= HIGH SHELF =================

                high_x1[ch] <= high_x0[ch];
                high_x2[ch] <= high_x1[ch];                
                high_y1[ch] <= high_y0[ch];
                high_y2[ch] <= high_y1[ch];

            end
        end
    end

    // ------------------------------------------------------------
    // Output Stream Processing
    // ------------------------------------------------------------

    integer ch2;

    always_comb begin
        for (ch2 = 0; ch2 < 2; ch2++) begin

            // ================= LOW SHELF =================
            
            low_x0[ch2]     = audio_in[ch2];
            low_y0_tmp[ch2] = LOW_B0*low_x0[ch2] + LOW_B1*low_x1[ch2] + LOW_B2*low_x2[ch2] - LOW_A1*low_y1[ch2] - LOW_A2*low_y2[ch2];
            low_y0[ch2]     = low_y0_tmp[ch2] >>> 15;

            // ================= HIGH SHELF =================

            high_x0[ch2]     = audio_in[ch2];
            high_y0_tmp[ch2] = HIGH_B0*high_x0[ch2] + HIGH_B1*high_x1[ch2] + HIGH_B2*high_x2[ch2] - HIGH_A1*high_y1[ch2] - HIGH_A2*high_y2[ch2];
            high_y0[ch2]     = high_y0_tmp[ch2] >>> 15;

            // ================= Other (MID) =================

            mid_y0[ch2] = audio_in[ch2] - low_y0[ch2] - high_y0[ch2];

            // ================= Full Mix =================

            low_scaled[ch2]  = $signed(low_y0[ch2])*$signed(gain_q15(fx_low_gain));
            high_scaled[ch2] = $signed(high_y0[ch2])*$signed(gain_q15(fx_high_gain));
            mid_scaled[ch2]  = $signed(mid_y0[ch2])*$signed(gain_q15(fx_mid_gain));
            mix[ch2]         = low_scaled[ch2] + high_scaled[ch2] + mid_scaled[ch2];

            audio_out[ch2] = sat16(mix[ch2] >>> 15);

        end
    end



endmodule
