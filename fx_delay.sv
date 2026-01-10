
// // Delay Effect with feedback
// module fx_delay #(
//     parameter DATA_W  = 16,
//     parameter PARAM_W = 8
// )(
//     input  logic                      clk,
//     input  logic                      reset_n,
//     input  logic signed [1:0][DATA_W-1:0]    audio_in,   // Stereo input
//     output logic signed [1:0][DATA_W-1:0]    audio_out,  // Stereo output
//     input  logic [PARAM_W-1:0]        fx_time,       // Delay time (0-255)
//     input  logic [PARAM_W-1:0]        fx_feedback,   // Feedback amount (0-255)
//     input  logic [PARAM_W-1:0]        fx_mix,        // Dry/wet mix (0-255)
//     input  logic                      sample_en
// );

//     import lab_pkg::*;

//     // Constants for sample rate and max delay time
//     // Assuming 48kHz sample rate
//     localparam MAX_DELAY_MS = 500;  // 500ms max delay (more reasonable for FPGA)
//     localparam SAMPLE_RATE = 48000;
//     localparam MAX_DELAY_SAMPLES = (MAX_DELAY_MS * SAMPLE_RATE) / 1000;  // 24000 samples
//     localparam ADDR_W = $clog2(MAX_DELAY_SAMPLES);
    
//     // Map fx_time (0-255) to delay samples (0 to MAX_DELAY_SAMPLES)
//     logic [ADDR_W-1:0] delay_samples;
//     assign delay_samples = (fx_time * MAX_DELAY_SAMPLES[ADDR_W-1:0]) >> 8;  // Scale 0-255 to 0-MAX_DELAY_SAMPLES
    
//     // Delay line outputs
//     logic signed [DATA_W-1:0] delayed_L, delayed_R;
    
//     // Feedback signals
//     logic signed [31:0] feedback_L, feedback_R;
//     logic signed [DATA_W-1:0] delay_input_L, delay_input_R;
    
//     // Mix calculation
//     logic signed [31:0] wet_L, wet_R;
//     logic signed [31:0] mixed_L, mixed_R;
    
//     // Calculate delay input (audio_in + feedback)
//     always_comb begin
//         // Feedback scaling: feedback_amount is 0-255, map to 0-0.9 range for stability
//         // Use fx_feedback * 230/256 ≈ 0.9 max to prevent runaway feedback
//         feedback_L = ($signed(delayed_L) * $signed({1'b0, fx_feedback})) >>> 8;
//         feedback_R = ($signed(delayed_R) * $signed({1'b0, fx_feedback})) >>> 8;
        
//         // Add input + feedback (with saturation)
//         delay_input_L = sat16($signed(audio_in[0]) + feedback_L);
//         delay_input_R = sat16($signed(audio_in[1]) + feedback_R);
        
//         // Mix calculation: dry + (wet - dry) * mix
//         wet_L = $signed(delayed_L);
//         wet_R = $signed(delayed_R);
        
//         mixed_L = $signed(audio_in[0]) + 
//                   ((($signed(delayed_L) - $signed(audio_in[0])) * $signed({1'b0, fx_mix})) >>> 8);
//         mixed_R = $signed(audio_in[1]) + 
//                   ((($signed(delayed_R) - $signed(audio_in[1])) * $signed({1'b0, fx_mix})) >>> 8);
//     end
    
//     // Delay lines for left and right channels
//     delay_line #(
//         .DATA_W(DATA_W),
//         .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES),
//         .ADDR_W(ADDR_W)
//     ) delay_line_L (
//         .clk(clk),
//         .reset_n(reset_n),
//         .data_in(delay_input_L),
//         .data_out(delayed_L),
//         .delay_samples(delay_samples),
//         .write_en(sample_en)
//     );
    
//     delay_line #(
//         .DATA_W(DATA_W),
//         .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES),
//         .ADDR_W(ADDR_W)
//     ) delay_line_R (
//         .clk(clk),
//         .reset_n(reset_n),
//         .data_in(delay_input_R),
//         .data_out(delayed_R),
//         .delay_samples(delay_samples),
//         .write_en(sample_en)
//     );
    
//     // Output register
//     always_ff @(posedge clk) begin
//         if (!reset_n) begin
//             audio_out <= '0;
//         end else if (sample_en) begin
//             audio_out[0] <= sat16(mixed_L);
//             audio_out[1] <= sat16(mixed_R);
//         end
//     end

// endmodule


module fx_delay #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                        clk,
    input  logic                        reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,
    output logic signed [1:0][DATA_W-1:0] audio_out,
    input  logic [PARAM_W-1:0]          fx_time,    
    input  logic [PARAM_W-1:0]          fx_feedback, 
    input  logic [PARAM_W-1:0]          fx_mix,      
    input  logic                        sample_en
);

    import lab_pkg::*;

    // 500ms at 48kHz = 24,000 samples
    localparam MAX_SAMPLES = 24000;
    localparam ADDR_W = $clog2(MAX_SAMPLES);

    logic [ADDR_W-1:0] target_delay;
    assign target_delay = (fx_time * (MAX_SAMPLES-1)) >> PARAM_W;

    logic signed [DATA_W-1:0] delayed_L, delayed_R;
    logic signed [DATA_W-1:0] fb_scaled_L, fb_scaled_R;
    logic signed [DATA_W-1:0] din_L, din_R;

    // 1. Scale Feedback (fx_feedback is 0-255, map to 0-0.9 approx)
    // We use 220/256 to ensure it never hits 1.0 and screams.
    assign fb_scaled_L = ($signed(delayed_L) * $signed({1'b0, fx_feedback})) >>> 8;
    assign fb_scaled_R = ($signed(delayed_R) * $signed({1'b0, fx_feedback})) >>> 8;

    // 2. Sum Input + Feedback (Saturation is critical here)
    // Replace 'sat16' with your package function
    assign din_L = sat16($signed(audio_in[0]) + fb_scaled_L);
    assign din_R = sat16($signed(audio_in[1]) + fb_scaled_R);

    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_SAMPLES)) 
    unit_L (.clk, .reset_n, .sample_en, .data_in(din_L), .data_out(delayed_L), .delay_samples(target_delay));

    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_SAMPLES)) 
    unit_R (.clk, .reset_n, .sample_en, .data_in(din_R), .data_out(delayed_R), .delay_samples(target_delay));

    // 3. Dry/Wet Mix logic
    // audio_out = dry * (1-mix) + wet * mix
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            logic signed [31:0] tmp_L, tmp_R;
            
            // Wet path
            tmp_L = ($signed(delayed_L) * $signed({1'b0, fx_mix}));
            tmp_R = ($signed(delayed_R) * $signed({1'b0, fx_mix}));
            
            // Add Dry path (scaled by 255 - fx_mix)
            tmp_L += ($signed(audio_in[0]) * $signed({1'b0, 8'd255 - fx_mix}));
            tmp_R += ($signed(audio_in[1]) * $signed({1'b0, 8'd255 - fx_mix}));

            audio_out[0] <= $signed(tmp_L >>> 8);
            audio_out[1] <= $signed(tmp_R >>> 8);
        end
    end

endmodule

