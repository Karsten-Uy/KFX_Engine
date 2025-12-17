
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


    // -----------------------------
    // PEAK LEVEL DETECTOR (Stereo-linked)
    // -----------------------------
    logic [15:0] abs_l, abs_r;
    logic [15:0] peak_level;

    always_comb begin
        abs_l = audio_in[0][15] ? -audio_in[0] : audio_in[0];
        abs_r = audio_in[1][15] ? -audio_in[1] : audio_in[1];
        peak_level = (abs_l > abs_r) ? abs_l : abs_r;  // Max of stereo
    end

    // -----------------------------
    // ENVELOPE FOLLOWER
    // -----------------------------
    logic [15:0] envelope;
    logic [15:0] att_step, rel_step;

    always_comb begin
        att_step = 16'd512 + ({8'd0, fx_attack} << 4);
        rel_step = 16'd16  + ({8'd0, fx_release} << 2);
    end

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
    
    logic [15:0] threshold_val;
    logic gate_open;
    logic [15:0] open_threshold, close_threshold;

    assign threshold_val = ({8'd0, fx_threshold} * 16'd96);  // 0-255 -> 0-24480
    
    assign open_threshold = threshold_val;
    assign close_threshold = (threshold_val >>> 1); // 50% hysteresis
    
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

    // ---------------- GATE GAIN SMOOTHING ----------------
    
    logic [15:0] gate_gain;
    
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

    // assign gate_gain = UNITY_Q15;

    // -----------------------------
    // APPLY GAIN TO DELAYED AUDIO
    // -----------------------------
    logic signed [31:0] prod_l, prod_r;

    always_comb begin
        // Multiply delayed audio by gain (both Q15)
        prod_l = $signed(audio_in[0]) * $signed({1'b0,gate_gain});
        prod_r = $signed(audio_in[1]) * $signed({1'b0,gate_gain});

    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            // Shift down by 15 bits and saturate
            audio_out[0] <= sat16(prod_l >>> 15);
            audio_out[1] <= sat16(prod_r >>> 15);

            // audio_out = audio_in;
        end
    end



    
    // always_ff @(posedge clk) begin
    //     if (!reset_n) begin
    //         audio_out <= '0;
    //     end else if (sample_en) begin
    //         audio_out = audio_in;
    //     end
    // end

endmodule