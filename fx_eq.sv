// EQ (FX 2)
module fx_eq #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 7
)(
    input  logic                      clk,
    input  logic                      reset_n,
    input  logic [1:0][DATA_W-1:0]    audio_in,   // Stereo input
    output logic [1:0][DATA_W-1:0]    audio_out,  // Stereo output
    input  logic [PARAM_W-1:0]        low_gain,   // Low frequency gain
    input  logic [PARAM_W-1:0]        mid_gain,   // Mid frequency gain
    input  logic [PARAM_W-1:0]        high_gain,  // High frequency gain
    input  logic [PARAM_W-1:0]        presence    // Presence control
);
    
    // Trivial assignment for now
    assign audio_out = audio_in;

endmodule