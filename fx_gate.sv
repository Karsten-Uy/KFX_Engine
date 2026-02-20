/*
    Gate with Soft-Knee, Exponential Smoothing, and Zero-Clamp.
    
    Architecture:
    1. Envelope Follower tracks the peak of the signal.
    2. Transfer Curve determines Target Gain (with Soft-Knee interpolation).
    3. Exponential Smoother moves Gate Gain toward Target Gain.
    4. Snap-to-Target logic ensures absolute silence when fx_depth = 255.

    Fixes (2026-02-20):
    
    1. Stuck-at-nonzero when depth = 255:
       The exponential decay step ((gate_gain - target_gain) >> rel_shift)
       rounds down to zero when gate_gain is small but still outside the
       snap threshold (< 8). Subtracting zero makes no progress and
       gate_gain gets stuck above 0 permanently — signal leaks through a
       "fully muted" gate. Fixed by guaranteeing a minimum step of 1
       whenever the shift result is zero, so gate_gain always converges.

    2. rel_shift overflow:
       att_shift and rel_shift were 4-bit but rel_shift could reach
       5 + 15 = 20, which wraps to 4 in 4 bits — high fx_release values
       produced a fast release (opposite of intent). Both widened to 5 bits.

    3. Shift clamped to 14:
       Shifting a 16-bit value right by >= 16 always gives 0, which
       re-triggers the stuck-at-nonzero problem for high param values.
       Both shifts are clamped to a maximum of 14.
*/

module fx_gate #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                      clk,
    input  logic                      reset_n,
    input  logic [1:0][DATA_W-1:0]    audio_in,
    output logic [1:0][DATA_W-1:0]    audio_out,
    input  logic [PARAM_W-1:0]        fx_threshold, // Center of transition
    input  logic [PARAM_W-1:0]        fx_attack,    // Attack speed
    input  logic [PARAM_W-1:0]        fx_release,   // Release speed
    input  logic [PARAM_W-1:0]        fx_knee,      // Knee softness
    input  logic [PARAM_W-1:0]        fx_depth,     // 255 = full mute
    input  logic                      sample_en
);

    import lab_pkg::*;

    // ---------------- INTERNAL SIGNALS ----------------
    logic [15:0] abs_l, abs_r, peak_level, envelope;
    logic [15:0] threshold_val, open_threshold, close_threshold;
    logic [15:0] knee_width, floor_gain;
    logic [15:0] target_gain, gate_gain;
    logic [4:0]  att_shift, rel_shift;         // 5-bit — fits up to 20 before clamp
    logic [4:0]  att_shift_c, rel_shift_c;     // clamped to max 14
    logic [15:0] att_delta, rel_delta;
    logic signed [31:0] prod_l, prod_r;

    // ---------------- ENVELOPE FOLLOWER ----------------
    always_comb begin
        abs_l      = audio_in[0][15] ? -audio_in[0] : audio_in[0];
        abs_r      = audio_in[1][15] ? -audio_in[1] : audio_in[1];
        peak_level = (abs_l > abs_r) ? abs_l : abs_r;
    end

    always_ff @(posedge clk) begin
        if (!reset_n) envelope <= 16'd0;
        else if (sample_en) begin
            if (peak_level > envelope)
                envelope <= envelope + ((peak_level - envelope) >> 4);
            else
                envelope <= envelope - ((envelope - peak_level) >> 8);
        end
    end

    // ---------------- TRANSFER CURVE (TARGET GAIN) ----------------
    assign threshold_val   = {8'd0, fx_threshold} * 16'd96;
    assign open_threshold  = threshold_val;

    // Guarantee floor_gain == 0 when fx_depth == 255 so fully-closed gate
    // passes absolutely no signal regardless of rounding elsewhere
    assign floor_gain      = (fx_depth == 8'd255)
                               ? 16'd0
                               : {1'b0, (8'd255 - fx_depth), 7'b0};

    assign knee_width      = (32'(open_threshold) * {8'd0, fx_knee}) >> 8;
    assign close_threshold = (open_threshold > knee_width)
                               ? open_threshold - knee_width
                               : 16'd0;

    always_comb begin
        if (envelope >= open_threshold || open_threshold == 0) begin
            target_gain = UNITY_Q15;
        end else if (envelope <= close_threshold || knee_width == 0) begin
            target_gain = floor_gain;
        end else begin
            // Linear interpolation inside the knee region
            automatic logic [31:0] env_above_close = 32'(envelope - close_threshold);
            automatic logic [31:0] knee_range      = 32'(UNITY_Q15 - floor_gain);
            automatic logic [31:0] interp          = (env_above_close * knee_range)
                                                     / 32'(knee_width);
            target_gain = floor_gain + interp[15:0];
        end
    end

    // ---------------- SHIFT CALCULATION ----------------
    //
    // Widened to 5 bits to prevent wrap-around.
    // rel_shift = 5 + fx_release[7:4]: max = 5+15 = 20 before clamp.
    // att_shift = 3 + fx_attack[7:5]:  max = 3+7  = 10 before clamp.
    //
    // Clamped to 14 — shifting a 16-bit value right by >= 15 always
    // gives 0 or 1, which causes the minimum-step path to fire every
    // sample and produces a constant 1-LSB-per-sample ramp instead of
    // exponential decay. Capping at 14 keeps the slowest decay audibly
    // smooth while guaranteeing the shift never zeroes the step.

    assign att_shift = 5'd3 + {2'b0, fx_attack[7:5]};
    assign rel_shift = 5'd5 + {1'b0, fx_release[7:4]};

    assign att_shift_c = (att_shift > 5'd14) ? 5'd14 : att_shift;
    assign rel_shift_c = (rel_shift > 5'd14) ? 5'd14 : rel_shift;

    // ---------------- GAIN SMOOTHING ----------------
    //
    // Exponential smoothing toward target_gain each sample.
    //
    // Minimum step of 1:
    //   When the shift result rounds down to zero (gate_gain is small
    //   but still outside the snap threshold), subtracting/adding zero
    //   makes no progress. gate_gain gets permanently stuck above
    //   target_gain — signal leaks through a "fully muted" gate.
    //   Forcing a minimum delta of 1 guarantees convergence.
    //
    // Snap threshold of 8:
    //   Avoids the infinite-approach problem near the target where the
    //   exponential step would never reach exactly target_gain.

    always_comb begin
        att_delta = (target_gain - gate_gain) >> att_shift_c;
        rel_delta = (gate_gain - target_gain) >> rel_shift_c;
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            gate_gain <= 16'd0;
        end else if (sample_en) begin
            if (gate_gain < target_gain) begin
                if ((target_gain - gate_gain) < 16'd8)
                    gate_gain <= target_gain;
                else
                    gate_gain <= gate_gain + (att_delta == 16'd0 ? 16'd1 : att_delta);
            end else if (gate_gain > target_gain) begin
                if ((gate_gain - target_gain) < 16'd8)
                    gate_gain <= target_gain;
                else
                    gate_gain <= gate_gain - (rel_delta == 16'd0 ? 16'd1 : rel_delta);
            end
        end
    end

    // ---------------- OUTPUT APPLICATION ----------------
    always_comb begin
        prod_l = $signed(audio_in[0]) * $signed({1'b0, gate_gain});
        prod_r = $signed(audio_in[1]) * $signed({1'b0, gate_gain});
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            audio_out[0] <= sat16(prod_l >>> 15);
            audio_out[1] <= sat16(prod_r >>> 15);
        end
    end

endmodule