/*

    Gate with Peak Envelope Smoothing that allows signals that exceed the 
    threshold through while muting signals that are below the threshold.

    Parameters:
        fx_threshold - Threshold for signal that is scaled to have a range
                       of 0-24480 in relation to audio_in
        fx_attack    - Time it takes for the gate to open. Higher value means
                       it takes longer to open once the envelope exceeds the 
                       threshold
        fx_release   - Time it takes for the gate to close. Higher value means
                       it takes longer to close once the envelope dips below the 
                       threshold 

 */


module fx_gate #(
    parameter DATA_W  = 16,
    PARAM_W = 8
)(
    input  logic                      clk,
    input  logic                      reset_n,
    input  logic [1:0][DATA_W-1:0]    audio_in,   // Stereo input
    output logic [1:0][DATA_W-1:0]    audio_out,  // Stereo output
    input  logic [PARAM_W-1:0]        fx_threshold,  // Gate threshold
    input  logic [PARAM_W-1:0]        fx_attack,     // Attack time
    input  logic [PARAM_W-1:0]        fx_release,     // Release time
    input  logic                      sample_en
);
    
    // ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;

    // ---------------- INTERNAL SIGNALS ----------------

    // Peak Detector
    logic [15:0] abs_l, abs_r;
    logic [15:0] peak_level;

    // Envelope Follower
    logic [15:0] envelope;
    logic [15:0] att_step, rel_step;

    // Gate Decision
    logic [15:0] threshold_val;
    logic gate_open;
    logic [15:0] open_threshold, close_threshold;

    // Gate Gain
    logic [15:0] gate_gain;
    logic signed [31:0] prod_l, prod_r;

    // ---------------- ENVELOPE ----------------    

    // Peak Level Detector (Stereo-linked)
    always_comb begin
        abs_l = audio_in[0][15] ? -audio_in[0] : audio_in[0];
        abs_r = audio_in[1][15] ? -audio_in[1] : audio_in[1];
        peak_level = (abs_l > abs_r) ? abs_l : abs_r;  // Max of stereo
    end

    // Envelope Follower
    always_comb begin
        att_step = 16'd512 + ({8'd0, fx_attack} << 4);
        rel_step = 16'd16  + ({8'd0, fx_release} << 2);
    end

    // Envelope FF
    always_ff @(posedge clk) begin
        if (!reset_n)
            envelope <= 16'd0;
        else if (sample_en) begin
            if (peak_level > envelope)
                envelope <= (peak_level - envelope > att_step) ? envelope + att_step : peak_level;
            else if (peak_level < envelope)
                envelope <= (envelope - peak_level > rel_step) ? envelope - rel_step : peak_level;
        end
    end

    // ---------------- GATE DECISION ----------------

    // Threshold Calculation
    assign threshold_val = ({8'd0, fx_threshold} * 16'd96);  // 0-255 -> 0-24480    
    assign open_threshold = threshold_val;
    assign close_threshold = (threshold_val >>> 1); // 50% hysteresis
    
    // Gate Decision FF
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            gate_open <= 1'b0;
        end else if (sample_en) begin
            if (gate_open) begin
                if (envelope < close_threshold)
                    gate_open <= 1'b0;
            end else begin
                if (envelope > open_threshold)
                    gate_open <= 1'b1;
            end
        end
    end

    // ---------------- GATE GAIN APPLICATION ----------------    
    
    // Gain Smoothing FF
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            gate_gain <= MIN_GAIN;
        end else if (sample_en) begin
            if (gate_open) begin
                // Ramp up
                if (gate_gain < (UNITY_Q15 - att_step)) begin
                    gate_gain <= gate_gain + att_step;
                end else begin
                    gate_gain <= UNITY_Q15;
                end
            end else begin
                // Ramp down
                if (gate_gain > (MIN_GAIN + rel_step)) begin
                    gate_gain <= gate_gain - rel_step;
                end else begin
                    gate_gain <= MIN_GAIN;
                end
            end
        end
    end

    // Gain Application
    always_comb begin
        prod_l = $signed(audio_in[0]) * $signed({1'b0,gate_gain});
        prod_r = $signed(audio_in[1]) * $signed({1'b0,gate_gain});

    end

    // Audio Out FF
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            // Right Shift 15 to resolve gain multiplication
            audio_out[0] <= sat16(prod_l >>> 15);
            audio_out[1] <= sat16(prod_r >>> 15);
        end
    end

endmodule