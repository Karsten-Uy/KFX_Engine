/*
 * delay_line.sv
 *
 * Single-channel circular-buffer delay line backed by M10K block RAM.
 *
 * Operates as a synchronous FIFO with a variable read offset: on every
 * sample_en pulse, data_in is written to the current write pointer and
 * the sample that was written delay_samples ticks ago is returned on
 * data_out one clock cycle later.
 *
 * sample_en must be a single-cycle pulse; data_in must be valid on that
 * cycle.  Holding sample_en for more than one cycle will corrupt the
 * buffer contents.
 *
 * If delay_samples == 0, data_in is passed through combinationally
 * (zero latency).  For all other values, latency is 1 sample (one
 * registered RAM read pipeline stage).
 *
 * Ports
 * -----
 *   data_in       — sample to write
 *   data_out      — sample from delay_samples ticks ago
 *   delay_samples — read offset in whole samples; must be < MAX_DELAY_SAMPLES
 *   sample_en     — single-cycle write/advance strobe
 */

module delay_line #(
    parameter DATA_W             = 16,
    parameter MAX_DELAY_SAMPLES  = 24000,
    parameter ADDR_W             = $clog2(MAX_DELAY_SAMPLES)
)(
    input  logic                     clk,
    input  logic                     reset_n,
    input  logic signed [DATA_W-1:0] data_in,
    output logic signed [DATA_W-1:0] data_out,
    input  logic [ADDR_W-1:0]        delay_samples,
    input  logic                     sample_en
);

    // ----------------------------------------------------------------
    // Internal Signals
    // ----------------------------------------------------------------

    (* ramstyle = "M10K" *) logic signed [DATA_W-1:0] buffer [0:MAX_DELAY_SAMPLES-1];

    logic [ADDR_W-1:0]        write_ptr;
    logic [ADDR_W-1:0]        read_ptr;
    logic signed [DATA_W-1:0] ram_out;

    // ----------------------------------------------------------------
    // Read Address Calculation
    //
    // Subtracts delay_samples from write_ptr with power-of-two-safe
    // wrap-around.  Uses full modular subtraction rather than a mask
    // so MAX_DELAY_SAMPLES does not need to be a power of two.
    // ----------------------------------------------------------------

    always_comb begin
        if (write_ptr >= delay_samples)
            read_ptr = write_ptr - delay_samples;
        else
            read_ptr = MAX_DELAY_SAMPLES + write_ptr - delay_samples;
    end

    // ----------------------------------------------------------------
    // Synchronous RAM Access  (one-cycle read latency)
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (sample_en) begin
            buffer[write_ptr] <= data_in;
            ram_out           <= buffer[read_ptr];
        end
    end

    // ----------------------------------------------------------------
    // Write Pointer + Output Register
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            write_ptr <= '0;
            data_out  <= '0;
        end else if (sample_en) begin
            // Zero delay: bypass the RAM and pass through immediately
            data_out <= (delay_samples == '0) ? data_in : ram_out;

            write_ptr <= (write_ptr >= MAX_DELAY_SAMPLES - 1) ? '0
                                                               : write_ptr + 1'b1;
        end
    end

endmodule
