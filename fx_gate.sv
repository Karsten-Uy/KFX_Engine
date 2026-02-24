/*
    fx_gate.sv — Noise Gate FX Module

    Timing fix (rev 2)
    ------------------
    Critical path was:
      params[1][0] → threshold_scaled → lower/upper_edge
                   → gate_open/closed → gain_target → gain FF
    Slack: -0.681 ns.

    Fix: register gain_target into gain_target_r on every sample_en tick.
    The gain slew FF now reads gain_target_r instead of gain_target,
    breaking the path into two shorter pipeline stages.
    Cost: 1 sample of gate-response latency (~21 µs @ 48 kHz) — inaudible.

    Parameter mapping (all 8-bit, 0–255):
      fx_threshold : noise floor level
      fx_attack    : how fast gate OPENS  (0 = instant, 255 = slowest)
      fx_release   : how fast gate CLOSES (0 = instant, 255 = slowest)
      fx_knee      : soft-knee half-width (0 = hard switch)
      fx_depth     : attenuation floor when closed (0 = mute, 255 = unity)
*/

module fx_gate #(
    parameter DATA_W            = 16,
    parameter PARAM_W           = 8,
    parameter SILENCE_THRESHOLD = 16'd128
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

    // -----------------------------------------------------------------------
    // 1.  Side-chain: absolute value of channel 0
    // -----------------------------------------------------------------------
    logic signed [DATA_W-1:0]   in_signed;
    logic        [DATA_W-1:0]   abs_in;

    assign in_signed = $signed(audio_in[0]);
    assign abs_in    = in_signed[DATA_W-1]
                       ? DATA_W'(unsigned'(-in_signed))
                       : DATA_W'(unsigned'( in_signed));

    // -----------------------------------------------------------------------
    // 2.  Threshold, knee edges, gain floor
    // -----------------------------------------------------------------------
    logic [DATA_W-1:0]  threshold_scaled;
    logic [DATA_W-1:0]  knee_half;
    logic [DATA_W:0]    upper_tmp;
    logic [DATA_W-1:0]  upper_edge;
    logic [DATA_W-1:0]  lower_edge;
    logic [15:0]        gain_min;

    assign threshold_scaled = { fx_threshold, {(DATA_W-PARAM_W){1'b0}} };
    assign knee_half        = { 1'b0, fx_knee, {(DATA_W-PARAM_W-1){1'b0}} };
    assign upper_tmp        = { 1'b0, threshold_scaled } + { 1'b0, knee_half };
    assign upper_edge       = upper_tmp[DATA_W] ? {DATA_W{1'b1}} : upper_tmp[DATA_W-1:0];
    assign lower_edge       = (threshold_scaled > knee_half)
                              ? (threshold_scaled - knee_half) : '0;
    assign gain_min         = { fx_depth, fx_depth };

    // -----------------------------------------------------------------------
    // 3.  Zone detection
    // -----------------------------------------------------------------------
    logic gate_open;
    logic gate_closed;

    assign gate_open   = (abs_in >= upper_edge);
    assign gate_closed = (abs_in <= lower_edge);

    // -----------------------------------------------------------------------
    // 4.  Soft-knee interpolation
    // -----------------------------------------------------------------------
    logic [DATA_W-1:0]  knee_pos;
    logic [DATA_W-1:0]  knee_width;
    logic [7:0]         knee_frac;

    assign knee_pos   = abs_in     - lower_edge;
    assign knee_width = upper_edge - lower_edge;

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

    logic [DATA_W-1:0] kw_norm;
    logic [DATA_W-1:0] kp_norm;

    assign kw_norm = knee_width >> kw_shift;
    assign kp_norm = knee_pos   >> kw_shift;

    logic [15:0] frac_num;
    assign frac_num  = kp_norm[7:0] * 8'hFF;
    assign knee_frac = (kw_norm == '0)      ? 8'hFF :
                       (kp_norm >= kw_norm) ? 8'hFF :
                                              frac_num[15:8];

    logic [15:0] gain_range;
    logic [23:0] knee_interp;
    logic [15:0] knee_target;

    assign gain_range  = 16'hFFFF - gain_min;
    assign knee_interp = gain_range * { 8'b0, knee_frac };
    assign knee_target = gain_min + knee_interp[23:8];

    // -----------------------------------------------------------------------
    // 5.  Gain target mux (combinational)
    // -----------------------------------------------------------------------
    logic [15:0] gain_target;

    always_comb begin
        if      (gate_open)   gain_target = 16'hFFFF;
        else if (gate_closed) gain_target = gain_min;
        else                  gain_target = knee_target;
    end

    // -----------------------------------------------------------------------
    // 6.  REGISTERED gain_target  ← timing fix
    //
    //     Breaks the long path:
    //       params → threshold_scaled → edges → gate_open/closed
    //             → gain_target → gain
    //     into two stages:
    //       Stage A: params → gain_target      (combinational, ends here)
    //       Stage B: gain_target_r → gain FF   (short registered path)
    // -----------------------------------------------------------------------
    logic [15:0] gain_target_r;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            gain_target_r <= 16'hFFFF;
        else if (sample_en)
            gain_target_r <= gain_target;
    end

    // -----------------------------------------------------------------------
    // 7.  Envelope gain register — slews toward gain_target_r
    // -----------------------------------------------------------------------
    logic [15:0] gain;
    logic [8:0]  attack_step;
    logic [8:0]  release_step;

    assign attack_step  = 9'd256 - { 1'b0, fx_attack  };
    assign release_step = 9'd256 - { 1'b0, fx_release };

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            gain <= 16'hFFFF;
        end else if (sample_en) begin
            if (gain < gain_target_r) begin
                if ((gain_target_r - gain) <= { 7'b0, attack_step })
                    gain <= gain_target_r;
                else
                    gain <= gain + { 7'b0, attack_step };
            end else if (gain > gain_target_r) begin
                if ((gain - gain_target_r) <= { 7'b0, release_step })
                    gain <= gain_target_r;
                else
                    gain <= gain - { 7'b0, release_step };
            end
        end
    end

    // -----------------------------------------------------------------------
    // 8.  Apply gain to both channels (Q0.16 multiply)
    // -----------------------------------------------------------------------
    generate
        genvar ch;
        for (ch = 0; ch < 2; ch++) begin : APPLY_GAIN
            logic signed [DATA_W-1:0]    ch_in;
            logic signed [DATA_W+16:0]   ch_product;

            assign ch_in      = $signed(audio_in[ch]);
            assign ch_product = ch_in * $signed({ 1'b0, gain });
            assign audio_out[ch] = ch_product[DATA_W+16-1 : 16];
        end
    endgenerate

endmodule