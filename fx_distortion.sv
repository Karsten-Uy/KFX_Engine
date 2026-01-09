
/*

    Algorithm from:
        https://dsp.stackexchange.com/questions/13142/digital-distortion-effect-algorithm

*/

// Distortion (FX 4)
module fx_distortion #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                      clk,
    input  logic                      reset_n,
    input  logic signed [1:0][DATA_W-1:0]    audio_in,   // Stereo input
    output logic signed [1:0][DATA_W-1:0]    audio_out,  // Stereo output
    input  logic [PARAM_W-1:0]        fx_drive,       // Distortion amount
    input  logic [PARAM_W-1:0]        fx_mix,         // Dry/wet mix
    input  logic [PARAM_W-1:0]        fx_makeup_gain,       
    input  logic [PARAM_W-1:0]        fx_threshold,         
    input  logic                      sample_en
);

    import lab_pkg::*;

    // ------------------------------------------------------------
    // Local Signals
    // ------------------------------------------------------------

    // Map 0-255 to 1x-4x gain
    logic [15:0] drive_gain;
    assign drive_gain = 16'h0100 + ({8'h00, fx_drive} << 2); 

    logic signed [31:0] distorted_signal[1:0];
    logic signed [63:0] mixed_signal[1:0];
    
    localparam signed [31:0] ONE      = 32'sd32768;
    localparam signed [31:0] NEG_ONE  = -32'sd32768;
    localparam signed [31:0] TWO_THRD = 32'sd21845;
    localparam signed [31:0] ONE_THRD = 32'sd10923;

    // logic signed [31:0] x[1:0];
    logic signed [63:0] mix_res[1:0];
    logic signed [63:0] makeup_scaled[1:0];

    logic signed [63:0] x_squared[1:0];
    logic signed [63:0] x_cubed[1:0];
    // logic signed [63:0] cubic_term[1:0];
    

    // ------------------------------------------------------------
    // Per Sample Distortion Calculation
    // ------------------------------------------------------------

    logic signed [31:0] threshold_pos;
    logic signed [31:0] threshold_neg;
    logic signed [31:0] clip_output_pos;
    logic signed [31:0] clip_output_neg;

    always_comb begin

        // // Map fx_threshold (0-255) to a threshold range
        threshold_pos = 32'sd8192 + (({24'd0, fx_threshold} * 32'd96) >>> 0);
        threshold_neg = -threshold_pos;

        // Map fx_threshold (0-255) to threshold range with lower floor
        // Range: 2048 (0.0625) to 32768 (1.0)
        // Formula: floor + (range * fx_threshold / 256)
        // threshold_pos = 32'sd2048 + (({24'd0, fx_threshold} * 32'd120) >>> 0);
        // threshold_neg = -threshold_pos;
        
        // Clip output should be proportional to threshold (traditional ~2/3 of threshold)
        clip_output_pos = (threshold_pos * 32'sd21845) >>> 15; // ~0.66 of threshold
        clip_output_neg = -clip_output_pos;

    end

    // always_comb begin
    //     for (int i = 0; i < 2; i++) begin            
    //         // 1. Gain Stage (Q8 drive_gain)
    //         x[i] = (64'($signed(audio_in[i])) * drive_gain) >>> 8;

    //         x_squared[i]  = (x[i] * x[i]) >>> 15;
    //         x_cubed[i]    = (x_squared[i] * x[i]) >>> 15;
    //         cubic_term[i] = (x_cubed[i] * ONE_THRD) >>> 15;
    //     end
    // end

    logic signed [31:0] x_raw[1:0];
    logic signed [31:0] x[1:0];
    logic signed [63:0] x_sq[1:0];      // 32×32 = 64 bits needed
    logic signed [96:0] x_cb_tmp[1:0];      // 64×32 = up to 96, but we shift
    logic signed [96:0] x_cb_tmp_reg[1:0];      // 64×32 = up to 96, but we shift
    logic signed [63:0] x_cb[1:0];      // 64×32 = up to 96, but we shift
    logic signed [63:0] cubic_term[1:0];

    logic signed [31:0] product_shifted[1:0];
    logic signed [31:0] product_shifted_reg[1:0];


    always_comb begin
        for (int i = 0; i < 2; i++) begin
            // Use explicit signed casting and let synthesis infer width
            
            product_shifted[i] = ($signed(audio_in[i]) * $signed({1'b0, drive_gain}));


            
            // x_raw[i] = product_shifted[i] >>> 8;
            x_raw[i] = product_shifted_reg[i] >>> 8;
            
            if (x_raw[i] > ONE)
                x[i] = ONE;
            else if (x_raw[i] < NEG_ONE)
                x[i] = NEG_ONE;
            else
                x[i] = x_raw[i];
        end
    end

    always_comb begin
        for (int i = 0; i < 2; i++) begin  
            // 3. Cubic (all 32-bit inputs, 64-bit intermediates)
            // x_sq[i] = signed'(x[i]) * signed'(x[i]);           // Q30 format
            // x_sq[i] = ($signed(x[i]) * $signed(x[i])) >>> 15;           // Q30 format
            // x_cb_tmp[i] = $signed(x_sq[i]) * $signed(x[i]);        
            // x_cb[i] = x_cb_tmp[i] >>> 15; // Back to Q15
            x_cb_tmp[i] = $signed(x[i]) * $signed(x[i]) * $signed(x[i]); // Back to Q15
            // cubic_term[i] = (x_cb[i] * signed'(ONE_THRD)) >>> 15;  // Q15
            // cubic_term[i] = ($signed(x_cb_tmp[i] >>> 30) * $signed(ONE_THRD)) >>> 15;  // Q15
            cubic_term[i] = $signed(x_cb_tmp_reg[i] >>> 30);  // Q15
        end
    end

    // always_comb begin
    //     for (int i = 0; i < 2; i++) begin
            
    //         // 1. Gain Stage (Q8 drive_gain)
    //         x[i] = (64'($signed(audio_in[i])) * drive_gain) >>> 8;
            
    //         // 2. Distortion with adjustable threshold
    //         if (x[i] > threshold_pos) begin
    //             distorted_signal[i] = clip_output_pos;
    //         end else if (x[i] < threshold_neg) begin
    //             distorted_signal[i] = clip_output_neg;
    //         end else begin
    //             distorted_signal[i] = x[i];
    //         end

    //         // 3. Mixing and Makeup
    //         // Use 64-bit for the makeup gain to prevent wrap-around noise
    //         mix_res[i] = $signed(audio_in[i]) + $signed(((distorted_signal[i] - $signed(audio_in[i])) * $signed({1'b0, fx_mix})) >>> 8);
            
    //         // mixed_signal[i] = (mix_res[i] * $signed({1'd0, fx_makeup_gain})) >>> 7;
    //         mixed_signal[i] = (mix_res[i]);
    //     end
    // end

    logic signed [31:0] dry_signal_32[1:0];


    always_comb begin
        for (int i = 0; i < 2; i++) begin
            
            // 2. Distortion with adjustable threshold, for now hard code
            if (x[i] > TWO_THRD) begin
                distorted_signal[i] = ONE;
            end else if (x[i] < -TWO_THRD) begin
                distorted_signal[i] = -ONE;
            end else begin
                // distorted_signal[i] = x[i]; // FMAX is ~30MHz
                distorted_signal[i] = x[i] - (($signed(cubic_term[i]) * $signed(ONE_THRD)) >>> 15);
            end

            // // 3. Mixing and Makeup
            // // Use 64-bit for the makeup gain to prevent wrap-around noise
            // mix_res[i] = $signed(audio_in[i]) + $signed(((distorted_signal[i] - $signed(audio_in[i])) * $signed({1'b0, fx_mix})) >>> 8);
            // mixed_signal[i] = (mix_res[i]);


            // Work in 32-bit space, normalize at the end
            dry_signal_32[i] = $signed(audio_in[i]); // stays as 16-bit value in 32-bit container
            
            // Mix: dry + (wet - dry) * mix
            mix_res[i] = (dry_signal_32[i]) + 
                        (((distorted_signal[i] - (dry_signal_32[i])) * 
                        $signed({1'b0, fx_mix})) >>> 8);
            
            mixed_signal[i] = mix_res[i]; // scale back down

        end
    end


    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
            product_shifted_reg[0] <= '0;
            product_shifted_reg[1] <= '0;
            x_cb_tmp_reg[0] <= '0;
            x_cb_tmp_reg[1] <= '0;
        end else if (sample_en) begin
            for (int i = 0; i < 2; i++) begin
                audio_out[i] <= sat16(distorted_signal[i]);
                // audio_out[i] <= sat16(mixed_signal[i] >>> 7); // L side buzz is coming from here
                // audio_out[i] <= sat16(mixed_signal[i]);

                product_shifted_reg[i] <= product_shifted[i];
                x_cb_tmp_reg[i] <= x_cb_tmp[i];

            end
            // audio_out = audio_in;

        end
    end

endmodule