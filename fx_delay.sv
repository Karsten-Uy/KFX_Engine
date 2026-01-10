
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
    
    localparam MAX_SAMPLES = 24000;
    localparam ADDR_W = $clog2(MAX_SAMPLES);

    logic [ADDR_W-1:0] target_delay;
    logic signed [DATA_W-1:0] delayed_L, delayed_R;
    logic signed [DATA_W-1:0] fb_in_L, fb_in_R;
    logic signed [31:0] fb_scaled_L, fb_scaled_R;

    // Map fx_time with minimum delay to avoid artifacts
    assign target_delay = 480 + ((fx_time * (MAX_SAMPLES - 480)) >> 8);  // 10ms minimum

    // --- FEEDBACK PATH ---
    always_comb begin
        // Feedback scaled to max 0.875 to prevent runaway (224/256)
        fb_scaled_L = ($signed(delayed_L) * $signed({1'b0, fx_feedback}) * 224) >>> 16;
        fb_scaled_R = ($signed(delayed_R) * $signed({1'b0, fx_feedback}) * 224) >>> 16;

        // Saturate feedback sum
        fb_in_L = sat16($signed(audio_in[0]) + fb_scaled_L);
        fb_in_R = sat16($signed(audio_in[1]) + fb_scaled_R);
    end

    // --- DELAY INSTANCES ---
    delay_line #(
        .DATA_W(DATA_W), 
        .MAX_DELAY_SAMPLES(MAX_SAMPLES),
        .ADDR_W(ADDR_W)
    ) unit_L (
        .clk(clk),
        .reset_n(reset_n),
        .sample_en(sample_en),
        .data_in(fb_in_L),
        .data_out(delayed_L),
        .delay_samples(target_delay)
    );

    delay_line #(
        .DATA_W(DATA_W), 
        .MAX_DELAY_SAMPLES(MAX_SAMPLES),
        .ADDR_W(ADDR_W)
    ) unit_R (
        .clk(clk),
        .reset_n(reset_n),
        .sample_en(sample_en),
        .data_in(fb_in_R),
        .data_out(delayed_R),
        .delay_samples(target_delay)
    );

    // Use signed arithmetic throughout
    logic signed [31:0] wet_L, dry_L, mixed_L;
    logic signed [31:0] wet_R, dry_R, mixed_R;
    logic signed [8:0] dry_gain;  // 9-bit signed for 256-fx_mix

    // --- MIXING OUTPUT (FIXED) ---
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            
            // Calculate dry gain (256 - fx_mix) to maintain unity gain
            dry_gain = 9'sd256 - $signed({1'b0, fx_mix});
            
            // Mix calculation with proper bit widths
            // wet = delayed * fx_mix / 256
            // dry = input * (256 - fx_mix) / 256
            wet_L = ($signed(delayed_L) * $signed({1'b0, fx_mix}));
            dry_L = ($signed(audio_in[0]) * dry_gain);
            mixed_L = (wet_L + dry_L) >>> 8;
            
            wet_R = ($signed(delayed_R) * $signed({1'b0, fx_mix}));
            dry_R = ($signed(audio_in[1]) * dry_gain);
            mixed_R = (wet_R + dry_R) >>> 8;
            
            // Saturate output
            audio_out[0] <= sat16(mixed_L);
            audio_out[1] <= sat16(mixed_R);
        end
    end

endmodule