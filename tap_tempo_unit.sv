/*
    tap_tempo_unit.sv

    Measures the clock-cycle interval between tap_pulse edges and converts
    it to a delay-line sample count that fx_delay can consume directly.

    Two or more taps are required before the output is considered valid.
    A configurable timeout resets the unit so the fx_time knob takes back
    over if the user stops tapping.

    CPS approximation
    -----------------
      CPS = 50 000 000 / 48 000 = 1041.67 ≈ 1024  (2^10)
      Right-shifting by CPS_SHIFT converts clock cycles → audio samples
      with ~1.7 % tempo error — inaudible for tap-tempo use.

    Ports
    -----
      tap_pulse     — single-cycle pulse from tap_mute_unit (short press)
      delay_samples — tap interval expressed in audio samples, clamped to
                      [MIN_DELAY_SAMPLES, MAX_DELAY_SAMPLES]; held until the
                      next valid tap pair or a timeout
      tap_active    — high while tap tempo is overriding the knob;
                      cleared after TIMEOUT_CYCLES of silence
*/

module tap_tempo_unit #(
    // ---- Timing ----
    parameter int TIMEOUT_CYCLES      = 100_000_000,   // 2 s  @ 50 MHz

    // ---- Delay bounds (must match fx_delay's local constants) ----
    parameter int MIN_DELAY_SAMPLES   = 2_400,         // 50 ms  @ 48 kHz
    parameter int MAX_DELAY_SAMPLES   = 24_000,        // 500 ms @ 48 kHz
    parameter int MAX_SAMPLES         = 24_000         // delay-line depth
)(
    input  logic clk,
    input  logic rst_n,

    input  logic tap_pulse,

    output logic [$clog2(MAX_SAMPLES)-1:0] delay_samples,
    output logic                           tap_active
);

    // ----------------------------------------------------------------
    // Derived widths
    // ----------------------------------------------------------------
    localparam int ADDR_W = $clog2(MAX_SAMPLES);      // 15 bits for 24 000
    localparam int CNT_W  = $clog2(TIMEOUT_CYCLES + 1);

    // CPS ≈ 2^10 — shift right by 10 to convert cycles → samples
    localparam int CPS_SHIFT = 10;

    // ----------------------------------------------------------------
    // Internal registers
    // ----------------------------------------------------------------
    logic [CNT_W-1:0] interval_cnt;   // free-running counter between taps
    logic             has_first_tap;  // have we seen at least one tap?

    // raw sample count before clamping
    logic [CNT_W-1:0] raw_samples;

    // ----------------------------------------------------------------
    // Combinational: convert current interval → sample count
    // ----------------------------------------------------------------
    assign raw_samples = interval_cnt >> CPS_SHIFT;

    // ----------------------------------------------------------------
    // Sequential logic
    // ----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            interval_cnt  <= '0;
            has_first_tap <= 1'b0;
            tap_active    <= 1'b0;
            delay_samples <= ADDR_W'(MIN_DELAY_SAMPLES);

        end else if (tap_pulse) begin
            // ---- Tap received ----------------------------------------
            if (has_first_tap) begin
                // Valid interval measured — clamp and latch
                if (raw_samples < CNT_W'(MIN_DELAY_SAMPLES))
                    delay_samples <= ADDR_W'(MIN_DELAY_SAMPLES);
                else if (raw_samples > CNT_W'(MAX_DELAY_SAMPLES))
                    delay_samples <= ADDR_W'(MAX_DELAY_SAMPLES);
                else
                    delay_samples <= raw_samples[ADDR_W-1:0];

                tap_active <= 1'b1;
            end

            // Restart the interval counter and mark reference tap seen
            interval_cnt  <= '0;
            has_first_tap <= 1'b1;

        end else begin
            // ---- Between taps: count up ------------------------------
            if (interval_cnt < CNT_W'(TIMEOUT_CYCLES)) begin
                interval_cnt <= interval_cnt + 1'b1;
            end else begin
                // Timeout — hand control back to the fx_time knob
                tap_active    <= 1'b0;
                has_first_tap <= 1'b0;
                interval_cnt  <= '0;
                // delay_samples is intentionally held so there is no
                // audible jump when tap_active de-asserts; fx_delay
                // switches back to the knob value via tap_active.
            end
        end
    end

endmodule

