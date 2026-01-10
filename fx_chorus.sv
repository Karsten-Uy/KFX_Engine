/*

    Chorus module that duplicates and delays the input audio signal with delay lines, then 
    subtly modulates the amplitude of the copies using a Low-Frequency Oscillator (LFO). After 
    that, it blends the copies them back with the original to create a thicker, richer sound,
    simulating multiple instruments or singers performing the same part.
        - LFO is a triangle wave

    Parameters:
        fx_rate     - Controls the frequency of the LFO
        fx_depth    - Controls the amplitude modulation done by the LFO
        fx_mix      - Mix control determining how much of the wet signal is in
                      the output of this FX. (fx_mix == 0) => all dry, 
                      (fx_mix == 255) => all wet

*/

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

    // ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;
    
    // ---------------- CONSTANTS ----------------
    localparam BASE_DELAY_MS = 20; 
    localparam MAX_MOD_MS = 5;      // Reduced from 10ms to 5ms for tighter chorus
    localparam BASE_DELAY_SAMPLES = (BASE_DELAY_MS * SAMPLE_RATE) / 1000;
    localparam MAX_MOD_SAMPLES = (MAX_MOD_MS * SAMPLE_RATE) / 1000;
    localparam MAX_DELAY_SAMPLES = 2048; // Power of 2 helps Quartus infer RAM easily
    localparam ADDR_W = $clog2(MAX_DELAY_SAMPLES);

    // ---------------- INTERNAL SIGNALS ----------------

    // LFO (Smooth Triangle)
    logic [23:0] lfo_phase;
    logic signed [15:0] lfo_tri;    
    logic [23:0] lfo_inc;

    // Delay
    logic [ADDR_W-1:0] delay_L, delay_R;

    // Mixed Signals
    logic signed [DATA_W-1:0] wet_L, wet_R;
    logic signed [1:0][DATA_W-1:0] dry_pipe_1, dry_pipe_2;
    logic signed [31:0] mix_L, mix_R;
    logic [8:0] w_gain, d_gain;

    // ---------------- DELAY LINE INSTANTIATION ----------------
    // Have 1 for each side (left-right)

    delay_line #(
        .DATA_W(DATA_W), 
        .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES)
    ) chorus_L (
        .clk(clk), 
        .reset_n(reset_n), 
        .sample_en(sample_en), 
        .data_in(audio_in[0]), 
        .data_out(wet_L), 
        .delay_samples(delay_L)
    );

    delay_line #(
        .DATA_W(DATA_W), 
        .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES)
    ) chorus_R (
        .clk(clk), 
        .reset_n(reset_n), 
        .sample_en(sample_en), 
        .data_in(audio_in[1]), 
        .data_out(wet_R), 
        .delay_samples(delay_R)
    );

    // ---------------- MAIN CHORUS CALCULATION ----------------

    // LFO increment (Chorus rate is usually 0.5Hz to 3Hz)
    assign lfo_inc = 10 + ((fx_rate * 24'd400) >> 8); 

    // LFO FF
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

    // Delay Calc (Limit the Depth)
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

    // Mix + feedback Calculation
    always_comb begin
        w_gain = {1'b0, fx_mix};       // 0 to 255
        d_gain = 9'd255 - w_gain;      // 255 down to 0

        mix_L = ($signed(wet_L) * $signed(w_gain)) + ($signed(dry_pipe_2[0]) * $signed(d_gain));
        mix_R = ($signed(wet_R) * $signed(w_gain)) + ($signed(dry_pipe_2[1]) * $signed(d_gain));
    end

    // Precise Alignment & Mix
    // M10K delay_line has 2 cycles of latency (1 for RAM, 1 for output reg)
    // We MUST delay the dry signal by exactly 2 sample_en cycles

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            // 1. Align the dry signal
            dry_pipe_1 <= audio_in;
            dry_pipe_2 <= dry_pipe_1;            

            // 3. Scale back and Saturate
            // Divide by 255 (approx >>> 8)
            audio_out[0] <= sat16(mix_L >>> 8);
            audio_out[1] <= sat16(mix_R >>> 8);
        end
    end


endmodule