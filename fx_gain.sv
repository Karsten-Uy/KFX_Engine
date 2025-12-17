
module fx_gain #(
    parameter DATA_W  = 16,
    PARAM_W = 8
)(
    input  logic                      clk,
    input  logic                      reset_n,
    input  logic [1:0][DATA_W-1:0]    audio_in,   // Stereo input
    output logic [1:0][DATA_W-1:0]    audio_out,  // Stereo output
    input  logic [PARAM_W-1:0]        fx_gain,        // Gain parameter
    input  logic                      sample_en
);

    // ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;

    // ---------------- INTERNAL SIGNALS ----------------
    logic signed [31:0] mult_l, mult_r;

    assign mult_l = $signed(audio_in[0]) * $signed({1'b0, fx_gain});
    assign mult_r = $signed(audio_in[1]) * $signed({1'b0, fx_gain});

    // ---------------- MAIN LOGIC ----------------
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
            // mult_l <= '0;
            // mult_r <= '0;
        end else if (sample_en) begin
            // Multiply audio (signed 16-bit) by gain (unsigned 9-bit)
            // Result is signed 25-bit, stored in 32-bit

            
            // Divide by 128 (shift right 7) and saturate
            // fx_gain = 128 → unity gain
            audio_out[0] <= sat16(mult_l >>> 7);
            audio_out[1] <= sat16(mult_r >>> 7);
        end
    end


endmodule