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
 * Reset behaviour
 * ---------------
 * While reset_n is asserted, the buffer is walked one address per clock
 * writing 0 (a full pass completes in MAX_DELAY_SAMPLES clocks).  This
 * clears stale BRAM that would otherwise be read back the instant audio
 * resumes — the same post-bank-switch buzz fix used in delay_line.sv.
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
    logic [ADDR_W-1:0]        clear_addr = '0;  // reset-time BRAM clear walk
                                                 // (init 0 = FPGA power-up state;
                                                 //  also keeps 4-state sim defined)
    logic signed [DATA_W-1:0] ram_out0, ram_out1;

    // BRAM write-port mux — selects between the reset-time clear walk and
    // normal sample_en writes (mirrors delay_line.sv).  Splitting the write
    // out of the read always_ff keeps a clean M10K inference.
    logic [ADDR_W-1:0]        bram_wr_addr;
    logic signed [DATA_W-1:0] bram_wr_data;
    logic                     bram_we;

    // Split fixed-point delay into integer and fractional parts
    logic [ADDR_W-1:0] delay_int;
    logic [FRAC_W-1:0] delay_frac;
    assign delay_int  = delay_samples[ADDR_W + FRAC_W - 1 : FRAC_W];
    assign delay_frac = delay_samples[FRAC_W-1:0];

    // Registered fractional part (aligned with the RAM read pipeline stage)
    logic [FRAC_W-1:0] frac_reg;

    // Interpolation intermediate values (32-bit signed for headroom).
    // `product` is the only multiply (diff × FRAC_W-bit fraction).  Forcing
    // it into ALUTs keeps it off the scarce DSP blocks — the design runs at
    // 87/87 DSP, and with FRAC_W small the shift-add tree is cheap.  This
    // also frees the DSPs the chorus instances would otherwise spend here.
    logic signed [31:0] s0, s1, diff, interpolated;
    (* multstyle = "logic" *) logic signed [31:0] product;

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
    // Write-Port Mux  (combinational)
    //
    // During reset, walk every address writing 0 (clear_addr advances one
    // step per clock in the pointer block below).  Outside reset, data_in
    // is written at write_ptr on each sample_en pulse.
    // ----------------------------------------------------------------

    always_comb begin
        if (!reset_n) begin
            bram_wr_addr = clear_addr;
            bram_wr_data = '0;
            bram_we      = 1'b1;
        end else begin
            bram_wr_addr = write_ptr;
            bram_wr_data = data_in;
            bram_we      = sample_en;
        end
    end

    // ----------------------------------------------------------------
    // Synchronous RAM Access  (one-cycle read latency)
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (bram_we) buffer[bram_wr_addr] <= bram_wr_data;
    end

    always_ff @(posedge clk) begin
        if (sample_en) begin
            ram_out0 <= buffer[read_ptr0];
            ram_out1 <= buffer[read_ptr1];
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
            write_ptr  <= '0;
            data_out   <= '0;
            frac_reg   <= '0;
            clear_addr <= (clear_addr == ADDR_W'(MAX_DELAY_SAMPLES - 1))
                          ? '0
                          : clear_addr + 1'b1;
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
