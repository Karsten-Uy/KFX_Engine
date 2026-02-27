/*
 * tap_tempo_unit.sv
 *
 * Converts footswitch tap intervals into a delay-line sample count for fx_delay.
 *
 * At least two taps are required before any output is produced.  On each
 * qualifying tap the clock-cycle interval since the previous tap is converted
 * to an audio sample count using a power-of-two shift approximation, then
 * range-checked before being latched into delay_samples.
 *
 * Cycle-to-sample conversion
 * --------------------------
 *   Exact ratio:  50_000_000 / 48_000 ≈ 1041.67 cycles per sample.
 *   Approximation: 1024 = 2^CPS_SHIFT  (right-shift by CPS_SHIFT).
 *   Error: ~1.7 % — inaudible for tap-tempo use.
 *
 * tap_active behaviour
 * --------------------
 *   Asserted only when a measured interval maps to a sample count inside
 *   [MIN_DELAY_SAMPLES, MAX_DELAY_SAMPLES].  Out-of-range taps are silently
 *   ignored; tap_active and delay_samples are unchanged, but the interval
 *   counter resets so the next tap re-measures from the ignored one.
 *
 *   Once asserted, tap_active remains high until either TIMEOUT_CYCLES
 *   elapse with no tap, or rst_n is de-asserted.  This prevents the delay
 *   from snapping back to the knob value mid-performance.
 *
 * Ports
 * -----
 *   tap_pulse     — single-cycle pulse from tap_mute_unit (short press)
 *   delay_samples — tap interval expressed in audio samples; held on
 *                   out-of-range taps; updated only on a valid in-range tap
 *   tap_active    — high while tap tempo is overriding the fx_time knob
 */

module tap_tempo_unit (
    input  logic clk,
    input  logic rst_n,
    input  logic tap_pulse,

    output logic [$clog2(MAX_SAMPLES)-1:0] delay_samples,
    output logic                           tap_active
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Local Parameters
    // ----------------------------------------------------------------

    localparam int ADDR_W    = $clog2(MAX_SAMPLES);
    localparam int CNT_W     = $clog2(TIMEOUT_CYCLES + 1);
    localparam int CPS_SHIFT = 10;  // 2^10 = 1024 ≈ cycles-per-sample

    // ----------------------------------------------------------------
    // Internal Signals
    // ----------------------------------------------------------------

    logic [CNT_W-1:0] interval_cnt;   // clock cycles since last tap
    logic             has_first_tap;  // at least one tap has been seen

    // Current interval expressed as audio samples (combinational)
    logic [CNT_W-1:0] raw_samples;
    assign raw_samples = interval_cnt >> CPS_SHIFT;

    // Whether the measured interval falls within the usable delay range
    logic tap_in_range;
    assign tap_in_range = (raw_samples >= CNT_W'(MIN_DELAY_SAMPLES)) &&
                          (raw_samples <= CNT_W'(MAX_DELAY_SAMPLES));

    // ----------------------------------------------------------------
    // Tap Interval Measurement
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            interval_cnt  <= '0;
            has_first_tap <= 1'b0;
            tap_active    <= 1'b0;
            delay_samples <= ADDR_W'(MIN_DELAY_SAMPLES);

        end else if (tap_pulse) begin
            // ---- Tap received ----------------------------------------
            if (has_first_tap && tap_in_range) begin
                // Valid interval within delay bounds: latch and activate
                delay_samples <= raw_samples[ADDR_W-1:0];
                tap_active    <= 1'b1;
            end
            // Out-of-range tap: interval_cnt still resets so the NEXT tap
            // measures from this one, giving the player a chance to re-tap
            // at the correct tempo without restarting from scratch.

            interval_cnt  <= '0;
            has_first_tap <= 1'b1;

        end else begin
            // ---- Between taps: count up ------------------------------
            if (interval_cnt < CNT_W'(TIMEOUT_CYCLES)) begin
                interval_cnt <= interval_cnt + 1'b1;
            end else begin
                // Timeout: hand control back to the fx_time knob.
                // delay_samples is held so there is no audible jump when
                // tap_active falls; fx_delay muxes back to the knob value.
                tap_active    <= 1'b0;
                has_first_tap <= 1'b0;
                interval_cnt  <= '0;
            end
        end
    end

endmodule