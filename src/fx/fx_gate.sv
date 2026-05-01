/*
 * fx_gate.sv
 *
 * Stereo noise gate with soft-knee and per-parameter attack/release slew.
 *
 * The gate is driven from a side-chain derived from the absolute value of
 * channel 0.  When the signal is above the upper knee edge the gate is
 * fully open (unity gain); below the lower edge it clamps to the depth
 * floor; in the transition zone it interpolates linearly.
 *
 * A registered gain_target stage breaks the otherwise critical path:
 *   params → threshold_scaled → knee edges → gate_open/closed → gain_target
 * into two shorter stages at the cost of 1 sample (~21 µs) of gate
 * response latency, which is inaudible.
 *
 * Parameter mapping  (all 8-bit, 0–255)
 * --------------------------------------
 *   fx_threshold — noise floor level (scales to full 16-bit range)
 *   fx_attack    — gate open speed  (0 = instant, 255 = slowest)
 *   fx_release   — gate close speed (0 = instant, 255 = slowest)
 *   fx_knee      — soft-knee half-width  (0 = hard switch)
 *   fx_depth     — gain floor when closed  (0 = full mute, 255 = unity)
 *
 * Latency: 0 samples on the audio path
 *   audio_out is combinational (assign) from audio_in × gain.  The
 *   "1 sample" you'll see referenced elsewhere is the gain-control
 *   response delay (gain_target register settles 1 sample after a
 *   threshold crossing) plus envelope slew — those affect *when* the
 *   gate opens/closes, not how long an audio sample takes to traverse.
 *
 * Ports
 * -----
 *   audio_in  — stereo signed 16-bit input;  channel 0 drives the side-chain
 *   audio_out — gain-applied stereo output (combinational from generate block)
 *   sample_en — single-cycle sample strobe
 */

module fx_gate #(
    parameter DATA_W            = 16,
    parameter PARAM_W           = 8,
    parameter SILENCE_THRESHOLD = 16'd128
)(
    input  logic                   clk,
    input  logic                   reset_n,
    input  logic [1:0][DATA_W-1:0] audio_in,
    output logic [1:0][DATA_W-1:0] audio_out,
    input  logic [PARAM_W-1:0]     fx_threshold,
    input  logic [PARAM_W-1:0]     fx_attack,
    input  logic [PARAM_W-1:0]     fx_release,
    input  logic [PARAM_W-1:0]     fx_knee,
    input  logic [PARAM_W-1:0]     fx_depth,
    input  logic                   sample_en
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // 1. Side-Chain: Absolute Value of Channel 0
    // ----------------------------------------------------------------

    logic signed [DATA_W-1:0] in_signed;
    logic        [DATA_W-1:0] abs_in;

    assign in_signed = $signed(audio_in[0]);
    assign abs_in    = in_signed[DATA_W-1] ? DATA_W'(unsigned'(-in_signed))
                                           : DATA_W'(unsigned'( in_signed));

    // ----------------------------------------------------------------
    // 2. Threshold, Knee Edges, and Gain Floor
    // ----------------------------------------------------------------

    logic [DATA_W-1:0] threshold_scaled;  // threshold mapped to 16-bit range
    logic [DATA_W-1:0] knee_half;          // half the knee width
    logic [DATA_W:0]   upper_tmp;
    logic [DATA_W-1:0] upper_edge;         // upper knee boundary (saturated)
    logic [DATA_W-1:0] lower_edge;         // lower knee boundary (clamped to 0)
    logic [15:0]       gain_min;           // gain floor at full attenuation

    assign threshold_scaled = {fx_threshold, {(DATA_W-PARAM_W){1'b0}}};
    assign knee_half        = {1'b0, fx_knee, {(DATA_W-PARAM_W-1){1'b0}}};
    assign upper_tmp        = {1'b0, threshold_scaled} + {1'b0, knee_half};
    assign upper_edge       = upper_tmp[DATA_W] ? {DATA_W{1'b1}} : upper_tmp[DATA_W-1:0];
    assign lower_edge       = (threshold_scaled > knee_half)
                              ? (threshold_scaled - knee_half) : '0;
    assign gain_min         = {fx_depth, fx_depth};

    // ----------------------------------------------------------------
    // 3. Zone Detection
    // ----------------------------------------------------------------

    logic gate_open;    // abs_in above upper knee — full gain
    logic gate_closed;  // abs_in below lower knee — gain floor

    assign gate_open   = (abs_in >= upper_edge);
    assign gate_closed = (abs_in <= lower_edge);

    // ----------------------------------------------------------------
    // 4. Soft-Knee Interpolation
    //
    // Computes the position of abs_in within the knee zone as an 8-bit
    // fraction, then interpolates between gain_min and full gain.
    // A leading-bit scan (casez) normalises both numerator and denominator
    // before the divide to keep the result in 8 bits.
    // ----------------------------------------------------------------

    logic [DATA_W-1:0] knee_pos;    // abs_in offset from lower edge
    logic [DATA_W-1:0] knee_width;  // total knee span
    logic [7:0]        knee_frac;   // normalised fraction [0, 0xFF]

    assign knee_pos   = abs_in     - lower_edge;
    assign knee_width = upper_edge - lower_edge;

    // Leading-bit scan: find the shift that brings knee_width into [128,255]
    logic [3:0] kw_shift;
    always_comb begin
        casez (knee_width[DATA_W-1:8])
            8'b1???????: kw_shift = 4'd8;
            8'b01??????: kw_shift = 4'd7;
            8'b001?????: kw_shift = 4'd6;
            8'b0001????: kw_shift = 4'd5;
            8'b00001???: kw_shift = 4'd4;
            8'b000001??: kw_shift = 4'd3;
            8'b0000001?: kw_shift = 4'd2;
            8'b00000001: kw_shift = 4'd1;
            default:     kw_shift = 4'd0;
        endcase
    end

    logic [DATA_W-1:0] kw_norm;   // normalised knee width
    logic [DATA_W-1:0] kp_norm;   // normalised knee position
    logic [15:0]       frac_num;

    assign kw_norm   = knee_width >> kw_shift;
    assign kp_norm   = knee_pos   >> kw_shift;
    assign frac_num  = kp_norm[7:0] * 8'hFF;
    assign knee_frac = (kw_norm == '0)      ? 8'hFF :
                       (kp_norm >= kw_norm) ? 8'hFF :
                                              frac_num[15:8];

    logic [15:0] gain_range;
    logic [23:0] knee_interp;
    logic [15:0] knee_target;

    assign gain_range  = 16'hFFFF - gain_min;
    assign knee_interp = gain_range * {8'b0, knee_frac};
    assign knee_target = gain_min + knee_interp[23:8];

    // ----------------------------------------------------------------
    // 5. Gain Target Mux  (combinational)
    // ----------------------------------------------------------------

    logic [15:0] gain_target;

    always_comb begin
        if      (gate_open)   gain_target = 16'hFFFF;
        else if (gate_closed) gain_target = gain_min;
        else                  gain_target = knee_target;
    end

    // ----------------------------------------------------------------
    // 6. Registered Gain Target  (timing fix)
    //
    // Breaks the long path:
    //   params → threshold_scaled → edges → gate_open/closed → gain_target → gain FF
    // into two shorter stages, trading 1 sample of response latency (~21 µs).
    // ----------------------------------------------------------------

    logic [15:0] gain_target_r;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) gain_target_r <= 16'hFFFF;
        else if (sample_en) gain_target_r <= gain_target;
    end

    // ----------------------------------------------------------------
    // 7. Envelope Gain Register  (slews toward gain_target_r)
    //
    // attack_step and release_step map the 8-bit params to a step size
    // where 0 → 256 (instant) and 255 → 1 (slowest).
    //
    // Note: linear amplitude ramping at low gain values is perceptually
    // "rough" because a constant LSB step becomes a large dB jump near
    // zero — this is unavoidable without an IIR-style approach.  An IIR
    // tracker is incompatible here because gain_target_r already moves
    // at audio rate inside the knee zone (knee_target is a function of
    // the current sample's abs_in), and a fast IIR ends up amplitude-
    // modulating the audio with itself, producing a constant crackle.
    // The linear slew effectively low-passes those fluctuations because
    // its rate is bounded.  For natural-sounding decay use higher
    // fx_release values (smaller step → longer tail).
    // ----------------------------------------------------------------

    logic [15:0] gain;
    logic [8:0]  attack_step;
    logic [8:0]  release_step;

    assign attack_step  = 9'd256 - {1'b0, fx_attack};
    assign release_step = 9'd256 - {1'b0, fx_release};

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            gain <= 16'hFFFF;
        end else if (sample_en) begin
            if (gain < gain_target_r) begin
                if ((gain_target_r - gain) <= {7'b0, attack_step})
                    gain <= gain_target_r;
                else
                    gain <= gain + {7'b0, attack_step};
            end else if (gain > gain_target_r) begin
                if ((gain - gain_target_r) <= {7'b0, release_step})
                    gain <= gain_target_r;
                else
                    gain <= gain - {7'b0, release_step};
            end
        end
    end

    // ----------------------------------------------------------------
    // 8. Apply Gain to Both Channels  (Q0.16 multiply)
    // ----------------------------------------------------------------

    generate
        genvar ch;
        for (ch = 0; ch < 2; ch++) begin : APPLY_GAIN
            logic signed [DATA_W-1:0]  ch_in;
            logic signed [DATA_W+16:0] ch_product;

            assign ch_in        = $signed(audio_in[ch]);
            assign ch_product   = ch_in * $signed({1'b0, gain});
            assign audio_out[ch] = ch_product[DATA_W+16-1 : 16];
        end
    endgenerate

endmodule