/*

    Reverb module that implements the Schroeder Reverberator that uses a combination 
    of parallel feedback comb filters and series all-pass filters to simulate reverberation
    in a room

    Parameters:
        fx_size     - Controls the "size" of the room AKA delay times (0-255)
        fx_damping  - Controls how much the reverberation is damped (0-255)
        fx_mix      - Mix control determining how much of the wet signal is in
                      the output of this FX. (fx_mix == 0) => all dry, 
                      (fx_mix == 255) => all wet

    Architecture uses a two-stage filter design:
    
    Stage 1 - Parallel Feedback Comb Filters (4 filters):
        Creates the initial reverb tail with different delay times. Each comb filter
        implements the following difference equation where g is the feedback gain
        (controlled by fx_damping), and d is the delay time (controlled by fx_size):
        
            y[n] = x[n] + g * y[n-d]
            output[n] = y[n-d]
        
        The four comb filters have prime number base delays to avoid modal resonances:
            - Comb 1: 1117 samples (~23ms) base delay
            - Comb 2: 1171 samples (~24ms) base delay  
            - Comb 3: 1277 samples (~27ms) base delay
            - Comb 4: 1356 samples (~28ms) base delay
        
        fx_size scales these delays: delay = base_delay * (1.0 + fx_size/256)
        
        All comb outputs are summed together.
    
    Stage 2 - Series Allpass Filters (2 filters):
        Diffuses the summed comb output without changing frequency response.
        Each allpass filter implements the difference equation where g = 0.5
        and d is a fixed delay:
        
            y[n] = -g*x[n] + x[n-d] + g*y[n-d]
        
        The two allpass filters have fixed delays:
            - Allpass 1: 556 samples (~12ms)
            - Allpass 2: 441 samples (~9ms)
    
    Signal flow:
        Stereo Input → Mix to Mono → [Comb1, Comb2, Comb3, Comb4] → Sum → 
        Divide by 4 → Allpass1 → Allpass2 → Wet Signal → Mix with Dry → Stereo Output
    
    The output is:
        audio_out[n] = (wet_signal[n] * fx_mix + dry_signal[n] * (256 - fx_mix)) / 256
    
    Latency = 4 Samples

*/

module fx_reverb #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                        clk,
    input  logic                        reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,   // Stereo input
    output logic signed [1:0][DATA_W-1:0] audio_out,  // Stereo output
    input  logic [PARAM_W-1:0]          fx_size,
    input  logic [PARAM_W-1:0]          fx_damping,
    input  logic [PARAM_W-1:0]          fx_mix,
    input  logic                        sample_en
);

    // ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;
        
    // ---------------- CONSTANTS ----------------
    // Schroeder Reverb uses 4 parallel comb filters + 2 series allpass filters
    // Prime number delays for natural sound (avoid modal resonances)    
    // Comb filter delays (in samples at 48kHz) - these create the reverb tail
    localparam COMB1_BASE = 1117;  // ~23ms
    localparam COMB2_BASE = 1171;  // ~24ms
    localparam COMB3_BASE = 1277;  // ~27ms
    localparam COMB4_BASE = 1356;  // ~28ms
    
    // Allpass filter delays - these diffuse the sound
    localparam ALLPASS1_DELAY = 556;   // ~12ms
    localparam ALLPASS2_DELAY = 441;   // ~9ms
    
    // Maximum delay for any line (used for buffer sizing)
    localparam MAX_COMB_DELAY = 2712;
    localparam COMB_ADDR_W = $clog2(MAX_COMB_DELAY);
    localparam ALLPASS_ADDR_W = $clog2(ALLPASS1_DELAY);
    
    // Allpass coefficient (fixed at 0.5 for stability)
    localparam ALLPASS_COEF = 8'd128;
    
    // ---------------- INTERNAL SIGNALS ----------------
    // Delay calculation
    logic [COMB_ADDR_W-1:0] comb1_delay, comb2_delay, comb3_delay, comb4_delay;

    // Comb Filter
    logic [7:0] comb_feedback;
    logic [7:0] damping_factor;
    logic signed [DATA_W-1:0] comb1_out, comb2_out, comb3_out, comb4_out;
    logic signed [DATA_W-1:0] comb1_delayed, comb2_delayed, comb3_delayed, comb4_delayed;
    logic signed [DATA_W-1:0] comb1_in, comb2_in, comb3_in, comb4_in;
    logic signed [31:0] comb1_fb, comb2_fb, comb3_fb, comb4_fb;
    logic signed [DATA_W+1:0] comb_sum;

    // allpass filter
    logic signed [DATA_W-1:0] allpass1_in, allpass1_out;
    logic signed [DATA_W-1:0] allpass2_in, allpass2_out;
    logic signed [DATA_W-1:0] allpass1_delayed, allpass2_delayed;
    logic signed [31:0] ap1_feed, ap1_back, ap2_feed, ap2_back;

    // Final mix
    logic signed [DATA_W:0] mono_in;
    logic signed [DATA_W-1:0] wet_L, wet_R;
    logic signed [31:0] mixed_L, mixed_R;
    logic signed [31:0] dry_L, dry_R;
    logic signed [31:0] wet_scaled_L, wet_scaled_R;
    logic signed [8:0] dry_gain;

    // ---------------- DELAY LINE INSTANTIATION ----------------

    // 4 for comb filtering
    delay_line #(
        .DATA_W(DATA_W),
        .MAX_DELAY_SAMPLES(MAX_COMB_DELAY),
        .ADDR_W(COMB_ADDR_W)
    ) comb1_delay_line (
        .clk(clk),
        .reset_n(reset_n),
        .sample_en(sample_en),
        .data_in(comb1_in),
        .data_out(comb1_delayed),
        .delay_samples(comb1_delay)
    );
    
    delay_line #(
        .DATA_W(DATA_W),
        .MAX_DELAY_SAMPLES(MAX_COMB_DELAY),
        .ADDR_W(COMB_ADDR_W)
    ) comb2_delay_line (
        .clk(clk),
        .reset_n(reset_n),
        .sample_en(sample_en),
        .data_in(comb2_in),
        .data_out(comb2_delayed),
        .delay_samples(comb2_delay)
    );
    
    delay_line #(
        .DATA_W(DATA_W),
        .MAX_DELAY_SAMPLES(MAX_COMB_DELAY),
        .ADDR_W(COMB_ADDR_W)
    ) comb3_delay_line (
        .clk(clk),
        .reset_n(reset_n),
        .sample_en(sample_en),
        .data_in(comb3_in),
        .data_out(comb3_delayed),
        .delay_samples(comb3_delay)
    );
    
    delay_line #(
        .DATA_W(DATA_W),
        .MAX_DELAY_SAMPLES(MAX_COMB_DELAY),
        .ADDR_W(COMB_ADDR_W)
    ) comb4_delay_line (
        .clk(clk),
        .reset_n(reset_n),
        .sample_en(sample_en),
        .data_in(comb4_in),
        .data_out(comb4_delayed),
        .delay_samples(comb4_delay)
    );
    
    // 2 for allpass filter
    delay_line #(
        .DATA_W(DATA_W),
        .MAX_DELAY_SAMPLES(ALLPASS1_DELAY),
        .ADDR_W(ALLPASS_ADDR_W)
    ) allpass1_delay_line (
        .clk(clk),
        .reset_n(reset_n),
        .sample_en(sample_en),
        .data_in(allpass1_in),
        .data_out(allpass1_delayed),
        .delay_samples(ALLPASS1_DELAY[ALLPASS_ADDR_W-1:0])
    );
    
    delay_line #(
        .DATA_W(DATA_W),
        .MAX_DELAY_SAMPLES(ALLPASS2_DELAY),
        .ADDR_W(ALLPASS_ADDR_W)
    ) allpass2_delay_line (
        .clk(clk),
        .reset_n(reset_n),
        .sample_en(sample_en),
        .data_in(allpass2_in),
        .data_out(allpass2_delayed),
        .delay_samples(ALLPASS2_DELAY[ALLPASS_ADDR_W-1:0])
    );

    // ---------------------- COMB FILTER ---------------------
    
    // Dynamic delay calculation based on fx_size
    // Scale delays: base_delay * (1.0 + fx_size/256)
    always_comb begin
        comb1_delay = COMB1_BASE + ((COMB1_BASE * fx_size) >> 8);
        comb2_delay = COMB2_BASE + ((COMB2_BASE * fx_size) >> 8);
        comb3_delay = COMB3_BASE + ((COMB3_BASE * fx_size) >> 8);
        comb4_delay = COMB4_BASE + ((COMB4_BASE * fx_size) >> 8);
    end
    
    // Comb Filter Feedback Gain with Damping 
    // - Damping reduces high frequencies in the feedback path
    always_comb begin
        damping_factor = 8'd216 - (fx_damping >> 2);
        comb_feedback = damping_factor;
    end
    
    // Mono input (mix L+R)
    always_comb begin
        mono_in = ($signed(audio_in[0]) + $signed(audio_in[1])) >>> 1;
    end
    
    // Comb filter calculation
    always_comb begin
        // Calculate feedback signals
        comb1_fb = ($signed(comb1_delayed) * $signed({1'b0, comb_feedback})) >>> 8;
        comb2_fb = ($signed(comb2_delayed) * $signed({1'b0, comb_feedback})) >>> 8;
        comb3_fb = ($signed(comb3_delayed) * $signed({1'b0, comb_feedback})) >>> 8;
        comb4_fb = ($signed(comb4_delayed) * $signed({1'b0, comb_feedback})) >>> 8;
        
        // Add input + feedback (with saturation)
        comb1_in = sat16($signed(mono_in) + comb1_fb);
        comb2_in = sat16($signed(mono_in) + comb2_fb);
        comb3_in = sat16($signed(mono_in) + comb3_fb);
        comb4_in = sat16($signed(mono_in) + comb4_fb);
        
        // Output is the delayed signal
        comb1_out = comb1_delayed;
        comb2_out = comb2_delayed;
        comb3_out = comb3_delayed;
        comb4_out = comb4_delayed;

        // Sum all comb filter outputs
        comb_sum = $signed(comb1_out) + $signed(comb2_out) + 
                   $signed(comb3_out) + $signed(comb4_out);
    end    

    // ----------------------- ALLPASS FILTERS (Series) ----------------------
    // Allpass filters diffuse the sound without changing frequency response    
    
    // Scale down comb sum before allpass (divide by 4 to prevent overflow)
    always_comb begin
        allpass1_in = sat16(comb_sum >>> 2);
    end
    
    // Allpass 1: y[n] = -g*x[n] + x[n-d] + g*y[n-d]
    always_comb begin
        ap1_feed = ($signed(allpass1_in) * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap1_back = ($signed(allpass1_delayed) * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass1_out = sat16(-ap1_feed + $signed(allpass1_delayed) + ap1_back);
    end
        
    // Allpass 2 (cascaded)
    always_comb begin
        allpass2_in = allpass1_out;
        ap2_feed = ($signed(allpass2_in) * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap2_back = ($signed(allpass2_delayed) * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass2_out = sat16(-ap2_feed + $signed(allpass2_delayed) + ap2_back);
    end

    // Mix
    always_comb begin
        wet_L = allpass2_out;
        wet_R = allpass2_out;

        // Calculate dry gain for unity gain mixing
        dry_gain = 9'sd256 - $signed({1'b0, fx_mix});
        
        // Mix calculation
        wet_scaled_L = ($signed(wet_L) * $signed({1'b0, fx_mix}));
        wet_scaled_R = ($signed(wet_R) * $signed({1'b0, fx_mix}));
        dry_L = ($signed(audio_in[0]) * dry_gain);
        dry_R = ($signed(audio_in[1]) * dry_gain);        
        mixed_L = (wet_scaled_L + dry_L) >>> 8;
        mixed_R = (wet_scaled_R + dry_R) >>> 8;
    end
    
    // ---------------- OUTPUT ----------------
    
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin            
            audio_out[0] <= sat16(mixed_L);
            audio_out[1] <= sat16(mixed_R);
        end
    end

endmodule