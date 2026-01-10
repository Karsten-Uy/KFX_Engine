
module fx_chorus #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                        clk,
    input  logic                        reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,
    output logic signed [1:0][DATA_W-1:0] audio_out,
    input  logic [PARAM_W-1:0]          fx_rate,    
    input  logic [PARAM_W-1:0]          fx_depth,   
    input  logic [PARAM_W-1:0]          fx_mix,     
    input  logic                        sample_en
);

    localparam SAMPLE_RATE = 48000;
    localparam BASE_DELAY_MS = 20; 
    localparam MAX_MOD_MS = 5;      // Reduced from 10ms to 5ms for tighter chorus
    localparam BASE_DELAY_SAMPLES = (BASE_DELAY_MS * SAMPLE_RATE) / 1000;
    localparam MAX_MOD_SAMPLES = (MAX_MOD_MS * SAMPLE_RATE) / 1000;
    localparam MAX_DELAY_SAMPLES = 2048; // Power of 2 helps Quartus infer RAM easily
    localparam ADDR_W = $clog2(MAX_DELAY_SAMPLES);

    // --- Stage 0: LFO (Smoother Triangle) ---
    logic [23:0] lfo_phase;
    logic signed [15:0] lfo_tri;
    
    // Slower rate for voices (Chorus rate is usually 0.5Hz to 3Hz)
    logic [23:0] lfo_inc;
    assign lfo_inc = 10 + ((fx_rate * 24'd400) >> 8); 

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            lfo_phase <= 0;
            lfo_tri   <= 0;
        end else if (sample_en) begin
            lfo_phase <= lfo_phase + lfo_inc;
            // 16-bit Triangle wave generation
            lfo_tri <= lfo_phase[23] ? $signed(~lfo_phase[22:7]) : $signed(lfo_phase[22:7]);
        end
    end

    // --- Stage 1: Delay Calc (Limit the Depth) ---
    logic [ADDR_W-1:0] delay_L, delay_R;
    always_ff @(posedge clk) begin
        if (sample_en) begin
            // We scale the LFO by fx_depth and MAX_MOD_SAMPLES
            // This ensures 0 depth = static delay (no modulation)
            automatic logic signed [31:0] mod_offset;
            mod_offset = ($signed(lfo_tri) * $signed({1'b0, fx_depth})) >>> 16;
            
            // Map mod_offset to a small sample range (e.g., +/- 100 samples)
            // Divide by 128 or similar to keep the "swing" musical
            delay_L <= BASE_DELAY_SAMPLES[ADDR_W-1:0] + mod_offset[ADDR_W-1:0];
            delay_R <= BASE_DELAY_SAMPLES[ADDR_W-1:0] - mod_offset[ADDR_W-1:0];
        end
    end

    // --- Stage 2: Delay Lines ---
    logic signed [DATA_W-1:0] wet_L, wet_R;
    
    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES)) 
    chorus_L (.clk, .reset_n, .sample_en, .data_in(audio_in[0]), .data_out(wet_L), .delay_samples(delay_L));

    delay_line #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES)) 
    chorus_R (.clk, .reset_n, .sample_en, .data_in(audio_in[1]), .data_out(wet_R), .delay_samples(delay_R));

    // --- Stage 3: Precise Alignment & Mix ---
    // M10K delay_line has 2 cycles of latency (1 for RAM, 1 for output reg)
    // We MUST delay the dry signal by exactly 2 sample_en cycles
    logic signed [1:0][DATA_W-1:0] dry_pipe_1, dry_pipe_2;

    // 2. Mix with 32-bit Headroom to prevent distortion
    logic signed [31:0] mix_L, mix_R;
    logic [8:0] w_gain, d_gain;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            // 1. Align the dry signal
            dry_pipe_1 <= audio_in;
            dry_pipe_2 <= dry_pipe_1;
            
            w_gain = {1'b0, fx_mix};       // 0 to 255
            d_gain = 9'd255 - w_gain;      // 255 down to 0

            mix_L = ($signed(wet_L) * $signed(w_gain)) + ($signed(dry_pipe_2[0]) * $signed(d_gain));
            mix_R = ($signed(wet_R) * $signed(w_gain)) + ($signed(dry_pipe_2[1]) * $signed(d_gain));

            // 3. Scale back and Saturate
            // Divide by 255 (approx >>> 8)
            audio_out[0] <= sat16(mix_L >>> 8);
            audio_out[1] <= sat16(mix_R >>> 8);
        end
    end

    function automatic logic signed [15:0] sat16(logic signed [31:0] val);
        if (val > 32767) return 16'sh7FFF;
        else if (val < -32768) return 16'sh8000;
        else return val[15:0];
    endfunction

endmodule