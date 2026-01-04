
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
    input  logic                      sample_en
);

    import lab_pkg::*;

    // ------------------------------------------------------------
    // Local Signals
    // ------------------------------------------------------------

    // Map 0-255 to 1x-4x gain
    logic [15:0] drive_gain;
    assign drive_gain = 16'h0100 + ({8'h00, fx_drive} << 2); // shift by 2 instead of 5

    logic signed [31:0] scaled_signal[1:0];
    logic signed [31:0] distorted_signal[1:0];
    logic signed [31:0] mixed_signal[1:0];

    // ------------------------------------------------------------
    // Distortion Function
    // ------------------------------------------------------------
    function automatic logic signed [31:0] tanh_distortion(logic signed [31:0] x);
        logic signed [63:0] x_sq;
        logic signed [63:0] x_cubed;
        logic signed [31:0] soft_clip;
        
        // Fixed-point constants (Q15: 1.0 = 32768)
        localparam signed [31:0] ONE      = 32'sd32768;
        localparam signed [31:0] NEG_ONE  = -32'sd32768;
        localparam signed [31:0] TWO_THRD = 32'sd21845; // ~0.66
        localparam signed [31:0] ONE_THRD = 32'sd10923; // ~0.33

        if (x > ONE) begin
            soft_clip = TWO_THRD;
        end 
        else if (x < NEG_ONE) begin
            soft_clip = -TWO_THRD;
        end 
        else begin
            // Polynomial: x - (x^3 / 3)
            // Use 64-bit intermediates to prevent overflow before the shift
            x_sq = (64'(x) * x) >>> 15;
            x_cubed = (x_sq[31:0] * x) >>> 15;
            
            soft_clip = x - ((x_cubed[31:0] * ONE_THRD) >>> 15);
        end

        // trivial to isolate issue
        soft_clip = x;

        return soft_clip;
    endfunction

    // ------------------------------------------------------------
    // Per Sample Distortion Calculation
    // ------------------------------------------------------------
    // always_comb begin
    //     for (int i = 0; i < 2; i++) begin
    //         // 1. Apply Gain: (Audio * Gain) >>> 8 
    //         // We shift right by 8 because drive_gain uses 8 bits for fraction (256 = 1.0)
    //         scaled_signal[i] = (64'(audio_in[i]) * drive_gain) >>> 8;
            
    //         // 2. Distort
    //         distorted_signal[i] = tanh_distortion(scaled_signal[i]);
            
    //         // 3. Mix: Dry + ((Wet - Dry) * Mix) >>> 8
    //         // We treat fx_mix as a Q8 fraction (0 to 255/256)
    //         mixed_signal[i] = $signed(audio_in[i]) + 
    //                          ((($signed(distorted_signal[i]) - $signed(audio_in[i])) * $signed({1'b0, fx_mix})) >>> 8);
    //     end
    // end

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            logic signed [31:0] audio_in_32;
            
            audio_in_32 = 32'($signed(audio_in[i]));
            
            scaled_signal[i] = (64'(audio_in_32) * drive_gain) >>> 8;
            distorted_signal[i] = tanh_distortion(scaled_signal[i]);
            
            mixed_signal[i] = audio_in_32 + 
                            (((distorted_signal[i] - audio_in_32) * $signed({1'b0, fx_mix})) >>> 8);
        end
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            for (int i = 0; i < 2; i++) begin
                // audio_out[i] <= sat16(distorted_signal[i]);
                audio_out[i] <= sat16(mixed_signal[i]);
            end
            // audio_out = audio_in;
        end
    end

endmodule