// EQ (FX 2)
module fx_eq #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 7
)(
    input  logic                      clk,
    input  logic                      reset_n,
    input  logic [1:0][DATA_W-1:0]    audio_in,   // Stereo input
    output logic [1:0][DATA_W-1:0]    audio_out,  // Stereo output
    input  logic [PARAM_W-1:0]        fx_low_gain,   // Low frequency gain
    input  logic [PARAM_W-1:0]        fx_mid_gain,   // Mid frequency gain
    input  logic [PARAM_W-1:0]        fx_high_gain,  // High frequency gain
    input  logic [PARAM_W-1:0]        fx_presence,    // Presence control
    input  logic                      sample_en
);    

    
    // Trivial assignment for now
    assign audio_out = audio_in;

endmodule