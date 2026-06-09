/*
 * fx_gain.sv
 *
 * Stereo gain stage: scales both channels by a single 8-bit multiplier.
 *
 * The gain parameter is unsigned Q3.5 scaled so that fx_gain = 32 produces
 * unity gain (1.0×).  Values above 32 amplify; values below 32 attenuate.
 * The 16×9-bit product is right-shifted by 5 bits and saturated to 16-bit
 * signed before being registered on the output.
 *
 *   output = saturate16( (audio_in * fx_gain) >> 5 )
 *
 * SMOOTH parameter
 * ----------------
 *   SMOOTH = 0 (default): direct multiply (above).  Correct for gains that
 *     only change occasionally via button/host edits (Input, Output, Global).
 *
 *   SMOOTH = 1: slew-limit the gain.  A continuously-moving control — the
 *     expression pedal — steps fx_gain every few samples; because unity is
 *     32, each 1-LSB step is a ~3 % instantaneous gain jump, and a stream of
 *     them is audible zipper crackle.  Here the multiplier ramps toward the
 *     target sub-LSB (one-pole, ~2.7 ms @ 48 kHz) so the change is inaudible.
 *     Same scheme as the reverb's slew accumulator.  Steady state is
 *     bit-identical to the direct path: in*(g<<GF) >> (5+GF) == (in*g) >> 5.
 *
 * Latency: 1 sample (both modes).
 *
 * Ports
 * -----
 *   audio_in  — stereo signed 16-bit input  [1]=right  [0]=left
 *   audio_out — stereo signed 16-bit output
 *   fx_gain   — gain multiplier (0–255);  32 = unity
 *   sample_en — single-cycle sample strobe
 */

module fx_gain #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8,
    parameter SMOOTH  = 0    // 1 = slew-limit the gain (use for the expression pedal)
)(
    input  logic                   clk,
    input  logic                   reset_n,
    input  logic [1:0][DATA_W-1:0] audio_in,
    output logic [1:0][DATA_W-1:0] audio_out,
    input  logic [PARAM_W-1:0]     fx_gain,
    input  logic                   sample_en
);

    import lab_pkg::*;

    generate
    if (SMOOTH == 0) begin : G_DIRECT

        // ------------------------------------------------------------
        // Direct gain multiply — output = sat16( (in * g) >> 5 ).
        // ------------------------------------------------------------
        logic signed [31:0] mult_l, mult_r;

        assign mult_l = $signed(audio_in[0]) * $signed({1'b0, fx_gain});
        assign mult_r = $signed(audio_in[1]) * $signed({1'b0, fx_gain});

        always_ff @(posedge clk) begin
            if (!reset_n) begin
                audio_out <= '0;
            end else if (sample_en) begin
                audio_out[0] <= sat16(mult_l >>> 5);
                audio_out[1] <= sat16(mult_r >>> 5);
            end
        end

    end else begin : G_SMOOTH

        // ------------------------------------------------------------
        // Slew-limited gain — one-pole ramp toward {fx_gain << GF}.
        //   gain_acc += (target - gain_acc) >>> SLEW   (per sample)
        // GF fractional bits keep the ramp sub-LSB, so even a 1-LSB
        // change in fx_gain glides instead of stepping (no zipper).
        // ------------------------------------------------------------
        localparam int GF   = 8;   // fractional gain bits
        localparam int SLEW = 7;   // ~2^7 samples (~2.7 ms @ 48 kHz)

        logic signed [PARAM_W+GF:0] gain_target, gain_acc;
        logic signed [47:0]         mult_l, mult_r;

        // target in Q(PARAM_W).GF — concat (not shift) so width is explicit.
        assign gain_target = $signed({1'b0, fx_gain, {GF{1'b0}}});

        assign mult_l = $signed(audio_in[0]) * gain_acc;
        assign mult_r = $signed(audio_in[1]) * gain_acc;

        always_ff @(posedge clk) begin
            if (!reset_n) begin
                gain_acc  <= gain_target;   // start at the target — no startup swell
                audio_out <= '0;
            end else if (sample_en) begin
                gain_acc     <= gain_acc + (($signed(gain_target) - $signed(gain_acc)) >>> SLEW);
                audio_out[0] <= sat16(mult_l >>> (5 + GF));
                audio_out[1] <= sat16(mult_r >>> (5 + GF));
            end
        end

    end
    endgenerate

endmodule
