/*
 * tuner_yin_engine.sv
 *
 * Polyphony-aware monophonic pitch detector based on the YIN algorithm,
 * with parabolic interpolation around the cumulative-mean-normalised
 * difference (CMND) minimum to give sub-sample lag resolution.
 *
 * Pipeline overview
 * -----------------
 *   1. Input pre-processing
 *        Four-tap FIR low-pass filter attenuates HF content before
 *        pitch analysis, reducing false detections on harmonics.
 *
 *   2. Shadow buffers
 *        Incoming filtered samples are written simultaneously into two
 *        M10K block-RAM buffers (buffer_a / buffer_b).  Reading both
 *        from the same write pointer but offset by the current lag tau
 *        lets the difference function be computed without a separate
 *        read-back phase.
 *
 *   3. State machine
 *        S_IDLE       — wait until COMP_WINDOW + MAX_LAG samples have
 *                       been collected, then init tau and global-min
 *                       tracking.
 *        S_SETUP      — reset per-tau accumulators and RAM addresses.
 *        S_FETCH      — one bubble cycle for synchronous RAM read.
 *        S_ACCUM      — accumulate squared diffs over COMP_WINDOW
 *                       samples.
 *        S_YIN_EVAL   — apply YIN threshold; on first hit, save
 *                       (d_prev, d_min, tau_min) and advance tau by 1
 *                       to capture d_next for parabolic refinement.
 *                       On the refinement pass, kick off the divider.
 *        S_REFINE_DIV — iterative subtract-and-count divider that
 *                       computes the parabolic offset in Q4 format.
 *                       Up to 9 cycles.
 *
 * Parabolic refinement
 * --------------------
 *   At a true minimum the CMND is locally well-fit by a parabola, so
 *     delta = (d_prev - d_next) / (2 · (d_prev - 2·d_min + d_next))
 *   gives a vertex offset in [-0.5, +0.5].  Computed as Q4:
 *     offset_q4 = (d_prev - d_next) · 8 / (d_prev + d_next - 2·d_min)
 *   and added to {tau_min, 4'b0} to produce a 16-bit Q12.4 lag.
 *   Result is sub-cent at E2, ~0.7 cent at E4 — tuner-grade.
 *
 *   Edge cases that fall back to integer-only output:
 *     • threshold met at the very first lag (tau == MIN_LAG) — d_prev
 *       is not yet captured.
 *     • threshold met at the very last lag (tau == MAX_LAG) — there is
 *       no tau+1 to evaluate.
 *     • no tau passed the threshold; abs_min_lag is used directly.
 *
 * Threshold
 * ---------
 *   CMND threshold = THRESH_NUM / 2^THRESH_DEN_SHFT ≈ 0.22 (the value
 *   recommended in the original YIN paper).
 *
 * Amplitude gate
 * --------------
 *   data_valid only fires when the input was above AMP_THRESHOLD
 *   somewhere in the analysis window — suppresses spurious detections
 *   in silence.
 *
 * Ports
 * -----
 *   audio_in        — signed 16-bit sample, valid when sample_en is high
 *   sample_en       — one-cycle strobe per new sample
 *   best_lag_q4_out — fundamental period in Q12.4 samples (12 integer
 *                     + 4 fractional bits).  Integer part is the
 *                     coarse lag; fractional bits come from parabolic
 *                     refinement.
 *   data_valid      — single-cycle pulse when best_lag_q4_out updates
 */

module tuner_yin_engine (
    input  logic clk, reset_n,
    input  logic signed [DATA_W-1:0] audio_in,
    input  logic sample_en,
    output logic [15:0] best_lag_q4_out,
    output logic        data_valid
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Local Parameters
    // ----------------------------------------------------------------

    localparam int COMP_WINDOW = 2048;
    localparam int BUF_BITS    = $clog2(WINDOW_SIZE);
    localparam int ACCUM_W     = 48;

    localparam logic [7:0] THRESH_NUM      = 8'd28;
    localparam logic [3:0] THRESH_DEN_SHFT = 4'd7;

    // ----------------------------------------------------------------
    // 1. Input Pre-Processing  (4-tap box low-pass filter)
    // ----------------------------------------------------------------

    logic signed [DATA_W-1:0] audio_filtered;
    logic signed [DATA_W-1:0] lpf_pipe [3:0];
    logic [DATA_W-2:0]        abs_val;

    always_ff @(posedge clk) begin
        if (sample_en) begin
            lpf_pipe[0] <= audio_in;
            lpf_pipe[1] <= lpf_pipe[0];
            lpf_pipe[2] <= lpf_pipe[1];
            lpf_pipe[3] <= lpf_pipe[2];
        end
    end

    assign audio_filtered = (lpf_pipe[0] >>> 2) + (lpf_pipe[1] >>> 2) +
                            (lpf_pipe[2] >>> 2) + (lpf_pipe[3] >>> 2);

    assign abs_val = audio_in[DATA_W-1] ? -audio_in : audio_in;

    // ----------------------------------------------------------------
    // 2. Shadow Buffers
    // ----------------------------------------------------------------

    (* ramstyle = "M10K" *) logic signed [DATA_W-1:0] buffer_a [0:WINDOW_SIZE-1];
    (* ramstyle = "M10K" *) logic signed [DATA_W-1:0] buffer_b [0:WINDOW_SIZE-1];

    logic [BUF_BITS-1:0] wptr;
    logic [13:0]         sample_cnt;
    logic                signal_strong_enough;

    // ----------------------------------------------------------------
    // 3. State Machine
    // ----------------------------------------------------------------

    typedef enum logic [2:0] {
        S_IDLE,
        S_SETUP,
        S_FETCH,
        S_ACCUM,
        S_YIN_EVAL,
        S_REFINE_DIV
    } state_t;

    state_t state;

    logic [BUF_BITS-1:0]      addr_a, addr_b, base_ptr;
    logic signed [DATA_W-1:0] sa, sb;
    logic [11:0]              tau;
    logic [11:0]              j;
    logic [11:0]              abs_min_lag;
    logic [ACCUM_W-1:0]       d_tau;
    logic [ACCUM_W-1:0]       running_sum_d;
    logic [ACCUM_W-1:0]       d_best_global;

    // ----------------------------------------------------------------
    // Parabolic Refinement Storage
    // ----------------------------------------------------------------

    logic [ACCUM_W-1:0] d_prev_r;     // d at tau_min - 1
    logic [ACCUM_W-1:0] d_min_r;      // d at tau_min
    logic [ACCUM_W-1:0] d_next_r;     // d at tau_min + 1
    logic [11:0]        tau_min_r;
    logic               refining;

    // d_next_w lets the combinational refinement operands "see" the
    // about-to-be-latched d_next on the same edge S_YIN_EVAL fires
    // with refining=1, so we can latch sub_acc with the right value.
    logic [ACCUM_W-1:0] d_next_w;
    assign d_next_w = (state == S_YIN_EVAL && refining) ? d_tau : d_next_r;

    // Truncate the three d values to 32-bit operands.  If any has
    // non-zero bits in [47:32], shift everyone right by 16 to fit;
    // otherwise use the lower 32 bits as-is.  Same shift for all
    // three preserves the ratio that the parabolic vertex needs.
    logic [4:0]  d_shamt;
    logic [31:0] d_prev_t, d_min_t, d_next_t;
    always_comb begin
        if (d_prev_r[47:32] != '0 || d_min_r[47:32] != '0 || d_next_w[47:32] != '0)
            d_shamt = 5'd16;
        else
            d_shamt = 5'd0;
    end
    assign d_prev_t = 32'(d_prev_r >> d_shamt);
    assign d_min_t  = 32'(d_min_r  >> d_shamt);
    assign d_next_t = 32'(d_next_w >> d_shamt);

    logic signed [32:0] para_num;     // d_prev_t - d_next_t
    logic        [33:0] para_den;     // d_prev_t + d_next_t - 2·d_min_t  (≥ 0 at a min)
    logic        [35:0] num_abs_8;    // |para_num| · 8
    assign para_num  = $signed({1'b0, d_prev_t}) - $signed({1'b0, d_next_t});
    assign para_den  = ({2'b0, d_prev_t}) + ({2'b0, d_next_t}) - ({1'b0, d_min_t, 1'b0});
    assign num_abs_8 = para_num[32] ? ({{3{1'b0}}, $unsigned(-para_num)} << 3)
                                    : ({{3{1'b0}}, $unsigned( para_num)} << 3);

    // Iterative subtract-and-count divider state
    logic [35:0] sub_acc;
    logic [3:0]  sub_cnt;

    // Final refined Q12.4 lag (combinational on tau_min_r, sub_cnt,
    // and the sign of para_num — para_num stays stable in S_REFINE_DIV
    // since d_next_w == d_next_r there).
    logic signed [4:0]  offset_q4;
    logic        [15:0] refined_q4;
    assign offset_q4  = para_num[32] ? -$signed({1'b0, sub_cnt})
                                     :  $signed({1'b0, sub_cnt});
    assign refined_q4 = {tau_min_r, 4'b0} + {{11{offset_q4[4]}}, offset_q4};

    // ----------------------------------------------------------------
    // RAM Read Pipeline
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        sa <= buffer_a[addr_a];
        sb <= buffer_b[addr_b];
    end

    logic signed [DATA_W:0] diff;
    logic [31:0]            diff_sq;
    assign diff    = $signed(sa) - $signed(sb);
    assign diff_sq = 32'(unsigned'(diff * diff));

    // ----------------------------------------------------------------
    // Main Control Process
    // ----------------------------------------------------------------

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state                <= S_IDLE;
            data_valid           <= 1'b0;
            best_lag_q4_out      <= '0;
            wptr                 <= '0;
            sample_cnt           <= '0;
            signal_strong_enough <= 1'b0;
            refining             <= 1'b0;
        end else begin
            data_valid <= 1'b0;

            if (sample_en) begin
                buffer_a[wptr] <= audio_filtered;
                buffer_b[wptr] <= audio_filtered;
                wptr           <= wptr + 1'b1;

                if (sample_cnt < 14'(WINDOW_SIZE))
                    sample_cnt <= sample_cnt + 1'b1;

                if (abs_val > AMP_THRESHOLD[DATA_W-2:0])
                    signal_strong_enough <= 1'b1;
            end

            case (state)
                S_IDLE: begin
                    if (sample_cnt >= 14'(COMP_WINDOW + MAX_LAG)) begin
                        tau           <= 12'(MIN_LAG);
                        running_sum_d <= 48'd1;
                        d_best_global <= '1;
                        base_ptr      <= wptr - BUF_BITS'(COMP_WINDOW + MAX_LAG);
                        refining      <= 1'b0;
                        state         <= S_SETUP;
                    end
                end

                S_SETUP: begin
                    j      <= '0;
                    d_tau  <= '0;
                    addr_a <= base_ptr;
                    addr_b <= base_ptr + BUF_BITS'(tau);
                    state  <= S_FETCH;
                end

                S_FETCH: state <= S_ACCUM;

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

                S_YIN_EVAL: begin
                    running_sum_d <= running_sum_d + d_tau;

                    if (refining) begin
                        // d_tau is d_next.  Latch it and kick the
                        // sub-and-count divider with num_abs_8 (which
                        // already reflects d_next via d_next_w).
                        d_next_r <= d_tau;
                        sub_acc  <= num_abs_8;
                        sub_cnt  <= '0;
                        state    <= S_REFINE_DIV;

                    end else if ((d_tau * ACCUM_W'(tau)) <
                                 ((running_sum_d * THRESH_NUM) >> THRESH_DEN_SHFT)) begin
                        // First minimum.
                        if (signal_strong_enough) begin
                            if (tau == 12'(MIN_LAG) || tau == 12'(MAX_LAG)) begin
                                // No room to refine — emit integer Q12.4.
                                best_lag_q4_out      <= {tau, 4'b0};
                                data_valid           <= 1'b1;
                                signal_strong_enough <= 1'b0;
                                state                <= S_IDLE;
                            end else begin
                                // d_prev_r already holds d at tau-1.
                                // Save d_min and tau_min, advance tau
                                // to capture d_next.
                                d_min_r   <= d_tau;
                                tau_min_r <= tau;
                                refining  <= 1'b1;
                                tau       <= tau + 1'b1;
                                state     <= S_SETUP;
                            end
                        end else begin
                            signal_strong_enough <= 1'b0;
                            state                <= S_IDLE;
                        end

                    end else if (tau == 12'(MAX_LAG)) begin
                        // No tau passed: fall back to integer global minimum.
                        if (signal_strong_enough) begin
                            best_lag_q4_out <= {abs_min_lag, 4'b0};
                            data_valid      <= 1'b1;
                        end
                        signal_strong_enough <= 1'b0;
                        state                <= S_IDLE;

                    end else begin
                        d_prev_r <= d_tau;
                        if (d_tau < d_best_global) begin
                            d_best_global <= d_tau;
                            abs_min_lag   <= tau;
                        end
                        tau   <= tau + 1'b1;
                        state <= S_SETUP;
                    end
                end

                S_REFINE_DIV: begin
                    // Subtract para_den from sub_acc up to 8 times.
                    if (sub_acc >= {2'b0, para_den} && sub_cnt < 4'd8) begin
                        sub_acc <= sub_acc - {2'b0, para_den};
                        sub_cnt <= sub_cnt + 1'b1;
                    end else begin
                        if (signal_strong_enough) begin
                            best_lag_q4_out <= refined_q4;
                            data_valid      <= 1'b1;
                        end
                        signal_strong_enough <= 1'b0;
                        refining             <= 1'b0;
                        state                <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
