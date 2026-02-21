
/*
    Gate with Soft-Knee Dead Band, Exponential Smoothing, and Zero-Clamp.

    Root cause of the "delay artifact" in previous versions:
      target_gain_c was purely combinational.  As the envelope jittered
      around close_r on the decay tail, target alternated between floor_r
      and an interpolated value on adjacent samples.  The release smoother
      turned this rapid toggling into a low-frequency oscillation — audible
      as a repeating "delay"-like effect whose rate was set by rel_shift_c
      (hence "adjusting release changes the speed of the delay").

    Fix: hysteresis latch (gate_open_r FF in Stage 2).
      - Gate OPENS  only when envelope >= open_r
      - Gate CLOSES only when envelope <= close_r
      - HOLDS state in the dead band — no toggling possible
      Smooth fade-in/out is handled by att/rel exponential smoother
      (stages 3/4), which was always the right place for it.

    Pipeline (5 stages):

        Stage P1  | fx_threshold * 96  → thresh_r          [1 multiply]
                  | fx_knee, fx_depth  → knee_r, depth_r   [FFs only]
                  |
        Stage P2a | thresh_r * knee_r >> 8  → knee_width_r [1 DSP multiply]
                  | thresh_r                → open_r2
                  | depth_r               → depth_r2
                  |
        Stage P2b | open_r2 - knee_width_r  → close_r      [adder only]
                  | depth_r2               → floor_r        [mux only]
                  | open_r2               → open_r          [wire]
                  | NO DIVIDE, NO priority encoder
                  |
        Stage 1   | Envelope follower: audio_in → envelope
                  |
        Stage 2   | Hysteresis latch: envelope + open_r/close_r → gate_open_r
                  | target_gain_c = gate_open_r ? UNITY_Q15 : floor_r
                  |
        Stage 3   | Delta: barrel shifter isolated from gate_gain feedback
                  |
        Stage 4   | Gain update: adder only on gate_gain path
                  |
        Output    | audio_in_reg * gate_gain_reg → audio_out  [1 DSP multiply]
*/

module fx_gate #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                      clk,
    input  logic                      reset_n,
    input  logic [1:0][DATA_W-1:0]    audio_in,
    output logic [1:0][DATA_W-1:0]    audio_out,
    input  logic [PARAM_W-1:0]        fx_threshold,
    input  logic [PARAM_W-1:0]        fx_attack,
    input  logic [PARAM_W-1:0]        fx_release,
    input  logic [PARAM_W-1:0]        fx_knee,
    input  logic [PARAM_W-1:0]        fx_depth,
    input  logic                      sample_en
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // STAGE P1 — one multiply: fx_threshold * 96
    // fx_knee and fx_depth are just registered (no computation).
    // ----------------------------------------------------------------

    logic [15:0] thresh_r;
    logic [7:0]  knee_r;
    logic [7:0]  depth_r;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            thresh_r <= 16'd0;
            knee_r   <= 8'd0;
            depth_r  <= 8'd0;
        end else begin
            thresh_r <= {8'd0, fx_threshold} * 16'd96;
            knee_r   <= fx_knee;
            depth_r  <= fx_depth;
        end
    end

    // ----------------------------------------------------------------
    // STAGE P2a — one multiply: knee_width = thresh * knee >> 8
    //
    // synthesis multstyle = "dsp"
    // Both inputs are FFs (from P1) and output is a FF, so Quartus
    // can use the DSP block's internal input and output registers —
    // fixes DSP Register Packing warning on this multiply.
    // ----------------------------------------------------------------

    logic [15:0] knee_width_r;
    logic [15:0] open_r2;
    logic [7:0]  depth_r2;

    // synthesis multstyle = "dsp"
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            knee_width_r <= 16'd0;
            open_r2      <= 16'd0;
            depth_r2     <= 8'd0;
        end else begin
            knee_width_r <= (32'(thresh_r) * {8'd0, knee_r}) >> 8;
            open_r2      <= thresh_r;
            depth_r2     <= depth_r;
        end
    end

    // ----------------------------------------------------------------
    // STAGE P2b — close_r and floor_r only. NO DIVISION.
    //
    // MIN_KNEE is enforced so close_r is ALWAYS strictly below open_r,
    // guaranteeing a real dead band even when fx_knee = 0.
    //
    // Without this: knee_width_r=0 → close_r=open_r → dead band is
    // EMPTY. Every sample the envelope is either >= open_r (open) or
    // <= close_r=open_r (close) with no stable middle ground. Gate
    // chatters on every sample near the threshold → amplitude
    // modulation at audio rate → distortion + repeating artifact.
    // ----------------------------------------------------------------

    localparam logic [15:0] MIN_KNEE = 16'd512;  // ~2% of full scale

    logic [15:0] open_r;
    logic [15:0] close_r;
    logic [15:0] floor_r;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            open_r  <= 16'd0;
            close_r <= 16'd0;
            floor_r <= 16'd0;
        end else begin
            automatic logic [15:0] kw;
            kw      = (knee_width_r < MIN_KNEE) ? MIN_KNEE : knee_width_r;
            open_r  <= open_r2;
            close_r <= (open_r2 > kw) ? open_r2 - kw : 16'd0;
            // depth=0   → floor_r = 0        (full mute when gate closed)
            // depth=255 → floor_r ≈ UNITY_Q15 (gate barely attenuates)
            floor_r <= {1'b0, depth_r2, 7'b0};
        end
    end

    // ----------------------------------------------------------------
    // STAGE 1 — ENVELOPE FOLLOWER
    // ----------------------------------------------------------------

    logic [15:0] abs_l, abs_r, peak_level, envelope;

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

    // ----------------------------------------------------------------
    // STAGE 2 — GATE STATE (hysteresis latch) + target_gain_r
    //
    // gate_open_r: latching state with a dead band between close_r
    // and open_r where no state change occurs.
    //
    //   envelope >= open_r  → gate_open_r = 1  (open)
    //   envelope <= close_r → gate_open_r = 0  (closed)
    //   close_r < env < open_r → hold state    (dead band — NO TOGGLE)
    //
    // gate_settled: prevents re-triggering while gate_gain is still
    // transitioning. Without this, as the signal decays:
    //   1. envelope drops below close_r → gate closes
    //   2. gate_gain starts ramping toward floor_r (still non-zero)
    //   3. signal still audible → envelope rises above open_r
    //   4. gate re-opens mid-ramp → gain reverses direction
    //   5. repeat → buzz at the transition
    //
    // gate_settled goes low immediately when state changes, and only
    // goes high again when gate_gain has reached within a small
    // threshold of its target (floor_r or UNITY_Q15). State changes
    // (open/close) are only allowed when gate_settled is high.
    // ----------------------------------------------------------------

    logic        gate_open_r;
    logic        gate_settled;
    logic [15:0] target_gain_c;
    logic [15:0] target_gain_r;

    // gate_settled: true when gate_gain has converged to its target
    always_comb begin
        if (gate_open_r)
            gate_settled = (gate_gain >= UNITY_Q15 - 16'd8);
        else
            gate_settled = (gate_gain <= floor_r + 16'd8);
    end

    always_ff @(posedge clk) begin
        if (!reset_n) gate_open_r <= 1'b0;
        else if (sample_en && gate_settled) begin
            // Only allow state changes once gain has settled —
            // prevents re-triggering during att/rel transitions
            if      (open_r == 16'd0)     gate_open_r <= 1'b1;
            else if (envelope >= open_r)  gate_open_r <= 1'b1;
            else if (envelope <= close_r) gate_open_r <= 1'b0;
        end
    end

    always_comb begin
        target_gain_c = gate_open_r ? UNITY_Q15 : floor_r;
    end

    always_ff @(posedge clk) begin
        if (!reset_n) target_gain_r <= 16'd0;
        else if (sample_en) target_gain_r <= target_gain_c;
    end

    // ----------------------------------------------------------------
    // STAGE 3 — DELTA COMPUTATION
    // Barrel shifter isolated from gate_gain feedback path.
    // ----------------------------------------------------------------

    logic [4:0]  att_shift_c, rel_shift_c;
    logic [15:0] att_delta_c, rel_delta_c;
    logic [15:0] att_delta_r, rel_delta_r;
    logic [15:0] gate_gain;

    assign att_shift_c = (5'd3 + {2'b0, fx_attack[7:5]}  > 5'd14) ? 5'd14
                                                                    : 5'd3 + {2'b0, fx_attack[7:5]};
    assign rel_shift_c = (5'd5 + {1'b0, fx_release[7:4]} > 5'd14) ? 5'd14
                                                                    : 5'd5 + {1'b0, fx_release[7:4]};

    always_comb begin
        att_delta_c = 16'd0;
        rel_delta_c = 16'd0;
        if (gate_gain < target_gain_r) begin
            if ((target_gain_r - gate_gain) < 16'd8)
                att_delta_c = target_gain_r - gate_gain;
            else begin
                automatic logic [15:0] d = (target_gain_r - gate_gain) >> att_shift_c;
                att_delta_c = (d == 16'd0) ? 16'd1 : d;
            end
        end else if (gate_gain > target_gain_r) begin
            if ((gate_gain - target_gain_r) < 16'd8)
                rel_delta_c = gate_gain - target_gain_r;
            else begin
                automatic logic [15:0] d = (gate_gain - target_gain_r) >> rel_shift_c;
                rel_delta_c = (d == 16'd0) ? 16'd1 : d;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            att_delta_r <= 16'd0;
            rel_delta_r <= 16'd0;
        end else if (sample_en) begin
            att_delta_r <= att_delta_c;
            rel_delta_r <= rel_delta_c;
        end
    end

    // ----------------------------------------------------------------
    // STAGE 4 — GATE GAIN UPDATE — adder only
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) gate_gain <= 16'd0;
        else if (sample_en) begin
            if      (att_delta_r != 16'd0) gate_gain <= gate_gain + att_delta_r;
            else if (rel_delta_r != 16'd0) gate_gain <= gate_gain - rel_delta_r;
        end
    end

    // ----------------------------------------------------------------
    // OUTPUT MULTIPLY
    //
    // Pre-register inputs so the DSP block uses its internal input FFs,
    // fixing the "DSP Register Packing" warning.
    // synthesis multstyle = "dsp"
    // ----------------------------------------------------------------

    logic [DATA_W-1:0] ain_l_r, ain_r_r;
    logic [15:0]       gg_r;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            ain_l_r <= '0;
            ain_r_r <= '0;
            gg_r    <= '0;
        end else if (sample_en) begin
            ain_l_r <= audio_in[0];
            ain_r_r <= audio_in[1];
            gg_r    <= gate_gain;
        end
    end

    logic signed [31:0] prod_l, prod_r;

    // synthesis multstyle = "dsp"
    always_comb begin
        prod_l = $signed(ain_l_r) * $signed({1'b0, gg_r});
        prod_r = $signed(ain_r_r) * $signed({1'b0, gg_r});
    end

    always_ff @(posedge clk) begin
        if (!reset_n) audio_out <= '0;
        else if (sample_en) begin
            audio_out[0] <= sat16(prod_l >>> 15);
            audio_out[1] <= sat16(prod_r >>> 15);
        end
    end

endmodule