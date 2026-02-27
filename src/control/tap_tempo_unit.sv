/*
    tap_tempo_unit.sv

    Measures the clock-cycle interval between tap_pulse edges and converts
    it to a delay-line sample count that fx_delay can consume directly.

    Two or more taps are required before the output is considered valid.

    tap_active behaviour
    --------------------
      - Asserted ONLY when a measured tap interval maps to a sample count
        within [MIN_DELAY_SAMPLES, MAX_DELAY_SAMPLES].  Taps outside that
        window are silently ignored; tap_active and delay_samples are
        unchanged.
      - Once asserted, tap_active stays HIGH until either:
          * TIMEOUT_CYCLES elapse with no tap, OR
          * rst_n is de-asserted.
        This means stopping your foot mid-song won't snap the delay back
        to the knob until the full 2-second window expires.

    CPS approximation
    -----------------
      CPS = 50_000_000 / 48_000 = 1041.67 ≈ 1024 = 2^10
      Right-shifting by CPS_SHIFT converts clock cycles → audio samples
      with ~1.7 % tempo error — inaudible for tap-tempo use.

    Ports
    -----
      tap_pulse     — single-cycle pulse from tap_mute_unit (short press)
      delay_samples — tap interval in audio samples; held on out-of-range
                      taps; only updated on a valid in-range tap
      tap_active    — high while tap tempo is overriding the knob
*/

module tap_tempo_unit (
    input  logic clk,
    input  logic rst_n,
    input  logic tap_pulse,

    output logic [$clog2(MAX_SAMPLES)-1:0] delay_samples,
    output logic                           tap_active
);

    // ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;

    localparam int ADDR_W    = $clog2(MAX_SAMPLES);
    localparam int CNT_W     = $clog2(TIMEOUT_CYCLES + 1);
    localparam int CPS_SHIFT = 10;  // divide cycles by ~1024 to get samples

    logic [CNT_W-1:0] interval_cnt;
    logic             has_first_tap;

    // Combinational: current counter value expressed as samples
    logic [CNT_W-1:0] raw_samples;
    assign raw_samples = interval_cnt >> CPS_SHIFT;

    // Combinational: is this interval in the usable delay range?
    logic tap_in_range;
    assign tap_in_range = (raw_samples >= CNT_W'(MIN_DELAY_SAMPLES)) &&
                          (raw_samples <= CNT_W'(MAX_DELAY_SAMPLES));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            interval_cnt  <= '0;
            has_first_tap <= 1'b0;
            tap_active    <= 1'b0;
            delay_samples <= ADDR_W'(MIN_DELAY_SAMPLES);

        end else if (tap_pulse) begin
            // ---- Tap received ----------------------------------------
            if (has_first_tap && tap_in_range) begin
                // Valid interval and within delay bounds — latch and activate
                delay_samples <= raw_samples[ADDR_W-1:0];
                tap_active    <= 1'b1;
            end
            // Out-of-range taps: interval_cnt still resets so the NEXT
            // tap measures from this one, giving the user a chance to
            // re-tap at the right tempo without restarting from scratch.

            interval_cnt  <= '0;
            has_first_tap <= 1'b1;

        end else begin
            // ---- Between taps: count up ------------------------------
            if (interval_cnt < CNT_W'(TIMEOUT_CYCLES)) begin
                interval_cnt <= interval_cnt + 1'b1;
            end else begin
                // 2-second silence — hand control back to the fx_time knob
                tap_active    <= 1'b0;
                has_first_tap <= 1'b0;
                interval_cnt  <= '0;
                // delay_samples is held so there is no sudden jump
                // when tap_active falls; fx_delay muxes back to the knob.
            end
        end
    end

endmodule