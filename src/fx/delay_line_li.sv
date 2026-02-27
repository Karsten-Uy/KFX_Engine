/*
 * delay_line_li.sv
 *
 * Single-channel circular-buffer delay line with linear interpolation,
 * backed by M10K block RAM.  Intended for the chorus module where the
 * modulated delay time changes continuously and fractional sample
 * positioning is required to prevent quantisation buzz.
 *
 * delay_samples is a fixed-point value in Q(ADDR_W).(FRAC_W) format:
 * the upper ADDR_W bits are the integer part (whole samples) and the
 * lower FRAC_W bits are the fractional part.
 *
 * On each sample_en pulse:
 *   1. Two adjacent RAM locations are read (integer delay and integer+1).
 *   2. The fractional part is registered (one cycle pipeline).
 *   3. Linear interpolation is applied:
 *        out = s0 + frac * (s1 - s0)
 *
 * Latency: 2 samples (one RAM read pipeline stage + one interpolation stage).
 *
 * sample_en must be a single-cycle pulse with data_in valid on that cycle.
 *
 * Ports
 * -----
 *   data_in       — sample to write
 *   data_out      — interpolated sample from delay_samples ticks ago
 *   delay_samples — Q(ADDR_W).(FRAC_W) fractional delay; must be in
 *                   range [0, MAX_DELAY_SAMPLES)
 *   sample_en     — single-cycle write/advance strobe
 */

module delay_line_li #(
    parameter DATA_W            = 16,
    parameter MAX_DELAY_SAMPLES = 2048,
    parameter ADDR_W            = $clog2(MAX_DELAY_SAMPLES),
    parameter FRAC_W            = 4
)(
    input  logic                              clk,
    input  logic                              reset_n,
    input  logic signed [DATA_W-1:0]          data_in,
    output logic signed [DATA_W-1:0]          data_out,
    input  logic [ADDR_W + FRAC_W - 1:0]     delay_samples,
    input  logic                              sample_en
);

    // ----------------------------------------------------------------
    // Internal Signals
    // ----------------------------------------------------------------

    (* ramstyle = "M10K" *) logic signed [DATA_W-1:0] buffer [0:MAX_DELAY_SAMPLES-1];

    logic [ADDR_W-1:0]        write_ptr;
    logic [ADDR_W-1:0]        read_ptr0;   // integer-delay address
    logic [ADDR_W-1:0]        read_ptr1;   // integer-delay + 1 (for interpolation)
    logic signed [DATA_W-1:0] ram_out0, ram_out1;

    // Split fixed-point delay into integer and fractional parts
    logic [ADDR_W-1:0] delay_int;
    logic [FRAC_W-1:0] delay_frac;
    assign delay_int  = delay_samples[ADDR_W + FRAC_W - 1 : FRAC_W];
    assign delay_frac = delay_samples[FRAC_W-1:0];

    // Registered fractional part (aligned with the RAM read pipeline stage)
    logic [FRAC_W-1:0] frac_reg;

    // Interpolation intermediate values (32-bit signed for headroom)
    logic signed [31:0] s0, s1, diff, product, interpolated;

    // ----------------------------------------------------------------
    // Read Address Calculation
    // ----------------------------------------------------------------

    always_comb begin
        // Primary address: integer delay before current write pointer
        if (write_ptr >= delay_int)
            read_ptr0 = write_ptr - delay_int;
        else
            read_ptr0 = MAX_DELAY_SAMPLES + write_ptr - delay_int;

        // Secondary address: one sample later in the buffer (with wrap)
        read_ptr1 = (read_ptr0 == MAX_DELAY_SAMPLES - 1) ? '0 : read_ptr0 + 1'b1;
    end

    // ----------------------------------------------------------------
    // Synchronous RAM Access  (one-cycle read latency)
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (sample_en) begin
            buffer[write_ptr] <= data_in;
            ram_out0          <= buffer[read_ptr0];
            ram_out1          <= buffer[read_ptr1];
        end
    end

    // ----------------------------------------------------------------
    // Linear Interpolation + Write Pointer Management
    //
    // out = s0 + frac * (s1 - s0)
    //     = (s0 << FRAC_W + (s1 - s0) * frac) >> FRAC_W
    //
    // frac_reg is delayed by one cycle to align with the RAM pipeline stage.
    // All intermediate values are 32-bit signed to prevent overflow.
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            write_ptr <= '0;
            data_out  <= '0;
            frac_reg  <= '0;
        end else if (sample_en) begin
            frac_reg <= delay_frac;  // register fraction to match RAM latency

            s0 = $signed(ram_out0);
            s1 = $signed(ram_out1);

            diff         = s1 - s0;
            product      = diff * $signed({1'b0, frac_reg});
            interpolated = (s0 <<< FRAC_W) + product;

            data_out <= interpolated[DATA_W + FRAC_W - 1 : FRAC_W];

            write_ptr <= (write_ptr >= MAX_DELAY_SAMPLES - 1) ? '0
                                                               : write_ptr + 1'b1;
        end
    end

endmodule
