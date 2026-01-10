// Working ish

// // Chorus Effect - Modulated delay for thick, shimmering sound
// module fx_chorus #(
//     parameter DATA_W  = 16,
//     parameter PARAM_W = 8
// )(
//     input  logic                      clk,
//     input  logic                      reset_n,
//     input  logic signed [1:0][DATA_W-1:0]    audio_in,   // Stereo input
//     output logic signed [1:0][DATA_W-1:0]    audio_out,  // Stereo output
//     input  logic [PARAM_W-1:0]        fx_rate,       // LFO rate (0-255)
//     input  logic [PARAM_W-1:0]        fx_depth,      // Modulation depth (0-255)
//     input  logic [PARAM_W-1:0]        fx_mix,        // Dry/wet mix (0-255)
//     input  logic                      sample_en
// );

//     import lab_pkg::*;

//     // Chorus parameters
//     localparam SAMPLE_RATE = 48000;
//     localparam BASE_DELAY_MS = 15;      // 15ms base delay (typical for chorus)
//     localparam MAX_MOD_MS = 8;          // ±8ms modulation depth
//     localparam BASE_DELAY_SAMPLES = (BASE_DELAY_MS * SAMPLE_RATE) / 1000;  // 720 samples
//     localparam MAX_MOD_SAMPLES = (MAX_MOD_MS * SAMPLE_RATE) / 1000;        // 384 samples
//     localparam MAX_DELAY_SAMPLES = BASE_DELAY_SAMPLES + MAX_MOD_SAMPLES;   // 1104 samples
//     localparam ADDR_W = $clog2(MAX_DELAY_SAMPLES);

//     // ===================================================================
//     // LFO (Low Frequency Oscillator) - Creates the modulation
//     // ===================================================================
    
//     logic [23:0] lfo_phase;        // Phase accumulator
//     logic [23:0] lfo_increment;    // How fast the LFO moves
//     logic signed [15:0] lfo_sine;  // LFO output (-32768 to +32767)
    
//     // Map fx_rate (0-255) to LFO frequency
//     // Target range: 0.1 Hz to 5 Hz (typical chorus rates)
//     // LFO increment = (frequency * 2^24) / sample_rate
//     // For 5 Hz max: (5 * 16777216) / 48000 ≈ 1747
//     always_comb begin
//         // Scale rate to get reasonable LFO speeds
//         // Rate 0 = ~0.02 Hz, Rate 255 = ~5 Hz
//         lfo_increment = 7 + ((fx_rate * 24'd1740) >> 8);
//     end
    
//     // Phase accumulator - runs at sample rate
//     always_ff @(posedge clk) begin
//         if (!reset_n)
//             lfo_phase <= 0;
//         else if (sample_en)
//             lfo_phase <= lfo_phase + lfo_increment;
//     end
    
//     // Convert phase to sine-like wave (simple triangle for now)
//     // Top bit determines positive/negative half
//     always_comb begin
//         if (lfo_phase[23]) begin
//             // Negative half: create downward slope
//             lfo_sine = -$signed({1'b0, lfo_phase[22:8]});
//         end else begin
//             // Positive half: create upward slope
//             lfo_sine = $signed({1'b0, lfo_phase[22:8]});
//         end
//     end

//     // ===================================================================
//     // Modulated Delay Calculation
//     // ===================================================================
    
//     logic signed [31:0] modulation;
//     logic [ADDR_W-1:0] delay_L, delay_R;
    
//     always_comb begin
//         // Scale LFO by depth parameter
//         // modulation = (lfo_sine * fx_depth * MAX_MOD_SAMPLES) / 65536
//         modulation = ($signed(lfo_sine) * $signed({1'b0, fx_depth}) * MAX_MOD_SAMPLES) >>> 16;
        
//         // Left channel: base + modulation
//         if (BASE_DELAY_SAMPLES[ADDR_W-1:0] + modulation[ADDR_W-1:0] < MAX_DELAY_SAMPLES[ADDR_W-1:0])
//             delay_L = BASE_DELAY_SAMPLES[ADDR_W-1:0] + modulation[ADDR_W-1:0];
//         else
//             delay_L = MAX_DELAY_SAMPLES[ADDR_W-1:0] - 1;
        
//         // Right channel: base - modulation (inverted for stereo width)
//         if (BASE_DELAY_SAMPLES[ADDR_W-1:0] > modulation[ADDR_W-1:0])
//             delay_R = BASE_DELAY_SAMPLES[ADDR_W-1:0] - modulation[ADDR_W-1:0];
//         else
//             delay_R = 1;  // Minimum delay
//     end

//     // ===================================================================
//     // Delay Lines
//     // ===================================================================
    
//     logic signed [DATA_W-1:0] delayed_L, delayed_R;
    
//     delay_line #(
//         .DATA_W(DATA_W),
//         .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES),
//         .ADDR_W(ADDR_W)
//     ) chorus_delay_L (
//         .clk(clk),
//         .reset_n(reset_n),
//         .data_in(audio_in[0]),
//         .data_out(delayed_L),
//         .delay_samples(delay_L),
//         .sample_en(sample_en)
//     );
    
//     delay_line #(
//         .DATA_W(DATA_W),
//         .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES),
//         .ADDR_W(ADDR_W)
//     ) chorus_delay_R (
//         .clk(clk),
//         .reset_n(reset_n),
//         .data_in(audio_in[1]),
//         .data_out(delayed_R),
//         .delay_samples(delay_R),
//         .sample_en(sample_en)
//     );

//     // ===================================================================
//     // Mixing
//     // ===================================================================
    
//     logic signed [31:0] wet_L, dry_L, mixed_L;
//     logic signed [31:0] wet_R, dry_R, mixed_R;
//     logic signed [8:0] dry_gain;
    
//     always_ff @(posedge clk) begin
//         if (!reset_n) begin
//             audio_out <= '0;
//         end else if (sample_en) begin
//             // Calculate dry gain for unity gain mixing
//             dry_gain = 9'sd256 - $signed({1'b0, fx_mix});
            
//             // Mix wet (delayed) and dry signals
//             wet_L = ($signed(delayed_L) * $signed({1'b0, fx_mix}));
//             dry_L = ($signed(audio_in[0]) * dry_gain);
//             mixed_L = (wet_L + dry_L) >>> 8;
            
//             wet_R = ($signed(delayed_R) * $signed({1'b0, fx_mix}));
//             dry_R = ($signed(audio_in[1]) * dry_gain);
//             mixed_R = (wet_R + dry_R) >>> 8;
            
//             // Saturate and output
//             audio_out[0] <= sat16(mixed_L);
//             audio_out[1] <= sat16(mixed_R);
//         end
//     end

// endmodule



// mix working output distorted

// // Chorus Effect - Fixed version with proper mixing and smoother modulation
// module fx_chorus #(
//     parameter DATA_W  = 16,
//     parameter PARAM_W = 8
// )(
//     input  logic                      clk,
//     input  logic                      reset_n,
//     input  logic signed [1:0][DATA_W-1:0]    audio_in,   // Stereo input
//     output logic signed [1:0][DATA_W-1:0]    audio_out,  // Stereo output
//     input  logic [PARAM_W-1:0]        fx_rate,       // LFO rate (0-255)
//     input  logic [PARAM_W-1:0]        fx_depth,      // Modulation depth (0-255)
//     input  logic [PARAM_W-1:0]        fx_mix,        // Dry/wet mix (0-255)
//     input  logic                      sample_en
// );

//     import lab_pkg::*;

//     // Chorus parameters - adjusted for smoother sound
//     localparam SAMPLE_RATE = 48000;
//     localparam BASE_DELAY_MS = 20;      // 20ms base delay (slightly longer for smoother chorus)
//     localparam MAX_MOD_MS = 5;          // ±5ms modulation (reduced for less extreme pitch shift)
//     localparam BASE_DELAY_SAMPLES = (BASE_DELAY_MS * SAMPLE_RATE) / 1000;  // 960 samples
//     localparam MAX_MOD_SAMPLES = (MAX_MOD_MS * SAMPLE_RATE) / 1000;        // 240 samples
//     localparam MAX_DELAY_SAMPLES = BASE_DELAY_SAMPLES + MAX_MOD_SAMPLES;   // 1200 samples
//     localparam ADDR_W = $clog2(MAX_DELAY_SAMPLES);

//     // ===================================================================
//     // LFO (Low Frequency Oscillator) - Creates the modulation
//     // ===================================================================
    
//     logic [23:0] lfo_phase;        // Phase accumulator
//     logic [23:0] lfo_increment;    // How fast the LFO moves
//     logic signed [15:0] lfo_triangle;  // LFO output (-32768 to +32767)
    
//     // Map fx_rate (0-255) to LFO frequency
//     // Reduced range for smoother chorus: 0.2 Hz to 3 Hz
//     always_comb begin
//         // Minimum rate to avoid DC shift
//         lfo_increment = 35 + ((fx_rate * 24'd1050) >> 8);  // ~0.2 Hz to 3 Hz
//     end
    
//     // Phase accumulator
//     always_ff @(posedge clk) begin
//         if (!reset_n)
//             lfo_phase <= 0;
//         else if (sample_en)
//             lfo_phase <= lfo_phase + lfo_increment;
//     end
    
//     // Generate triangle wave (smoother than saw, less harsh than sine approximation)
//     always_comb begin
//         if (lfo_phase[23]) begin
//             // Negative half: inverted triangle
//             lfo_triangle = -$signed({1'b0, lfo_phase[22:8]});
//         end else begin
//             // Positive half: triangle
//             lfo_triangle = $signed({1'b0, lfo_phase[22:8]});
//         end
//     end

//     // ===================================================================
//     // Modulated Delay Calculation with bounds checking
//     // ===================================================================
    
//     logic signed [31:0] modulation_scaled;
//     logic signed [ADDR_W:0] delay_calc_L, delay_calc_R;  // Extra bit for overflow detection
//     logic [ADDR_W-1:0] delay_L, delay_R;
    
//     always_comb begin
//         // Scale LFO by depth parameter
//         // Use full 16-bit multiply then scale
//         modulation_scaled = ($signed(lfo_triangle) * $signed({1'b0, fx_depth}) * MAX_MOD_SAMPLES) >>> 16;
        
//         // Calculate delays with overflow protection
//         delay_calc_L = $signed({1'b0, BASE_DELAY_SAMPLES[ADDR_W-1:0]}) + modulation_scaled[ADDR_W:0];
//         delay_calc_R = $signed({1'b0, BASE_DELAY_SAMPLES[ADDR_W-1:0]}) - modulation_scaled[ADDR_W:0];
        
//         // Clamp to valid range
//         if (delay_calc_L < 1)
//             delay_L = 1;
//         else if (delay_calc_L >= MAX_DELAY_SAMPLES[ADDR_W-1:0])
//             delay_L = MAX_DELAY_SAMPLES[ADDR_W-1:0] - 1;
//         else
//             delay_L = delay_calc_L[ADDR_W-1:0];
            
//         if (delay_calc_R < 1)
//             delay_R = 1;
//         else if (delay_calc_R >= MAX_DELAY_SAMPLES[ADDR_W-1:0])
//             delay_R = MAX_DELAY_SAMPLES[ADDR_W-1:0] - 1;
//         else
//             delay_R = delay_calc_R[ADDR_W-1:0];
//     end

//     // ===================================================================
//     // Delay Lines
//     // ===================================================================
    
//     logic signed [DATA_W-1:0] delayed_L, delayed_R;
    
//     delay_line #(
//         .DATA_W(DATA_W),
//         .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES),
//         .ADDR_W(ADDR_W)
//     ) chorus_delay_L (
//         .clk(clk),
//         .reset_n(reset_n),
//         .data_in(audio_in[0]),
//         .data_out(delayed_L),
//         .delay_samples(delay_L),
//         .sample_en(sample_en)
//     );
    
//     delay_line #(
//         .DATA_W(DATA_W),
//         .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES),
//         .ADDR_W(ADDR_W)
//     ) chorus_delay_R (
//         .clk(clk),
//         .reset_n(reset_n),
//         .data_in(audio_in[1]),
//         .data_out(delayed_R),
//         .delay_samples(delay_R),
//         .sample_en(sample_en)
//     );

//     // ===================================================================
//     // Mixing - FIXED for proper dry/wet balance
//     // ===================================================================
    
//     always_ff @(posedge clk) begin
//         if (!reset_n) begin
//             audio_out <= '0;
//         end else if (sample_en) begin
//             // Use automatic variables for cleaner code
//             automatic logic signed [31:0] wet_L, dry_L, mixed_L;
//             automatic logic signed [31:0] wet_R, dry_R, mixed_R;
//             automatic logic signed [8:0] dry_gain;
            
//             // Calculate dry gain for unity gain mixing
//             dry_gain = 9'sd256 - $signed({1'b0, fx_mix});
            
//             // Mix calculation
//             // Wet path: delayed signal * fx_mix
//             wet_L = $signed(delayed_L) * $signed({1'b0, fx_mix});
//             wet_R = $signed(delayed_R) * $signed({1'b0, fx_mix});
            
//             // Dry path: input signal * (256 - fx_mix)
//             dry_L = $signed(audio_in[0]) * dry_gain;
//             dry_R = $signed(audio_in[1]) * dry_gain;
            
//             // Combine and scale
//             mixed_L = (wet_L + dry_L) >>> 8;
//             mixed_R = (wet_R + dry_R) >>> 8;
            
//             // Saturate and output
//             audio_out[0] <= sat16(mixed_L);
//             audio_out[1] <= sat16(mixed_R);
//         end
//     end

// endmodule



// Distorted Chorus
// // Chorus Effect - With linear interpolation for smooth modulation
// module fx_chorus #(
//     parameter DATA_W  = 16,
//     parameter PARAM_W = 8
// )(
//     input  logic                      clk,
//     input  logic                      reset_n,
//     input  logic signed [1:0][DATA_W-1:0]    audio_in,   // Stereo input
//     output logic signed [1:0][DATA_W-1:0]    audio_out,  // Stereo output
//     input  logic [PARAM_W-1:0]        fx_rate,       // LFO rate (0-255)
//     input  logic [PARAM_W-1:0]        fx_depth,      // Modulation depth (0-255)
//     input  logic [PARAM_W-1:0]        fx_mix,        // Dry/wet mix (0-255)
//     input  logic                      sample_en
// );

//     import lab_pkg::*;

//     // Chorus parameters - optimized for smooth, musical sound
//     localparam SAMPLE_RATE = 48000;
//     localparam BASE_DELAY_MS = 25;      // 25ms base (longer = smoother)
//     localparam MAX_MOD_MS = 3;          // ±3ms modulation (subtle)
//     localparam BASE_DELAY_SAMPLES = (BASE_DELAY_MS * SAMPLE_RATE) / 1000;
//     localparam MAX_MOD_SAMPLES = (MAX_MOD_MS * SAMPLE_RATE) / 1000;
//     localparam MAX_DELAY_SAMPLES = BASE_DELAY_SAMPLES + MAX_MOD_SAMPLES + 2;  // +2 for interpolation
//     localparam ADDR_W = $clog2(MAX_DELAY_SAMPLES);

//     // ===================================================================
//     // LFO with sine approximation for smoother modulation
//     // ===================================================================
    
//     logic [23:0] lfo_phase;
//     logic [23:0] lfo_increment;
//     logic signed [15:0] lfo_out;
    
//     // Slower LFO range: 0.1 Hz to 2 Hz
//     always_comb begin
//         lfo_increment = 17 + ((fx_rate * 24'd650) >> 8);  // 0.1 Hz to 2 Hz
//     end
    
//     always_ff @(posedge clk) begin
//         if (!reset_n)
//             lfo_phase <= 0;
//         else if (sample_en)
//             lfo_phase <= lfo_phase + lfo_increment;
//     end
    
//     // Parabolic approximation of sine (smoother than triangle)
//     logic signed [15:0] triangle;
//     logic signed [31:0] triangle_sq;
//     always_comb begin
//         // Generate triangle
//         if (lfo_phase[23])
//             triangle = -$signed({1'b0, lfo_phase[22:8]});
//         else
//             triangle = $signed({1'b0, lfo_phase[22:8]});
        
//         // Parabolic shaping: y = x - (x^3 / (3*32768^2))
//         // This approximates a sine wave
//         triangle_sq = triangle * triangle;
//         if (triangle >= 0)
//             lfo_out = triangle - (triangle_sq >>> 17);  // Simplified approximation
//         else
//             lfo_out = triangle + (triangle_sq >>> 17);
//     end

//     // ===================================================================
//     // Fractional delay with linear interpolation
//     // ===================================================================
    
//     logic signed [31:0] modulation_scaled;
//     logic signed [31:0] fractional_delay_L, fractional_delay_R;
//     logic [ADDR_W-1:0] delay_int_L, delay_int_R;        // Integer part
//     logic [ADDR_W-1:0] delay_int_plus1_L, delay_int_plus1_R;  // Integer + 1
//     logic [7:0] delay_frac_L, delay_frac_R;              // Fractional part (8-bit)
    
//     always_comb begin
//         // Scale modulation by depth (in 8.8 fixed point for fractional delay)
//         modulation_scaled = ($signed(lfo_out) * $signed({1'b0, fx_depth}) * MAX_MOD_SAMPLES) >>> 8;
        
//         // Calculate fractional delays (in 8.8 fixed point)
//         fractional_delay_L = (BASE_DELAY_SAMPLES << 8) + modulation_scaled;
//         fractional_delay_R = (BASE_DELAY_SAMPLES << 8) - modulation_scaled;
        
//         // Extract integer and fractional parts for left
//         if (fractional_delay_L < (1 << 8))
//             fractional_delay_L = (1 << 8);
//         if (fractional_delay_L >= ((MAX_DELAY_SAMPLES - 1) << 8))
//             fractional_delay_L = ((MAX_DELAY_SAMPLES - 1) << 8);
            
//         delay_int_L = fractional_delay_L[ADDR_W+7:8];
//         delay_frac_L = fractional_delay_L[7:0];
//         delay_int_plus1_L = delay_int_L + 1;
        
//         // Extract integer and fractional parts for right
//         if (fractional_delay_R < (1 << 8))
//             fractional_delay_R = (1 << 8);
//         if (fractional_delay_R >= ((MAX_DELAY_SAMPLES - 1) << 8))
//             fractional_delay_R = ((MAX_DELAY_SAMPLES - 1) << 8);
            
//         delay_int_R = fractional_delay_R[ADDR_W+7:8];
//         delay_frac_R = fractional_delay_R[7:0];
//         delay_int_plus1_R = delay_int_R + 1;
//     end

//     // ===================================================================
//     // Dual-tap delay lines for interpolation
//     // ===================================================================
    
//     logic signed [DATA_W-1:0] delayed_L_tap0, delayed_L_tap1;
//     logic signed [DATA_W-1:0] delayed_R_tap0, delayed_R_tap1;
    
//     // Left channel - tap 0
//     delay_line #(
//         .DATA_W(DATA_W),
//         .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES),
//         .ADDR_W(ADDR_W)
//     ) chorus_delay_L_tap0 (
//         .clk(clk),
//         .reset_n(reset_n),
//         .data_in(audio_in[0]),
//         .data_out(delayed_L_tap0),
//         .delay_samples(delay_int_L),
//         .sample_en(sample_en)
//     );
    
//     // Left channel - tap 1 (for interpolation)
//     delay_line #(
//         .DATA_W(DATA_W),
//         .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES),
//         .ADDR_W(ADDR_W)
//     ) chorus_delay_L_tap1 (
//         .clk(clk),
//         .reset_n(reset_n),
//         .data_in(audio_in[0]),
//         .data_out(delayed_L_tap1),
//         .delay_samples(delay_int_plus1_L),
//         .sample_en(sample_en)
//     );
    
//     // Right channel - tap 0
//     delay_line #(
//         .DATA_W(DATA_W),
//         .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES),
//         .ADDR_W(ADDR_W)
//     ) chorus_delay_R_tap0 (
//         .clk(clk),
//         .reset_n(reset_n),
//         .data_in(audio_in[1]),
//         .data_out(delayed_R_tap0),
//         .delay_samples(delay_int_R),
//         .sample_en(sample_en)
//     );
    
//     // Right channel - tap 1
//     delay_line #(
//         .DATA_W(DATA_W),
//         .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES),
//         .ADDR_W(ADDR_W)
//     ) chorus_delay_R_tap1 (
//         .clk(clk),
//         .reset_n(reset_n),
//         .data_in(audio_in[1]),
//         .data_out(delayed_R_tap1),
//         .delay_samples(delay_int_plus1_R),
//         .sample_en(sample_en)
//     );

//     // ===================================================================
//     // Linear interpolation and mixing
//     // ===================================================================
    
//     always_ff @(posedge clk) begin
//         if (!reset_n) begin
//             audio_out <= '0;
//         end else if (sample_en) begin
//             automatic logic signed [31:0] interp_L, interp_R;
//             automatic logic signed [31:0] wet_L, dry_L, mixed_L;
//             automatic logic signed [31:0] wet_R, dry_R, mixed_R;
//             automatic logic signed [8:0] dry_gain;
            
//             // Linear interpolation: out = tap0 * (1-frac) + tap1 * frac
//             // frac is 8-bit (0-255), so (256-frac) gives (1-frac)
//             interp_L = (($signed(delayed_L_tap0) * (256 - delay_frac_L)) + 
//                         ($signed(delayed_L_tap1) * delay_frac_L)) >>> 8;
                        
//             interp_R = (($signed(delayed_R_tap0) * (256 - delay_frac_R)) + 
//                         ($signed(delayed_R_tap1) * delay_frac_R)) >>> 8;
            
//             // Mix calculation
//             dry_gain = 9'sd256 - $signed({1'b0, fx_mix});
            
//             wet_L = interp_L * $signed({1'b0, fx_mix});
//             dry_L = $signed(audio_in[0]) * dry_gain;
//             mixed_L = (wet_L + dry_L) >>> 8;
            
//             wet_R = interp_R * $signed({1'b0, fx_mix});
//             dry_R = $signed(audio_in[1]) * dry_gain;
//             mixed_R = (wet_R + dry_R) >>> 8;
            
//             // Saturate and output
//             audio_out[0] <= sat16(mixed_L);
//             audio_out[1] <= sat16(mixed_R);
//         end
//     end

// endmodule


// Chorus Effect - Pipelined version for timing closure
module fx_chorus #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                      clk,
    input  logic                      reset_n,
    input  logic signed [1:0][DATA_W-1:0]    audio_in,   // Stereo input
    output logic signed [1:0][DATA_W-1:0]    audio_out,  // Stereo output
    input  logic [PARAM_W-1:0]        fx_rate,       // LFO rate (0-255)
    input  logic [PARAM_W-1:0]        fx_depth,      // Modulation depth (0-255)
    input  logic [PARAM_W-1:0]        fx_mix,        // Dry/wet mix (0-255)
    input  logic                      sample_en
);

    import lab_pkg::*;

    // Simplified chorus - single delay line, no interpolation for timing
    localparam SAMPLE_RATE = 48000;
    localparam BASE_DELAY_MS = 25;
    localparam MAX_MOD_MS = 3;
    localparam BASE_DELAY_SAMPLES = (BASE_DELAY_MS * SAMPLE_RATE) / 1000;
    localparam MAX_MOD_SAMPLES = (MAX_MOD_MS * SAMPLE_RATE) / 1000;
    localparam MAX_DELAY_SAMPLES = BASE_DELAY_SAMPLES + MAX_MOD_SAMPLES;
    localparam ADDR_W = $clog2(MAX_DELAY_SAMPLES);

    // ===================================================================
    // Pipeline stage signals
    // ===================================================================
    logic [2:0] sample_en_pipe;  // 3-stage pipeline
    logic signed [1:0][DATA_W-1:0] audio_in_pipe [0:2];
    
    // ===================================================================
    // Stage 0: LFO generation
    // ===================================================================
    
    logic [23:0] lfo_phase;
    logic [23:0] lfo_increment;
    logic signed [15:0] lfo_triangle_s0;
    
    always_comb begin
        lfo_increment = 17 + ((fx_rate * 24'd650) >> 8);
    end
    
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            lfo_phase <= 0;
            lfo_triangle_s0 <= 0;
        end else if (sample_en) begin
            lfo_phase <= lfo_phase + lfo_increment;
            
            // Simple triangle wave
            if (lfo_phase[23])
                lfo_triangle_s0 <= -$signed({1'b0, lfo_phase[22:8]});
            else
                lfo_triangle_s0 <= $signed({1'b0, lfo_phase[22:8]});
        end
    end

    // ===================================================================
    // Stage 1: Modulation calculation
    // ===================================================================
    
    logic signed [31:0] modulation_s1;
    logic signed [31:0] delay_calc_L_s1, delay_calc_R_s1;
    logic [ADDR_W-1:0] delay_L_s1, delay_R_s1;
    
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            modulation_s1 <= 0;
            delay_L_s1 <= BASE_DELAY_SAMPLES[ADDR_W-1:0];
            delay_R_s1 <= BASE_DELAY_SAMPLES[ADDR_W-1:0];
        end else if (sample_en_pipe[0]) begin
            // Calculate modulation
            modulation_s1 <= ($signed(lfo_triangle_s0) * $signed({1'b0, fx_depth}) * MAX_MOD_SAMPLES) >>> 16;
            
            // Calculate delays with simple clamping
            delay_calc_L_s1 = $signed({1'b0, BASE_DELAY_SAMPLES[ADDR_W-1:0]}) + modulation_s1;
            delay_calc_R_s1 = $signed({1'b0, BASE_DELAY_SAMPLES[ADDR_W-1:0]}) - modulation_s1;
            
            // Clamp delays
            if (delay_calc_L_s1 < 10)
                delay_L_s1 <= 10;
            else if (delay_calc_L_s1 >= MAX_DELAY_SAMPLES[ADDR_W-1:0])
                delay_L_s1 <= MAX_DELAY_SAMPLES[ADDR_W-1:0] - 1;
            else
                delay_L_s1 <= delay_calc_L_s1[ADDR_W-1:0];
                
            if (delay_calc_R_s1 < 10)
                delay_R_s1 <= 10;
            else if (delay_calc_R_s1 >= MAX_DELAY_SAMPLES[ADDR_W-1:0])
                delay_R_s1 <= MAX_DELAY_SAMPLES[ADDR_W-1:0] - 1;
            else
                delay_R_s1 <= delay_calc_R_s1[ADDR_W-1:0];
        end
    end

    // ===================================================================
    // Stage 2: Delay line read (happens in delay_line module)
    // ===================================================================
    
    logic signed [DATA_W-1:0] delayed_L_s2, delayed_R_s2;
    
    delay_line #(
        .DATA_W(DATA_W),
        .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES),
        .ADDR_W(ADDR_W)
    ) chorus_delay_L (
        .clk(clk),
        .reset_n(reset_n),
        .data_in(audio_in[0]),
        .data_out(delayed_L_s2),
        .delay_samples(delay_L_s1),
        .sample_en(sample_en)
    );
    
    delay_line #(
        .DATA_W(DATA_W),
        .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES),
        .ADDR_W(ADDR_W)
    ) chorus_delay_R (
        .clk(clk),
        .reset_n(reset_n),
        .data_in(audio_in[1]),
        .data_out(delayed_R_s2),
        .delay_samples(delay_R_s1),
        .sample_en(sample_en)
    );

    // ===================================================================
    // Stage 3: Mixing
    // ===================================================================
    
    logic signed [31:0] wet_L_s3, dry_L_s3, mixed_L_s3;
    logic signed [31:0] wet_R_s3, dry_R_s3, mixed_R_s3;
    logic signed [8:0] dry_gain_s3;
    
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            wet_L_s3 <= 0;
            wet_R_s3 <= 0;
            dry_L_s3 <= 0;
            dry_R_s3 <= 0;
            dry_gain_s3 <= 256;
        end else if (sample_en_pipe[1]) begin
            // Calculate gains
            dry_gain_s3 <= 9'sd256 - $signed({1'b0, fx_mix});
            
            // Multiply stage
            wet_L_s3 <= $signed(delayed_L_s2) * $signed({1'b0, fx_mix});
            wet_R_s3 <= $signed(delayed_R_s2) * $signed({1'b0, fx_mix});
            dry_L_s3 <= $signed(audio_in_pipe[2][0]) * dry_gain_s3;
            dry_R_s3 <= $signed(audio_in_pipe[2][1]) * dry_gain_s3;
        end
    end
    
    // Stage 4: Final sum and output
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en_pipe[2]) begin
            mixed_L_s3 = (wet_L_s3 + dry_L_s3) >>> 8;
            mixed_R_s3 = (wet_R_s3 + dry_R_s3) >>> 8;
            
            audio_out[0] <= sat16(mixed_L_s3);
            audio_out[1] <= sat16(mixed_R_s3);
        end
    end

    // ===================================================================
    // Pipeline control - align sample_en and audio_in through pipeline
    // ===================================================================
    
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            sample_en_pipe <= '0;
            for (int i = 0; i <= 2; i++)
                audio_in_pipe[i] <= '0;
        end else begin
            // Pipeline sample_en
            sample_en_pipe[0] <= sample_en;
            sample_en_pipe[1] <= sample_en_pipe[0];
            sample_en_pipe[2] <= sample_en_pipe[1];
            
            // Pipeline audio_in for proper alignment
            if (sample_en) begin
                audio_in_pipe[0] <= audio_in;
            end
            if (sample_en_pipe[0]) begin
                audio_in_pipe[1] <= audio_in_pipe[0];
            end
            if (sample_en_pipe[1]) begin
                audio_in_pipe[2] <= audio_in_pipe[1];
            end
        end
    end

endmodule

