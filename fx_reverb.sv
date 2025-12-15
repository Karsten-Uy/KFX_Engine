// Reverb (FX 7)
module fx_reverb #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 7
)(
    input  logic                      clk,
    input  logic                      reset_n,
    input  logic [1:0][DATA_W-1:0]    audio_in,   // Stereo input
    output logic [1:0][DATA_W-1:0]    audio_out,  // Stereo output
    input  logic [PARAM_W-1:0]        size,       // Room size
    input  logic [PARAM_W-1:0]        damping,    // High frequency damping
    input  logic [PARAM_W-1:0]        mix         // Dry/wet mix
);

    // Trivial assignment for now
    assign audio_out = audio_in;

endmodule