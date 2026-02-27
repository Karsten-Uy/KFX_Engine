/*
 * tap_mute_unit.sv
 *
 * Dual-function footswitch handler: short press = tap tempo, long press = mute.
 *
 * Press classification
 * --------------------
 *   Short press  (<MUTE_START_CNT cycles held)
 *     On release, emits a single-cycle delay_pulse for tap_tempo_unit.
 *
 *   Long press   (≥MUTE_START_CNT cycles held)
 *     Engages mute immediately when the threshold is reached; is_mute stays
 *     asserted after the button is released.
 *
 *   Press while muted
 *     Any rising edge while is_mute is asserted clears the mute immediately,
 *     regardless of how long the button is subsequently held.
 *
 * This module expects a debounced level signal from debounce_unit.
 *
 * Ports
 * -----
 *   stable      — debounced button level (active-high, from debounce_unit)
 *   is_mute     — latched mute flag; high while audio output is silenced
 *   delay_pulse — single-cycle pulse on a qualifying short press (tap tempo)
 */

module tap_mute_unit (
    input  logic clk, rst_n,
    input  logic stable,
    output logic is_mute,
    output logic delay_pulse
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Internal Signals
    // ----------------------------------------------------------------

    logic [$clog2(MUTE_START_CNT)-1:0] timer;  // counts cycles button is held
    logic long_press_triggered;                 // set once action fires this press
    logic prev_stable;                          // previous stable for edge detect

    // ----------------------------------------------------------------
    // Press Handler
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            timer                <= '0;
            is_mute              <= 1'b0;
            delay_pulse          <= 1'b0;
            long_press_triggered <= 1'b0;
            prev_stable          <= 1'b0;
        end else begin
            delay_pulse <= 1'b0;       // default: no pulse
            prev_stable <= stable;

            if (stable) begin
                if (stable && !prev_stable && is_mute) begin
                    // Rising edge while muted: clear mute immediately
                    is_mute              <= 1'b0;
                    long_press_triggered <= 1'b1;  // suppress tap on release
                end else if (!long_press_triggered) begin
                    // Counting toward long-press threshold
                    if (timer < MUTE_START_CNT - 1) begin
                        timer <= timer + 1'b1;
                    end else begin
                        // Threshold reached: engage mute
                        is_mute              <= 1'b1;
                        long_press_triggered <= 1'b1;
                    end
                end
                // If long_press_triggered is already set (and this is not an
                // unmute edge), hold the current state until the button releases.
            end else begin
                // Button released
                if (prev_stable && !long_press_triggered) begin
                    // Short press confirmed: send tap tempo pulse
                    delay_pulse <= 1'b1;
                end

                // Reset press state for the next press
                timer                <= '0;
                long_press_triggered <= 1'b0;
            end
        end
    end

endmodule