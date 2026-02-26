/*
    Chorus module (Fixed)
    - Replaced Voice 2 with Linear Interpolation to eliminate quantization "buzz".
    - Maintains two independent voices for a lush stereo spread.
    - Synchronized dry pipeline for phase alignment.
*/

module fx_chorus #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                          clk,
    input  logic                          reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,
    output logic signed [1:0][DATA_W-1:0] audio_out,
    input  logic [PARAM_W-1:0]            fx_rate,    
    input  logic [PARAM_W-1:0]            fx_depth,   
    input  logic [PARAM_W-1:0]            fx_mix,     
    input  logic                          sample_en
);

    import lab_pkg::*;
    
    // ---------------- CONSTANTS ----------------
    localparam FRAC_W = 4; // Fractional bits for interpolation

    localparam BASE_DELAY_MS_V1  = 20; 
    localparam BASE_DELAY_MS_V2  = 28;
    localparam BASE_DELAY_V1     = (BASE_DELAY_MS_V1 * SAMPLE_RATE) / 1000;
    localparam BASE_DELAY_V2     = (BASE_DELAY_MS_V2 * SAMPLE_RATE) / 1000;
    localparam MAX_DELAY_SAMPLES = 2048; 
    localparam ADDR_W            = $clog2(MAX_DELAY_SAMPLES);

    // ---------------- INTERNAL SIGNALS ----------------

    logic [23:0] lfo_phase;
    logic [23:0] lfo_inc;
    logic [23:0] ph90;
    logic signed [15:0] lfo_tri_0;
    logic signed [15:0] lfo_tri_90;

    // Voice Accumulators (Q16.16)
    logic signed [31:0] v1_L_acc, v1_R_acc;
    logic signed [31:0] v2_L_acc, v2_R_acc;
    
    // Delay control signals (including fractional bits)
    logic [ADDR_W+FRAC_W-1:0] v1_L_fixed, v1_R_fixed;
    logic [ADDR_W+FRAC_W-1:0] v2_L_fixed, v2_R_fixed;
    
    logic signed [DATA_W-1:0] wet_v1_L, wet_v1_R;
    logic signed [DATA_W-1:0] wet_v2_L, wet_v2_R;

    // Modulation and Mix
    logic signed [31:0] mod_0, mod_90;
    logic signed [31:0] target_v1L, target_v1R, target_v2L, target_v2R;
    logic signed [1:0][DATA_W-1:0] dry_pipe[3:0]; // Match delay line latency

    logic signed [32:0] avg_wet_L, avg_wet_R;
    logic signed [31:0] mix_L, mix_R;

    // ---------------- DELAY LINE INSTANTIATION ----------------
    // All voices now use linear interpolation to prevent aliasing (buzz)

    delay_line_li #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES), .FRAC_W(FRAC_W)) 
    DL_V1_L (.clk(clk), .reset_n(reset_n), .sample_en(sample_en), .data_in(audio_in[0]), .data_out(wet_v1_L), .delay_samples(v1_L_fixed));

    delay_line_li #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES), .FRAC_W(FRAC_W)) 
    DL_V1_R (.clk(clk), .reset_n(reset_n), .sample_en(sample_en), .data_in(audio_in[1]), .data_out(wet_v1_R), .delay_samples(v1_R_fixed));

    delay_line_li #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES), .FRAC_W(FRAC_W)) 
    DL_V2_L (.clk(clk), .reset_n(reset_n), .sample_en(sample_en), .data_in(audio_in[0]), .data_out(wet_v2_L), .delay_samples(v2_L_fixed));

    delay_line_li #(.DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_DELAY_SAMPLES), .FRAC_W(FRAC_W)) 
    DL_V2_R (.clk(clk), .reset_n(reset_n), .sample_en(sample_en), .data_in(audio_in[1]), .data_out(wet_v2_R), .delay_samples(v2_R_fixed));

    // ---------------- LFO & MODULATION ----------------
    assign lfo_inc = 2 + ((fx_rate * 24'd80) >> 8);

    always_comb begin
        ph90 = lfo_phase + 24'h40_0000;

        // Tri wave: convert 0-2^24 to signed triangle
        lfo_tri_0  = lfo_phase[23] ? $signed(~lfo_phase[22:7]) : $signed(lfo_phase[22:7]);
        lfo_tri_90 = ph90[23]      ? $signed(~ph90[22:7])      : $signed(ph90[22:7]);

        mod_0  = ($signed(lfo_tri_0)  * $signed({1'b0, fx_depth})) >>> 18;
        mod_90 = ($signed(lfo_tri_90) * $signed({1'b0, fx_depth})) >>> 18;

        target_v1L = ($signed(BASE_DELAY_V1) + mod_0)  << 16;
        target_v1R = ($signed(BASE_DELAY_V1) - mod_0)  << 16;
        target_v2L = ($signed(BASE_DELAY_V2) + mod_90) << 16;
        target_v2R = ($signed(BASE_DELAY_V2) - mod_90) << 16;

        // Mix logic
        avg_wet_L = ($signed(wet_v1_L) + $signed(wet_v2_L)) >>> 1;
        avg_wet_R = ($signed(wet_v1_R) + $signed(wet_v2_R)) >>> 1;

        mix_L = (avg_wet_L * $signed({1'b0, fx_mix})) +
                ($signed(dry_pipe[3][0]) * $signed({1'b0, 8'd255 - fx_mix}));
        mix_R = (avg_wet_R * $signed({1'b0, fx_mix})) +
                ($signed(dry_pipe[3][1]) * $signed({1'b0, 8'd255 - fx_mix}));
    end

    // ---------------- SEQUENTIAL LOGIC ----------------
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            lfo_phase  <= 0;
            v1_L_acc   <= $signed(BASE_DELAY_V1) << 16;
            v1_R_acc   <= $signed(BASE_DELAY_V1) << 16;
            v2_L_acc   <= $signed(BASE_DELAY_V2) << 16;
            v2_R_acc   <= $signed(BASE_DELAY_V2) << 16;
            audio_out  <= '0;
        end else if (sample_en) begin
            lfo_phase  <= lfo_phase + lfo_inc;

            // Slew the delay targets to prevent clicks (Low-pass smoothing)
            v1_L_acc <= v1_L_acc + ((target_v1L - v1_L_acc) >>> 10);
            v1_R_acc <= v1_R_acc + ((target_v1R - v1_R_acc) >>> 10);
            v2_L_acc <= v2_L_acc + ((target_v2L - v2_L_acc) >>> 10);
            v2_R_acc <= v2_R_acc + ((target_v2R - v2_R_acc) >>> 10);

            // Extract ADDR_W + FRAC_W bits for the delay lines
            v1_L_fixed <= v1_L_acc[16+ADDR_W-1 : 16-FRAC_W];
            v1_R_fixed <= v1_R_acc[16+ADDR_W-1 : 16-FRAC_W];
            v2_L_fixed <= v2_L_acc[16+ADDR_W-1 : 16-FRAC_W];
            v2_R_fixed <= v2_R_acc[16+ADDR_W-1 : 16-FRAC_W];

            // Update Dry Pipeline and Final Output
            dry_pipe[0] <= audio_in;
            dry_pipe[1] <= dry_pipe[0];
            dry_pipe[2] <= dry_pipe[1];
            dry_pipe[3] <= dry_pipe[2];

            audio_out[0] <= sat16(mix_L >>> 8);
            audio_out[1] <= sat16(mix_R >>> 8);
        end
    end

endmodule