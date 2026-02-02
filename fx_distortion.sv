/*

    Distortion of a signal using a non-linear 3rd-order-polynomial approxiation
    of the tanh(x) function that is described below:

        *NOTE: input x is scaled to fit values accordingly

               { 2/3       , x => 1 }
        f(x) = { x - x^3/3 , -1 < x < 1}
               { 2/3       , x <= -1 }

    Parameters:
        fx_drive       - Gain multiplier controlling input into non-linearity where
                         (fx_drive == 0) => UNITY and (fx_drive == 255) => 32.875x
        fx_mix         - Mix control determining how much of the wet signal is in
                         the output of this FX. (fx_mix == 0) => all dry, 
                         (fx_mix == 255) => all wet
        fx_makeup_gain - Gain multiplier controlling output gain where 
                         (fx_makeup_gain == 128) => UNITY

    Latency = 5 Samples

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
    input  logic [PARAM_W-1:0]        fx_makeup_gain,        
    input  logic [PARAM_W-1:0]        fx_mix,         // Dry/wet mix
    input  logic                      sample_en
);

    // ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;

    // ---------------- CONSTANTS ----------------
    localparam signed [31:0] ONE      = 32'sd32768;
    localparam signed [31:0] NEG_ONE  = -32'sd32768;
    localparam signed [31:0] TWO_THRD = 32'sd21845;
    localparam signed [31:0] ONE_THRD = 32'sd10923;

    // ---------------- INTERNAL SIGNALS ----------------

    // Drive gain
    logic [15:0] drive_gain;

    // Mix Signals
    logic signed [31:0] distorted_signal[1:0];
    logic signed [63:0] mixed_signal[1:0];   
    logic signed [31:0] mix_res[1:0];        
    logic signed [31:0] makeup_scaled[1:0];  
    logic signed [31:0] product_shifted[1:0];
    logic signed [31:0] dry_signal_32[1:0];

    // x^3 calculation
    logic signed [63:0] x_squared[1:0];
    logic signed [63:0] x_cubed[1:0];
    logic signed [31:0] x_raw[1:0];
    logic signed [31:0] x[1:0];
    logic signed [63:0] x_sq[1:0];      
    logic signed [96:0] x_cb_tmp[1:0];  
    logic signed [63:0] x_cb[1:0];      
    logic signed [63:0] cubic_term[1:0];

    // Pipeline
    logic signed [63:0] x_sq_reg[1:0]; 
    logic signed [96:0] x_cb_tmp_reg[1:0];
    logic signed [31:0] product_shifted_reg[1:0];
    logic signed [31:0] distorted_signal_reg[1:0];
    logic signed [31:0] mix_res_reg[1:0];  

    // ---------------- DISTORTION LOGIC ----------------

    // Map 0-255 to 1x-32.875x gain
    assign drive_gain = 16'h0100 + ({8'h00, fx_drive} << 5); 

    // Drive Calculation
    always_comb begin
        for (int i = 0; i < 2; i++) begin

            // Use explicit signed casting and let synthesis infer width            
            product_shifted[i] = ($signed(audio_in[i]) * $signed({1'b0, drive_gain}));
            x_raw[i] = product_shifted_reg[i] >>> 8;
            
            if (x_raw[i] > ONE)
                x[i] = ONE;
            else if (x_raw[i] < NEG_ONE)
                x[i] = NEG_ONE;
            else
                x[i] = x_raw[i];
        end
    end

    // Calculate Cubic term for non-linearity
    always_comb begin
        for (int i = 0; i < 2; i++) begin  
            x_sq[i] = $signed(x[i]) * $signed(x[i]);
            x_cb_tmp[i] = $signed(x_sq_reg[i]) * $signed(x[i]);
            cubic_term[i] = $signed(x_cb_tmp_reg[i] >>> 30);  // Q15
        end
    end


    // Apply nonlinearity and final mix
    always_comb begin
        for (int i = 0; i < 2; i++) begin
            
            // Clip at threshold, else use (x - x^3/3)
            if (x[i] >= ONE) begin
                distorted_signal[i] = TWO_THRD; 
            end else if (x[i] <= NEG_ONE) begin
                distorted_signal[i] = -TWO_THRD;
            end else begin
                distorted_signal[i] = x[i] - (($signed(cubic_term[i]) * $signed(ONE_THRD)) >>> 15);
            end

            // 3. Mixing
            dry_signal_32[i] = $signed(audio_in[i]);
            
            // Mix: dry + (wet - dry) * mix
            mix_res[i] = (dry_signal_32[i]) + 
                        (((distorted_signal_reg[i] - (dry_signal_32[i])) * 
                        $signed({1'b0, fx_mix})) >>> 8);
            
            // Apply makeup gain
            // - Note that it scales the mixed signal, for pipelining, so it applies
            //   even if fx_mix == 0
            makeup_scaled[i] = (mix_res_reg[i] * $signed({1'b0, fx_makeup_gain})) >>> 7;
            mixed_signal[i] = $signed(makeup_scaled[i]);

        end
    end

    // Pipeline
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            for (int i = 0; i < 2; i++) begin
                product_shifted_reg[i] <= '0;
                x_sq_reg[i] <= '0;
                x_cb_tmp_reg[i] <= '0;
                distorted_signal_reg[i] <= '0;
                mix_res_reg[i] <= '0;
            end
        end else if (sample_en) begin
            for (int i = 0; i < 2; i++) begin
                product_shifted_reg[i] <= product_shifted[i];
                x_cb_tmp_reg[i] <= x_cb_tmp[i];
                x_sq_reg[i] <= x_sq[i];
                distorted_signal_reg[i] <= distorted_signal[i];
                mix_res_reg[i] <= mix_res[i];
            end
        end
    end

    // -------------------- OUTPUT -------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            for (int i = 0; i < 2; i++) begin
                audio_out[i] <= sat16(mixed_signal[i]);
            end
        end
    end

endmodule