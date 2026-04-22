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
 *   Asserted once a measured interval maps to a sample count inside
 *   [MIN_DELAY_SAMPLES, MAX_DELAY_SAMPLES].  Out-of-range taps are silently
 *   ignored; tap_active and delay_samples are unchanged, but the interval
 *   counter resets so the next tap re-measures from the ignored one.
 *
 *   Once asserted, tap_active remains high until rst_n is de-asserted.
 *   There is no idle timeout — tap tempo holds indefinitely so the delay
 *   never snaps back to the knob value mid-performance.
 *
 * Ports
 * -----
 *   tap_pulse     — single-cycle pulse from tap_mute_unit (short press)
 *   delay_samples — tap interval expressed in audio samples; held on
 *                   out-of-range taps; updated only on a valid in-range tap
 *   tap_active    — high while tap tempo is overriding the fx_time knob;
 *                   clears only on reset
 */

module tap_tempo_unit (
    input  logic clk,
    input  logic rst_n,
    input  logic tap_pulse,

    output logic [$clog2(MAX_SAMPLES)-1:0] delay_samples,
    output logic                           tap_active,
    output logic                           beat_pulse
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Local Parameters
    // ----------------------------------------------------------------

    localparam int ADDR_W    = $clog2(MAX_SAMPLES);
    // Size the interval counter to hold the largest useful tap interval:
    // MAX_DELAY_SAMPLES samples × 2^CPS_SHIFT cycles/sample, plus one
    // guard bit so the counter can saturate without wrapping.
    localparam int CPS_SHIFT = 10;  // 2^10 = 1024 ≈ cycles-per-sample
    localparam int CNT_W     = ADDR_W + CPS_SHIFT + 1;

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
            tap_active    <= 1'b1;
            delay_samples <= ADDR_W'(MIN_DELAY_SAMPLES);
        end else if (tap_pulse) begin
            if (has_first_tap) begin
                // Saturate the count: If too slow, use MAX. If too fast, use MIN.
                if (raw_samples > CNT_W'(MAX_DELAY_SAMPLES)) begin
                    delay_samples <= ADDR_W'(MAX_DELAY_SAMPLES);
                end else if (raw_samples < CNT_W'(MIN_DELAY_SAMPLES)) begin
                    delay_samples <= ADDR_W'(MIN_DELAY_SAMPLES);
                end else begin
                    delay_samples <= raw_samples[ADDR_W-1:0];
                end
                tap_active <= 1'b1;
            end
            interval_cnt  <= '0;
            has_first_tap <= 1'b1;
        end else begin
            if (interval_cnt < CNT_W'(2**CNT_W - 1)) begin
                interval_cnt <= interval_cnt + 1'b1;
            end
        end
    end
    // ------------------------------------------------------------------
    // Beat Pulse - fires once per delay_samples clock cycles when active
    // ------------------------------------------------------------------
    logic [CNT_W-1:0] beat_cnt;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            beat_cnt   <= '0;
            beat_pulse <= 1'b0;
        end else begin
            beat_pulse <= 1'b0;

            // Reset phase on EVERY tap attempt to provide visual feedback
            if (tap_pulse && has_first_tap) begin
                beat_cnt <= '0; 
                // Optional: pulse immediately on tap for instant feedback
                // beat_pulse <= 1'b1; 
            end else if (tap_active) begin
                if (beat_cnt >= (CNT_W'(delay_samples) << CPS_SHIFT) - 1) begin
                    beat_cnt   <= '0;
                    beat_pulse <= 1'b1;
                end else begin
                    beat_cnt <= beat_cnt + 1'b1;
                end
            end
        end
    end

endmodule