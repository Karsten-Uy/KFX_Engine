/*

    Delay line that linear interperlates current and previous sample values for use by 
    chorus that is implemented similar to a FIFO. Using this adds 2 Samples of Latency

    Parameters:
        data_in       - input sample
        data_out      - output sample
        delay_samples - number of samples to delay by, is fractional in Q11.4 Format
        sample_en     - sampling enable signal, triggers the progression
                        of the delay line. Must not be held for more than
                        1 clock cycle and data_in must be valid. if sufficient
                        samples in memory, will set data_out to be the sample
                        that stored delay_samples before the current sample_en
                        edge
*/

module delay_line_li #(
    parameter DATA_W = 16,
    parameter MAX_DELAY_SAMPLES = 2048,
    parameter ADDR_W = $clog2(MAX_DELAY_SAMPLES),
    parameter FRAC_W = 4 
)(
    input  logic                     clk,
    input  logic                     reset_n,
    input  logic signed [DATA_W-1:0] data_in,
    output logic signed [DATA_W-1:0] data_out,
    input  logic [ADDR_W + FRAC_W - 1:0] delay_samples, 
    input  logic                     sample_en
);

    // ---------------- INTERNAL SIGNALS ----------------
    
    (* ramstyle = "M10K" *) logic signed [DATA_W-1:0] buffer [0:MAX_DELAY_SAMPLES-1];
    
    logic [ADDR_W-1:0] write_ptr;
    logic [ADDR_W-1:0] read_ptr0, read_ptr1;
    logic signed [DATA_W-1:0] ram_out0, ram_out1;
    
    logic [ADDR_W-1:0] delay_int;
    logic [FRAC_W-1:0] delay_frac;

    logic [FRAC_W-1:0] frac_reg;
    logic signed [31:0] s0, s1, diff, product, interpolated;

    // ---------------- FIFO-ISH LOGIC ----------------
    
    // Split integer and fractional parts
    assign delay_int  = delay_samples[ADDR_W + FRAC_W - 1 : FRAC_W];
    assign delay_frac = delay_samples[FRAC_W-1:0];

    // Address Calculation
    always_comb begin
        // Primary sample address
        if (write_ptr >= delay_int)
            read_ptr0 = write_ptr - delay_int;
        else
            read_ptr0 = MAX_DELAY_SAMPLES + write_ptr - delay_int;
            
        // Next sample address (wrap around the buffer)
        read_ptr1 = (read_ptr0 == MAX_DELAY_SAMPLES - 1) ? 0 : read_ptr0 + 1;
    end

    // Synchronous RAM Access
    always_ff @(posedge clk) begin
        if (sample_en) begin
            buffer[write_ptr] <= data_in;
            ram_out0 <= buffer[read_ptr0];
            ram_out1 <= buffer[read_ptr1];
        end
    end

    // ---------------- LINEAR INTERPOLATION LOGIC ----------------
    // Uses a wide 32-bit signed container for all intermediate math

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            write_ptr <= 0;
            data_out  <= 0;
            frac_reg  <= 0;
        end else if (sample_en) begin

            frac_reg <= delay_frac;            
            
            s0 = $signed(ram_out0);
            s1 = $signed(ram_out1);
            
            // Linear Interpolation: out = s0 + frac * (s1 - s0)
            diff         = s1 - s0;
            product      = diff * $signed({1'b0, frac_reg});
            interpolated = (s0 << FRAC_W) + product;
            
            // Shift back down to original scale
            data_out <= interpolated[DATA_W + FRAC_W - 1 : FRAC_W];

            // Pointer Management
            if (write_ptr >= MAX_DELAY_SAMPLES - 1)
                write_ptr <= 0;
            else
                write_ptr <= write_ptr + 1;
        end
    end

endmodule