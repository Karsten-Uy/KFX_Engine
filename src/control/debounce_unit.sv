/*
 * debounce_unit.sv
 *
 * Debounces a single active-high button input and produces a clean stable
 * level along with a single-cycle rising-edge pulse.
 *
 * The input is first double-flopped to cross into the clock domain, then
 * held in its current state.  A counter must reach DEBOUNCE_CNT_MAX
 * consecutive cycles of disagreement between the synchronised input and
 * the current stable output before stable is allowed to update.  Any
 * glitch shorter than that window is ignored.
 *
 * Ports
 * -----
 *   in     — raw, unsynchronised button signal (active-high)
 *   stable — debounced level; high while button is held
 *   pulse  — single-cycle high pulse on the rising edge of stable
 */

module debounce_unit (
    input  logic clk, rst_n, in,
    output logic stable, pulse
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Internal Signals
    // ----------------------------------------------------------------

    logic sync0, sync1;  // two-flop synchroniser chain
    logic prev;          // previous stable value for edge detection
    logic [$clog2(DEBOUNCE_CNT_MAX)-1:0] count;

    // ----------------------------------------------------------------
    // Edge Detection
    //
    // pulse is combinational: it goes high the same cycle that stable
    // rises, with no extra latency.
    // ----------------------------------------------------------------

    assign pulse = stable && !prev;

    // ----------------------------------------------------------------
    // Synchroniser + Debounce Counter
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sync0  <= 1'b0;
            sync1  <= 1'b0;
            stable <= 1'b0;
            prev   <= 1'b0;
            count  <= '0;
        end else begin
            // Two-flop synchroniser
            sync0 <= in;
            sync1 <= sync0;

            // Hold and count: reset counter whenever sync matches stable;
            // flip stable only after DEBOUNCE_CNT_MAX cycles of difference.
            if (sync1 == stable) begin
                count <= '0;
            end else if (count == DEBOUNCE_CNT_MAX - 1) begin
                stable <= sync1;
                count  <= '0;
            end else begin
                count <= count + 1'b1;
            end

            prev <= stable;
        end
    end

endmodule