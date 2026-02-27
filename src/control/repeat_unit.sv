/*
 * repeat_unit.sv
 *
 * Generates auto-repeat pulses while a button is held down.
 *
 * Behaviour mirrors a keyboard's key-repeat: after the button has been
 * held for REPEAT_START_CNT cycles (the initial delay), a pulse is
 * emitted every REPEAT_RATE_CNT cycles for as long as stable remains
 * asserted.  Both counters reset immediately when the button is released.
 *
 * This module is intended to be paired with debounce_unit; its stable
 * input should come from debounce_unit's stable output.
 *
 * Ports
 * -----
 *   stable — debounced button level (active-high, from debounce_unit)
 *   pulse  — single-cycle high pulse at the auto-repeat rate
 */

module repeat_unit (
    input  logic clk, rst_n, stable,
    output logic pulse
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Internal Counters
    // ----------------------------------------------------------------

    logic [$clog2(REPEAT_START_CNT)-1:0] hold_cnt;  // time button has been held
    logic [$clog2(REPEAT_RATE_CNT)-1:0]  rate_cnt;  // phase within repeat period

    // ----------------------------------------------------------------
    // Auto-Repeat FSM
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            hold_cnt <= '0;
            rate_cnt <= '0;
            pulse    <= 1'b0;
        end else begin
            pulse <= 1'b0;  // default: no pulse this cycle

            if (stable) begin
                if (hold_cnt < REPEAT_START_CNT) begin
                    // Initial hold period — no repeat yet
                    hold_cnt <= hold_cnt + 1'b1;
                end else if (rate_cnt == REPEAT_RATE_CNT - 1) begin
                    // Repeat period elapsed — emit pulse and restart rate counter
                    rate_cnt <= '0;
                    pulse    <= 1'b1;
                end else begin
                    rate_cnt <= rate_cnt + 1'b1;
                end
            end else begin
                // Button released — reset both counters
                hold_cnt <= '0;
                rate_cnt <= '0;
            end
        end
    end

endmodule