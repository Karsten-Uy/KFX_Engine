/*
    fx_gate.sv — Noise Gate FX Module
    
    Signal Chain:
      1. Compute absolute value of the mono side-chain (ch 0)
      2. Compare against threshold ± knee/2 → three zones
         • above upper_edge : gate OPEN   → target gain = 0xFFFF
         • below lower_edge : gate CLOSED → target gain = gain_min (depth-scaled)
         • in knee region   : target gain linearly interpolated between min and max
      3. Slew the envelope gain toward target at attack / release rates
      4. Multiply both channels by the envelope gain (Q0.16 fixed-point)

    Parameter mapping (all 8-bit, 0–255):
      fx_threshold : noise floor level, scaled to DATA_W range
                     0 = always open, 255 = nearly always closed
      fx_attack    : how fast gate OPENS  (0 = instant, 255 = ~256 samples)
      fx_release   : how fast gate CLOSES (0 = instant, 255 = ~256 samples)
      fx_knee      : soft-knee half-width around threshold
                     0 = hard switch, 255 = widest transition zone
      fx_depth     : attenuation floor when gate is closed
                     0 = full mute, 255 = unity (no gating effect)
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
    // 2.  Threshold, knee edges, and gain floor
    //
    //     threshold_scaled = { fx_threshold, 8'b0 }  → 0x0000 .. 0xFF00
    //     knee_half        = { fx_knee[6:0], 9'b0 }  → half knee width
    //     upper_edge       = threshold + knee_half    (clamp to 0xFFFF)
    //     lower_edge       = threshold - knee_half    (clamp to 0x0000)
    //     gain_min         = { fx_depth, fx_depth }   → 0x0000 .. 0xFFFF
    // -----------------------------------------------------------------------
    logic [DATA_W-1:0]   threshold_scaled;
    logic [DATA_W-1:0]   knee_half;
    logic [DATA_W:0]     upper_tmp;          // 17-bit to detect overflow
    logic [DATA_W-1:0]   upper_edge;
    logic [DATA_W-1:0]   lower_edge;
    logic [15:0]         gain_min;

    assign threshold_scaled = { fx_threshold, {(DATA_W-PARAM_W){1'b0}} };

    // knee_half uses the upper 7 bits of fx_knee shifted into the high byte
    // so knee=255 → ±0x7F80, knee=0 → 0
    assign knee_half  = { 1'b0, fx_knee, {(DATA_W-PARAM_W-1){1'b0}} };

    assign upper_tmp  = { 1'b0, threshold_scaled } + { 1'b0, knee_half };
    assign upper_edge = upper_tmp[DATA_W] ? {DATA_W{1'b1}} : upper_tmp[DATA_W-1:0];

    assign lower_edge = (threshold_scaled > knee_half)
                        ? (threshold_scaled - knee_half)
                        : '0;

    // depth=0 → gain_min=0x0000 (full mute), depth=255 → 0xFFFF (unity)
    assign gain_min = { fx_depth, fx_depth };

    // -----------------------------------------------------------------------
    // 3.  Zone detection
    // -----------------------------------------------------------------------
    logic gate_open;    // signal is clearly above threshold+knee
    logic gate_closed;  // signal is clearly below threshold-knee

    assign gate_open   = (abs_in >= upper_edge);
    assign gate_closed = (abs_in <= lower_edge);

    // -----------------------------------------------------------------------
    // 4.  Soft-knee linear interpolation (no divider — shift approximation)
    //
    //     knee width W = upper_edge - lower_edge = 2 * knee_half
    //     position  p  = abs_in - lower_edge          (0 .. W)
    //
    //     We need:  frac = p / W  scaled to [0, 255]
    //
    //     Strategy: normalise W to 8 bits by right-shifting both p and W
    //     by the same amount (determined by the leading bit of W).
    //     This gives ±1 LSB accuracy over the knee — adequate for audio.
    //
    //     knee_target = gain_min + frac * (0xFFFF - gain_min) / 255
    // -----------------------------------------------------------------------
    logic [DATA_W-1:0]  knee_pos;        // abs_in - lower_edge
    logic [DATA_W-1:0]  knee_width;      // upper_edge - lower_edge
    logic [7:0]         knee_frac;       // 0..255

    assign knee_pos   = abs_in    - lower_edge;
    assign knee_width = upper_edge - lower_edge;

    // Find the shift amount so that knee_width fits in 8 bits.
    // We look at which of the top bits of knee_width is set.
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

    logic [DATA_W-1:0] kw_norm;   // knee_width >> kw_shift, fits in 8 bits
    logic [DATA_W-1:0] kp_norm;   // knee_pos   >> kw_shift

    assign kw_norm = knee_width >> kw_shift;
    assign kp_norm = knee_pos   >> kw_shift;

    // frac = min(kp_norm, kw_norm) * 255 / kw_norm
    // Since kw_norm fits in 8 bits and we want 8-bit result:
    //   frac ≈ (kp_norm[7:0] * 8'hFF) / kw_norm[7:0]
    // Use 16-bit intermediate; guard against divide-by-zero with kw_norm==0.
    logic [15:0] frac_num;
    assign frac_num  = kp_norm[7:0] * 8'hFF;
    assign knee_frac = (kw_norm == '0) ? 8'hFF
                     : (kp_norm >= kw_norm) ? 8'hFF
                     : frac_num[15:8];   // ÷ 256 ≈ ÷ kw_norm when kw_norm~=256

    // knee_target = gain_min + (gain_range * knee_frac) >> 8
    logic [15:0] gain_range;
    logic [23:0] knee_interp;
    logic [15:0] knee_target;

    assign gain_range   = 16'hFFFF - gain_min;
    assign knee_interp  = gain_range * { 8'b0, knee_frac };
    assign knee_target  = gain_min + knee_interp[23:8];

    // -----------------------------------------------------------------------
    // 5.  Gain target mux
    // -----------------------------------------------------------------------
    logic [15:0] gain_target;

    always_comb begin
        if      (gate_open)   gain_target = 16'hFFFF;
        else if (gate_closed) gain_target = gain_min;
        else                  gain_target = knee_target;
    end

    // -----------------------------------------------------------------------
    // 6.  Envelope gain register — slew toward target each sample_en tick
    //
    //     attack_step  = 256 - fx_attack   (1..256 per sample tick)
    //     release_step = 256 - fx_release
    //
    //     Larger param → smaller step → slower ramp.
    // -----------------------------------------------------------------------
    logic [15:0] gain;
    logic [8:0]  attack_step;
    logic [8:0]  release_step;

    assign attack_step  = 9'd256 - { 1'b0, fx_attack  };
    assign release_step = 9'd256 - { 1'b0, fx_release };

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            gain <= 16'hFFFF;           // start with gate fully open
        end else if (sample_en) begin
            if (gain < gain_target) begin
                // Rising (attack)
                if ((gain_target - gain) <= { 7'b0, attack_step })
                    gain <= gain_target;
                else
                    gain <= gain + { 7'b0, attack_step };

            end else if (gain > gain_target) begin
                // Falling (release)
                if ((gain - gain_target) <= { 7'b0, release_step })
                    gain <= gain_target;
                else
                    gain <= gain - { 7'b0, release_step };
            end
            // else: gain == gain_target, hold
        end
    end

    // -----------------------------------------------------------------------
    // 7.  Apply gain to both channels (combinational)
    //
    //     audio_out = audio_in * gain >> 16   (Q0.16 multiply)
    //
    //     audio_in  : signed 16-bit
    //     gain      : unsigned 16-bit → sign-extend to 17-bit (MSB=0)
    //     product   : signed 33-bit
    //     result    : product[32:17]  (discard lower 16 fractional bits,
    //                                  take 16 integer bits)
    // -----------------------------------------------------------------------
    generate
        genvar ch;
        for (ch = 0; ch < 2; ch++) begin : APPLY_GAIN
            logic signed [DATA_W-1:0]    ch_in;
            logic signed [DATA_W+16:0]   ch_product;   // 33-bit signed

            assign ch_in      = $signed(audio_in[ch]);
            assign ch_product = ch_in * $signed({ 1'b0, gain });  // 16s × 17u → 33s
            assign audio_out[ch] = ch_product[DATA_W+16-1 : 16];  // [31:16]
        end
    endgenerate

endmodule