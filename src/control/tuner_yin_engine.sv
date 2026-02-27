/*
 * tuner_yin_engine.sv
 *
 * Polyphony-aware monophonic pitch detector based on the YIN algorithm.
 *
 * YIN computes the Cumulative Mean Normalised Difference (CMND) function over
 * a sliding window of audio samples, then finds the first lag whose CMND value
 * falls below a fixed threshold — that lag is the fundamental period.
 *
 * Pipeline overview
 * -----------------
 *   1. Input pre-processing
 *        Four-tap FIR low-pass filter attenuates high-frequency content before
 *        pitch analysis, reducing false detections on harmonics.
 *
 *   2. Shadow buffers
 *        Incoming filtered samples are written simultaneously into two M10K
 *        block-RAM buffers (buffer_a / buffer_b).  Reading both from the same
 *        write pointer but offset by the current lag tau allows the difference
 *        function to be computed without a separate read-back phase.
 *
 *   3. State machine  (S_IDLE → S_SETUP → S_FETCH → S_ACCUM → S_YIN_EVAL)
 *        S_IDLE     — wait until COMP_WINDOW + MAX_LAG samples have been
 *                     collected, then initialise tau and global-minimum tracking.
 *        S_SETUP    — reset per-tau accumulators and set RAM read addresses.
 *        S_FETCH    — one pipeline bubble cycle for synchronous RAM read.
 *        S_ACCUM    — accumulate squared differences over COMP_WINDOW samples.
 *        S_YIN_EVAL — apply YIN threshold test; latch result or advance tau.
 *
 * Threshold
 * ---------
 *   The CMND threshold is THRESH_NUM / 2^THRESH_DEN_SHFT ≈ 0.22,
 *   which is the value recommended in the original YIN paper.
 *
 * Amplitude gate
 * --------------
 *   data_valid is only asserted when the input signal was above AMP_THRESHOLD
 *   during the analysis window, suppressing spurious detections in silence.
 *
 * Ports
 * -----
 *   audio_in     — signed 16-bit sample, presented each time sample_en is high
 *   sample_en    — one-cycle strobe indicating a new sample is available
 *   best_lag_out — detected fundamental period in samples (updated each window)
 *   data_valid   — single-cycle pulse when best_lag_out holds a valid result
 */

module tuner_yin_engine (
    input  logic clk, reset_n,
    input  logic signed [DATA_W-1:0] audio_in,
    input  logic sample_en,
    output logic [11:0] best_lag_out,
    output logic        data_valid
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Local Parameters
    // ----------------------------------------------------------------

    localparam int COMP_WINDOW = 2048;                // samples per difference-function window
    localparam int BUF_BITS    = $clog2(WINDOW_SIZE);
    localparam int ACCUM_W     = 48;                  // accumulator width (avoids overflow)

    // YIN threshold: d'(tau) < THRESH_NUM / 2^THRESH_DEN_SHFT ≈ 0.22
    localparam logic [7:0] THRESH_NUM      = 8'd28;
    localparam logic [3:0] THRESH_DEN_SHFT = 4'd7;

    // ----------------------------------------------------------------
    // 1. Input Pre-Processing  (4-tap box low-pass filter)
    // ----------------------------------------------------------------

    logic signed [DATA_W-1:0] audio_filtered;
    logic signed [DATA_W-1:0] lpf_pipe [3:0];  // shift register of recent samples
    logic [DATA_W-2:0]        abs_val;          // unsigned magnitude for amplitude check

    always_ff @(posedge clk) begin
        if (sample_en) begin
            lpf_pipe[0] <= audio_in;
            lpf_pipe[1] <= lpf_pipe[0];
            lpf_pipe[2] <= lpf_pipe[1];
            lpf_pipe[3] <= lpf_pipe[2];
        end
    end

    // Average of four consecutive samples (divide-by-4 via arithmetic shift)
    assign audio_filtered = (lpf_pipe[0] >>> 2) + (lpf_pipe[1] >>> 2) +
                            (lpf_pipe[2] >>> 2) + (lpf_pipe[3] >>> 2);

    assign abs_val = audio_in[DATA_W-1] ? -audio_in : audio_in;

    // ----------------------------------------------------------------
    // 2. Shadow Buffers  (dual M10K block RAMs, written in lock-step)
    // ----------------------------------------------------------------

    (* ramstyle = "M10K" *) logic signed [DATA_W-1:0] buffer_a [0:WINDOW_SIZE-1];
    (* ramstyle = "M10K" *) logic signed [DATA_W-1:0] buffer_b [0:WINDOW_SIZE-1];

    logic [BUF_BITS-1:0] wptr;         // shared write pointer for both buffers
    logic [13:0]         sample_cnt;   // total samples received since reset
    logic                signal_strong_enough;  // amplitude gate flag

    // ----------------------------------------------------------------
    // 3. State Machine
    // ----------------------------------------------------------------

    typedef enum logic [2:0] {
        S_IDLE,      // wait for enough samples; reset tau and global minimum
        S_SETUP,     // initialise per-tau accumulators and RAM addresses
        S_FETCH,     // bubble cycle for synchronous RAM read latency
        S_ACCUM,     // accumulate squared difference over COMP_WINDOW samples
        S_YIN_EVAL   // apply YIN threshold; latch or advance tau
    } state_t;

    state_t state;

    logic [BUF_BITS-1:0]  addr_a, addr_b, base_ptr;
    logic signed [DATA_W-1:0] sa, sb;             // latched RAM outputs
    logic [11:0]          tau;                    // current lag under test
    logic [11:0]          j;                      // sample index within window
    logic [11:0]          abs_min_lag;            // lag of global minimum so far
    logic [ACCUM_W-1:0]   d_tau;                  // difference function for current tau
    logic [ACCUM_W-1:0]   running_sum_d;          // cumulative sum for CMND normalisation
    logic [ACCUM_W-1:0]   d_best_global;          // smallest d_tau seen this sweep

    // ----------------------------------------------------------------
    // RAM Read Pipeline  (one-cycle synchronous read)
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        sa <= buffer_a[addr_a];
        sb <= buffer_b[addr_b];
    end

    // Squared difference between the two read-back samples
    logic signed [DATA_W:0] diff;
    logic [31:0]             diff_sq;
    assign diff    = $signed(sa) - $signed(sb);
    assign diff_sq = 32'(unsigned'(diff * diff));

    // ----------------------------------------------------------------
    // Main Control Process
    // ----------------------------------------------------------------

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state                <= S_IDLE;
            data_valid           <= 1'b0;
            best_lag_out         <= '0;
            wptr                 <= '0;
            sample_cnt           <= '0;
            signal_strong_enough <= 1'b0;
        end else begin
            data_valid <= 1'b0;  // default: no output this cycle

            // Buffer write and amplitude detection run every sample
            if (sample_en) begin
                buffer_a[wptr] <= audio_filtered;
                buffer_b[wptr] <= audio_filtered;
                wptr           <= wptr + 1'b1;

                if (sample_cnt < 14'(WINDOW_SIZE))
                    sample_cnt <= sample_cnt + 1'b1;

                // Latch amplitude flag if signal is loud enough
                if (abs_val > AMP_THRESHOLD[DATA_W-2:0])
                    signal_strong_enough <= 1'b1;
            end

            case (state)
                // ---- Wait until the buffer holds a full analysis frame ----
                S_IDLE: begin
                    if (sample_cnt >= 14'(COMP_WINDOW + MAX_LAG)) begin
                        tau           <= 12'(MIN_LAG);
                        running_sum_d <= 48'd1;   // seed to avoid divide-by-zero at tau=0
                        d_best_global <= '1;       // initialise to max so any d_tau wins
                        base_ptr      <= wptr - BUF_BITS'(COMP_WINDOW + MAX_LAG);
                        state         <= S_SETUP;
                    end
                end

                // ---- Set up accumulators and RAM addresses for current tau ----
                S_SETUP: begin
                    j      <= '0;
                    d_tau  <= '0;
                    addr_a <= base_ptr;
                    addr_b <= base_ptr + BUF_BITS'(tau);
                    state  <= S_FETCH;
                end

                // ---- Bubble cycle: wait for synchronous RAM read ----
                S_FETCH: state <= S_ACCUM;

                // ---- Accumulate squared differences over the window ----
                S_ACCUM: begin
                    d_tau <= d_tau + ACCUM_W'(diff_sq);

                    if (j == 12'(COMP_WINDOW - 1)) begin
                        state <= S_YIN_EVAL;
                    end else begin
                        j      <= j + 1'b1;
                        addr_a <= addr_a + 1'b1;
                        addr_b <= addr_b + 1'b1;
                    end
                end

                // ---- Apply YIN threshold; decide whether to latch or advance ----
                S_YIN_EVAL: begin
                    running_sum_d <= running_sum_d + d_tau;

                    if ((d_tau * ACCUM_W'(tau)) <
                        ((running_sum_d * THRESH_NUM) >> THRESH_DEN_SHFT)) begin
                        // CMND below threshold: this tau is the fundamental period
                        if (signal_strong_enough) begin
                            best_lag_out <= tau;
                            data_valid   <= 1'b1;
                        end
                        signal_strong_enough <= 1'b0;  // reset for next window
                        state                <= S_IDLE;

                    end else if (tau == 12'(MAX_LAG)) begin
                        // No tau passed the threshold: use the global minimum
                        if (signal_strong_enough) begin
                            best_lag_out <= abs_min_lag;
                            data_valid   <= 1'b1;
                        end
                        signal_strong_enough <= 1'b0;  // reset for next window
                        state                <= S_IDLE;

                    end else begin
                        // Current tau did not pass; track global minimum and advance
                        if (d_tau < d_best_global) begin
                            d_best_global <= d_tau;
                            abs_min_lag   <= tau;
                        end
                        tau   <= tau + 1'b1;
                        state <= S_SETUP;
                    end
                end
            endcase
        end
    end

endmodule