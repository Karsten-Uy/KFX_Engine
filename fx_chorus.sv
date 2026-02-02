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

    Latency = 3 Samples

*/

module fx_chorus #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                         clk,
    input  logic                         reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,
    output logic signed [1:0][DATA_W-1:0] audio_out,
    input  logic [PARAM_W-1:0]           fx_rate,    
    input  logic [PARAM_W-1:0]           fx_depth,   
    input  logic [PARAM_W-1:0]           fx_mix,     
    input  logic                         sample_en
);

    import lab_pkg::*;
    
    // ---------------- CONSTANTS ----------------
    localparam FRAC_W = 4;
    localparam BASE_DELAY_MS = 20; 
    localparam BASE_DELAY_SAMPLES = (BASE_DELAY_MS * SAMPLE_RATE) / 1000;
    localparam MAX_DELAY_SAMPLES = 2048; 
    localparam ADDR_W = $clog2(MAX_DELAY_SAMPLES);

    // ---------------- INTERNAL SIGNALS ----------------
    logic [23:0] lfo_phase;
    logic signed [15:0] lfo_tri;    
    logic [23:0] lfo_inc;

    // Smoothed Delay Accumulators (Q16.16 fixed point)
    logic signed [31:0] delay_L_acc, delay_R_acc;
    
    // Fixed-point delay signals (Integer bits + FRAC_W bits)
    logic [ADDR_W + FRAC_W - 1:0] delay_L_fixed, delay_R_fixed;

    logic signed [DATA_W-1:0] wet_L, wet_R;
    logic signed [1:0][DATA_W-1:0] dry_pipe_1, dry_pipe_2, dry_pipe_3;
    logic signed [31:0] mix_L, mix_R;
    logic signed [31:0] target_L, target_R;
    logic signed [31:0] mod_offset;
    
    // ---------------- DELAY LINE INSTANTIATION ----------------
    // These are the delay lines with linear interpolation, it sounded terrible 
    // without it

    delay_line_li #(
        .DATA_W(DATA_W), 
        .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES),
        .FRAC_W(FRAC_W)
    ) chorus_L (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en), 
        .data_in(audio_in[0]), .data_out(wet_L), 
        .delay_samples(delay_L_fixed)
    );

    delay_line_li #(
        .DATA_W(DATA_W), 
        .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES),
        .FRAC_W(FRAC_W)
    ) chorus_R (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en), 
        .data_in(audio_in[1]), .data_out(wet_R), 
        .delay_samples(delay_R_fixed)
    );

    // ---------------- LOGIC ----------------
    
    // Set LFO inc value, had to toggle to make the warble not too evident
    assign lfo_inc = 3 + ((fx_rate * 24'd120) >> 8);

    // LFO value calculation and delay smoothing
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            lfo_phase <= 0;
            lfo_tri   <= 0;
            delay_L_acc <= $signed(BASE_DELAY_SAMPLES) << 16;
            delay_R_acc <= $signed(BASE_DELAY_SAMPLES) << 16;
        end else if (sample_en) begin

            // LFO Generation (Triangle Wave)
            lfo_phase <= lfo_phase + lfo_inc;
            lfo_tri <= lfo_phase[23] ? $signed(~lfo_phase[22:7]) : $signed(lfo_phase[22:7]);

            // Short Modulation Depth
            mod_offset = ($signed(lfo_tri) * $signed({1'b0, fx_depth})) >>> 17; 
            
            target_L = ($signed(BASE_DELAY_SAMPLES) + mod_offset) << 16;
            target_R = ($signed(BASE_DELAY_SAMPLES) - mod_offset) << 16;

            // Heavy low-pass smoothing
            delay_L_acc <= delay_L_acc + ((target_L - delay_L_acc) >>> 13);
            delay_R_acc <= delay_R_acc + ((target_R - delay_R_acc) >>> 13);

            // Extract bits for the Interpolating Delay Line
            delay_L_fixed <= delay_L_acc[16 + ADDR_W - 1 : 16 - FRAC_W];
            delay_R_fixed <= delay_R_acc[16 + ADDR_W - 1 : 16 - FRAC_W];
        end
    end

    // ---------------- MIXING + OUTPUT ----------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            // 3 cycles of delay to match interpolating delay line latency
            dry_pipe_1 <= audio_in;
            dry_pipe_2 <= dry_pipe_1;
            dry_pipe_3 <= dry_pipe_2; 

            // Mix Logic (Dry/Wet)
            mix_L = ($signed(wet_L) * $signed({1'b0, fx_mix})) + 
                    ($signed(dry_pipe_3[0]) * $signed({1'b0, 8'd255 - fx_mix}));
            mix_R = ($signed(wet_R) * $signed({1'b0, fx_mix})) + 
                    ($signed(dry_pipe_3[1]) * $signed({1'b0, 8'd255 - fx_mix}));

            audio_out[0] <= sat16(mix_L >>> 8);
            audio_out[1] <= sat16(mix_R >>> 8);
        end
    end

endmodule
