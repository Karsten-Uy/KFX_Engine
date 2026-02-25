/*

    Delay module that uses delay lines to make a signal delay and connects it back on
    itself to implement feedback.

    Parameters:
        fx_time     - Time it takes until signal is heard again. Larger value => more time
        fx_feedback - How much the delayed signal is fed back into itself to create an 
                      echo effect. Is capped at 0.875 to prevent a runaway signal
        fx_mix      - Mix control determining how much of the wet signal is in
                      the output of this FX. (fx_mix == 0) => all dry, 
                      (fx_mix == 255) => all wet

    Latency = 2 Samples

*/

module fx_delay #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                          clk,
    input  logic                          reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,
    output logic signed [1:0][DATA_W-1:0] audio_out,
    input  logic [PARAM_W-1:0]            fx_time,    
    input  logic [PARAM_W-1:0]            fx_feedback, 
    input  logic [PARAM_W-1:0]            fx_mix,      
    input  logic                          sample_en,

    // ---- Tap-tempo override (from tap_tempo_unit) ----
    input  logic [$clog2(MAX_SAMPLES)-1:0] tap_samples,  // raw sample count
    input  logic                           tap_active     // 1 = use tap_samples
);
    
    // ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;
    
    // ---------------- CONSTANTS ----------------
    localparam MAX_SAMPLES = 24000;
    localparam ADDR_W = $clog2(MAX_SAMPLES);

    localparam MIN_DELAY_MS = 50;
    localparam MAX_DELAY_MS = 500;
    
    localparam MIN_DELAY_SAMPLES = (MIN_DELAY_MS * SAMPLE_RATE) / 1000;
    localparam MAX_DELAY_SAMPLES_PARAM = (MAX_DELAY_MS * SAMPLE_RATE) / 1000;
    localparam DELAY_RANGE = MAX_DELAY_SAMPLES_PARAM - MIN_DELAY_SAMPLES;  // 21600 

    // ---------------- INTERNAL SIGNALS ----------------

    logic [ADDR_W-1:0] target_delay;
    logic signed [DATA_W-1:0] delayed[1:0];
    logic signed [DATA_W-1:0] fb_in[1:0];
    logic signed [31:0] fb_scaled[1:0];
    
    logic [31:0] delay_range;
    logic [23:0] scaled_delay;

    logic signed [31:0] wet_signal[1:0];
    logic signed [31:0] dry_signal[1:0];
    logic signed [31:0] mixed[1:0];
    logic signed [8:0] dry_gain;

    // ---------------- DELAY LINE INSTANTIATION ----------------

    delay_line #(
        .DATA_W(DATA_W), 
        .MAX_DELAY_SAMPLES(MAX_SAMPLES),
        .ADDR_W(ADDR_W)
    ) unit_L (
        .clk(clk),
        .reset_n(reset_n),
        .sample_en(sample_en),
        .data_in(fb_in[0]),
        .data_out(delayed[0]),
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
        .data_in(fb_in[1]),
        .data_out(delayed[1]),
        .delay_samples(target_delay)
    );

    // ---------------- DELAY CALCULATION ----------------

    logic [ADDR_W-1:0] knob_delay;

    always_comb begin
        // Knob path (unchanged)
        scaled_delay = fx_time * DELAY_RANGE[14:0];
        knob_delay   = MIN_DELAY_SAMPLES[ADDR_W-1:0] + scaled_delay[23:8];
        if (knob_delay > MAX_SAMPLES[ADDR_W-1:0])
            knob_delay = MAX_SAMPLES[ADDR_W-1:0];

        // Mux: tap overrides the knob when tap_active is asserted
        target_delay = tap_active ? tap_samples : knob_delay;
    end

    // Feedback and Mix Calculations
    always_comb begin
        dry_gain = 9'sd255 - $signed({1'b0, fx_mix});
        
        for (int i = 0; i < 2; i++) begin
            // Feedback calculation, to a max of 0.875 to prevent runaway (224/256)
            fb_scaled[i] = ($signed(delayed[i]) * $signed({1'b0, fx_feedback}) * 224) >>> 16;
            fb_in[i] = sat16($signed(audio_in[i]) + fb_scaled[i]);
            
            // Mix dry and wet: dry + (wet - dry) * mix
            wet_signal[i] = $signed(delayed[i]);
            dry_signal[i] = $signed(audio_in[i]);
            mixed[i] = dry_signal[i] + 
                      (((wet_signal[i] - dry_signal[i]) * 
                      $signed({1'b0, fx_mix})) >>> 8);
        end
    end

    // -------------------- OUTPUT -------------------------
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            for (int i = 0; i < 2; i++) begin
                audio_out[i] <= sat16(mixed[i]);
            end
        end
    end

endmodule
