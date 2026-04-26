
interface fx_gain_if (input logic clk);
    logic reset_n;
    logic [1:0][15:0] audio_in;
    logic [1:0][15:0] audio_out;
    logic [7:0]       fx_gain;
    logic             sample_en;
endinterface
