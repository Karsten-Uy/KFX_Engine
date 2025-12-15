
module fx_gate #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 7
)(
    input  logic                      clk,
    input  logic                      reset_n,
    input  logic [1:0][DATA_W-1:0]    audio_in,   // Stereo input
    output logic [1:0][DATA_W-1:0]    audio_out,  // Stereo output
    input  logic [PARAM_W-1:0]        threshold,  // Gate threshold
    input  logic [PARAM_W-1:0]        attack,     // Attack time
    input  logic [PARAM_W-1:0]        release     // Release time
);
    
    // Trivial assignment for now
    assign audio_out = audio_in;

endmodule