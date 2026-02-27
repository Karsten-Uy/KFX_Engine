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
 * Latency: 1 sample.
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
    parameter PARAM_W = 8
)(
    input  logic                   clk,
    input  logic                   reset_n,
    input  logic [1:0][DATA_W-1:0] audio_in,
    output logic [1:0][DATA_W-1:0] audio_out,
    input  logic [PARAM_W-1:0]     fx_gain,
    input  logic                   sample_en
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Gain Multiply  (combinational)
    //
    // Zero-extend fx_gain to 9 bits to keep the multiply signed.
    // Results are 32-bit before saturation.
    // ----------------------------------------------------------------

    logic signed [31:0] mult_l, mult_r;

    assign mult_l = $signed(audio_in[0]) * $signed({1'b0, fx_gain});
    assign mult_r = $signed(audio_in[1]) * $signed({1'b0, fx_gain});

    // ----------------------------------------------------------------
    // Output Register  (shift and saturate on sample boundary)
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            audio_out[0] <= sat16(mult_l >>> 5);
            audio_out[1] <= sat16(mult_r >>> 5);
        end
    end

endmodule