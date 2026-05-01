
// -----------------------------------------------------------------------------
// Audio FX output monitor
// -----------------------------------------------------------------------------
module fx_monitor #(
    parameter int    DATA_W  = 16,
    parameter int    LATENCY = 1,      // Clock cycles between sample_en and valid output
    parameter string NAME    = "MON"   // Prefix for console messages
)(
    input logic clk,
    input logic reset_n,
    input logic sample_en,
    input logic [1:0][DATA_W-1:0] audio_out
);

    // Shift register to track the sample through the DUT pipeline.
    // Sized to 32 bits to accommodate latencies up to 32 cycles.
    logic [31:0] delay_pipe; 

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            delay_pipe <= '0;
        end else begin
            // Shift left, pulling in the new sample strobe
            delay_pipe <= {delay_pipe[30:0], sample_en};
        end
    end

    // Determine when output data is valid based on the parameterized latency
    logic valid_out;
    assign valid_out = (LATENCY == 0) ? sample_en : delay_pipe[LATENCY-1];

    // Print the output when it arrives
    always_ff @(posedge clk) begin
        if (reset_n && valid_out) begin
            $display("[%0t] [%s] OUT -> Left: %0d | Right: %0d", 
                     $time, NAME, $signed(audio_out[0]), $signed(audio_out[1]));
        end
    end

endmodule