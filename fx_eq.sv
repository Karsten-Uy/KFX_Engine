// EQ (FX 2)
module fx_eq #(
    parameter DATA_W  = 16,
    PARAM_W = 8
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
    
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            audio_out = audio_in;
        end
    end


endmodule