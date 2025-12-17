// Delay (FX 6)
module fx_delay #(
    parameter DATA_W  = 16,
    PARAM_W = 8
)(
    input  logic                      clk,
    input  logic                      reset_n,
    input  logic [1:0][DATA_W-1:0]    audio_in,   // Stereo input
    output logic [1:0][DATA_W-1:0]    audio_out,  // Stereo output
    input  logic [PARAM_W-1:0]        fx_time,       // Delay time
    input  logic [PARAM_W-1:0]        fx_feedback,   // Feedback amount
    input  logic [PARAM_W-1:0]        fx_mix,         // Dry/wet mix
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