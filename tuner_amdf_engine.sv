module tuner_amdf_engine #(
    parameter DATA_W      = 16,
    parameter MAX_LAG     = 3200,
    parameter WINDOW_SIZE = 8192
)(
    input  logic clk, reset_n,
    input  logic signed [DATA_W-1:0] audio_in,
    input  logic sample_en,
    output logic [11:0] best_lag_out,
    output logic        data_valid
);

    // ---------------------------------------------------------------
    // Algorithm: YIN Cumulative Mean Normalized Difference Function
    // ---------------------------------------------------------------
    //
    // Standard AMDF picks the global minimum of d(tau), which can be a
    // sub-harmonic (2T, 3T) because d(nT) is also near-zero for periodic
    // signals.  YIN solves this with normalization:
    //
    //   d(tau)  = sum_{n} |x(n) - x(n-tau)|          (raw AMDF)
    //   S(tau)  = sum_{j=MIN_LAG}^{tau} d(j)          (cumulative sum)
    //   d'(tau) = tau * d(tau) / S(tau)               (CMNDF)
    //
    // The pitch period is the FIRST tau where d'(tau) < threshold.
    // "First" is the sub-harmonic rejection mechanism: the fundamental
    // always appears at a shorter lag than 2T, 3T, etc., so it is chosen
    // before they get a chance.
    //
    // Division is eliminated by cross-multiplying:
    //   d'(tau) < threshold  <=>  tau * d(tau) < S(tau) * threshold
    //
    // With threshold = 1/8 (THRESHOLD_SHIFT = 3):
    //   tau * d(tau) < S(tau) >> 3
    //
    // ---------------------------------------------------------------
    // Timing notes:
    //
    //   prod_r is computed COMBINATIONALLY in EVALUATE from the fully
    //   accumulated current_sum (which has its final value by the time
    //   EVALUATE is entered).  At 50 MHz a 29×12→41b multiply is well
    //   within a single clock cycle on Cyclone-V DSP blocks.
    //
    //   cumulative_sum is updated AND used in the same EVALUATE cycle:
    //   we form cumsum_new = cumulative_sum + current_sum combinationally,
    //   register it (cumulative_sum <= cumsum_new), and compare against
    //   cumsum_new.  This fixes the off-by-one lag bug where the previous
    //   version compared against S(tau-1) instead of S(tau).
    //
    // ---------------------------------------------------------------
    // Bit widths:
    //   SUM_W    = clog2(WINDOW_SIZE * 65536) = 29  (d(tau) per lag)
    //   CUMSUM_W = SUM_W + LAG_W              = 41  (S(tau))
    //   PROD_W   = SUM_W + LAG_W              = 41  (tau * d(tau))

    localparam BUF_DEPTH       = MAX_LAG + WINDOW_SIZE;
    localparam LAG_W           = $clog2(MAX_LAG + 1);          // 12
    localparam IDX_W           = $clog2(BUF_DEPTH);
    localparam SUM_W           = $clog2(WINDOW_SIZE * 65536);  // 29
    localparam CUMSUM_W        = SUM_W + LAG_W;                // 41
    localparam PROD_W          = SUM_W + LAG_W;                // 41
    localparam SEARCH_INTERVAL = 8192;
    localparam INTV_W          = $clog2(SEARCH_INTERVAL + 1);
    localparam MIN_SEARCH_LAG  = 80;    // well above 96000/1200 Hz guitar max
    localparam THRESHOLD_SHIFT = 4;     // threshold = 1/8 = 0.125

    // ---- Circular buffer ----
    logic signed [DATA_W-1:0] buffer [0:BUF_DEPTH-1];
    logic [IDX_W-1:0] wr_ptr;
    logic [IDX_W-1:0] search_base_ptr;

    // ---- Sample interval counter ----
    logic [INTV_W-1:0] sample_ctr;
    logic              start_search;
    logic              buf_ready;

    // ---- Per-lag AMDF accumulator ----
    logic [SUM_W-1:0] current_sum;

    // ---- YIN state ----
    logic [CUMSUM_W-1:0] cumulative_sum;  // S(tau): running sum of all d(j)
    logic                yin_found;       // true once first dip below threshold seen
    logic [LAG_W-1:0]    yin_lag;         // lag of that first dip

    // ---- Fallback: raw global minimum (used if YIN finds nothing) ----
    logic [SUM_W-1:0]  min_sum;
    logic [LAG_W-1:0]  best_lag_internal;

    // ---- Search control ----
    logic [LAG_W-1:0]  current_lag;
    logic [IDX_W-1:0]  window_idx;

    // ---- Pipelined RAM signals ----
    logic [IDX_W-1:0]         addr_v0, addr_vlag;
    logic signed [DATA_W-1:0] v0, vLag;
    logic signed [DATA_W:0]   diff_signed_r;
    logic [DATA_W-1:0]        diff_r;

    // ---- Combinational YIN signals (evaluated in EVALUATE state) ----
    // These are wires; the always_ff block reads them the same cycle.
    logic [PROD_W-1:0]   yin_prod;      // tau * d(tau)
    logic [CUMSUM_W-1:0] cumsum_new;    // S(tau) including this lag

    assign yin_prod   = PROD_W'(current_sum) * PROD_W'(current_lag);
    assign cumsum_new = cumulative_sum + CUMSUM_W'(current_sum);

    function automatic logic [IDX_W-1:0] circ(
        input logic [IDX_W-1:0] base,
        input logic [IDX_W-1:0] offset
    );
        circ = (base >= offset) ? (base - offset)
                                : (IDX_W'(BUF_DEPTH) + base - offset);
    endfunction

    typedef enum logic [2:0] {IDLE, ADDR_SETUP, ACCUMULATE, EVALUATE} state_t;
    state_t state;

    // ---- Continuous buffer write ----
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            wr_ptr    <= '0;
            buf_ready <= 1'b0;
        end else if (sample_en) begin
            buffer[wr_ptr] <= audio_in;
            if (wr_ptr == IDX_W'(BUF_DEPTH - 1)) begin
                wr_ptr    <= '0;
                buf_ready <= 1'b1;
            end else begin
                wr_ptr <= wr_ptr + 1'b1;
            end
        end
    end

    // ---- Interval counter ----
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            sample_ctr   <= '0;
            start_search <= 1'b0;
        end else begin
            start_search <= 1'b0;
            if (sample_en) begin
                if (sample_ctr == INTV_W'(SEARCH_INTERVAL - 1)) begin
                    sample_ctr   <= '0;
                    start_search <= 1'b1;
                end else begin
                    sample_ctr <= sample_ctr + 1'b1;
                end
            end
        end
    end

    // ---- RAM read ----
    always_ff @(posedge clk) begin
        v0   <= buffer[addr_v0];
        vLag <= buffer[addr_vlag];
    end

    // ---- Registered diff ----
    always_ff @(posedge clk) begin
        diff_signed_r <= signed'({1'b0, v0}) - signed'({1'b0, vLag});
        diff_r        <= diff_signed_r[DATA_W] ? DATA_W'(-diff_signed_r)
                                               : DATA_W'(diff_signed_r);
    end

    // ---- Main FSM ----
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            state             <= IDLE;
            search_base_ptr   <= '0;
            best_lag_out      <= '0;
            best_lag_internal <= LAG_W'(MIN_SEARCH_LAG);
            data_valid        <= 1'b0;
            current_lag       <= '0;
            window_idx        <= '0;
            current_sum       <= '0;
            min_sum           <= '1;
            cumulative_sum    <= '0;
            yin_found         <= 1'b0;
            yin_lag           <= '0;
            addr_v0           <= '0;
            addr_vlag         <= '0;
        end else begin
            case (state)

                IDLE: begin
                    data_valid <= 1'b0;
                    if (start_search && buf_ready) begin
                        search_base_ptr   <= wr_ptr;
                        current_lag       <= LAG_W'(MIN_SEARCH_LAG);
                        window_idx        <= '0;
                        current_sum       <= '0;
                        min_sum           <= '1;
                        cumulative_sum    <= '0;
                        yin_found         <= 1'b0;
                        yin_lag           <= '0;
                        best_lag_internal <= LAG_W'(MIN_SEARCH_LAG);

                        addr_v0   <= circ(wr_ptr, IDX_W'(0));
                        addr_vlag <= circ(wr_ptr, IDX_W'(MIN_SEARCH_LAG));
                        state     <= ADDR_SETUP;
                    end
                end

                ADDR_SETUP: begin
                    addr_v0    <= circ(search_base_ptr, IDX_W'(1));
                    addr_vlag  <= circ(search_base_ptr, IDX_W'(1) + IDX_W'(current_lag));
                    window_idx <= IDX_W'(1);
                    state      <= ACCUMULATE;
                end

                ACCUMULATE: begin
                    current_sum <= current_sum + SUM_W'(diff_r);

                    addr_v0   <= circ(search_base_ptr, window_idx + 1'b1);
                    addr_vlag <= circ(search_base_ptr, (window_idx + 1'b1) + IDX_W'(current_lag));

                    if (window_idx == IDX_W'(WINDOW_SIZE + 1))
                        state <= EVALUATE;
                    else
                        window_idx <= window_idx + 1'b1;
                end

                EVALUATE: begin
                    // ---- Update S(tau) ----
                    // cumsum_new = cumulative_sum + current_sum is computed
                    // combinationally above and registered here.  We compare
                    // against cumsum_new (not the stale cumulative_sum) so
                    // the YIN criterion uses S(tau) inclusive of this lag.
                    cumulative_sum <= cumsum_new;

                    // ---- Update raw global minimum (fallback) ----
                    if (current_sum < min_sum) begin
                        min_sum           <= current_sum;
                        best_lag_internal <= current_lag;
                    end

                    // ---- YIN threshold test ----
                    //
                    //   Accept the FIRST tau where d'(tau) < threshold:
                    //     tau * d(tau)  <  S(tau) >> THRESHOLD_SHIFT
                    //     yin_prod      <  cumsum_new >> THRESHOLD_SHIFT
                    //
                    //   Both sides are computed combinationally from the fully
                    //   settled current_sum (registered at end of ACCUMULATE)
                    //   and cumulative_sum (stale-read fixed by using cumsum_new).
                    //
                    //   "First" is the sub-harmonic rejection:
                    //   Once yin_found is true we stop updating yin_lag.
                    //   The fundamental at lag T is always encountered before
                    //   its sub-harmonics at 2T, 3T, so it wins naturally.
                    if (!yin_found &&
                            cumsum_new > 0 &&
                            yin_prod < (PROD_W'(cumsum_new) >> THRESHOLD_SHIFT)) begin
                        yin_found <= 1'b1;
                        yin_lag   <= current_lag;
                    end

                    if (current_lag == LAG_W'(MAX_LAG - 1)) begin
                        // Output the YIN result, or fall back to raw minimum
                        // if the signal never crossed the threshold (silence /
                        // heavy noise — the fallback value is don't-care in
                        // tuner mode but avoids emitting lag=0).
                        best_lag_out <= yin_found ? 12'(yin_lag)
                                                  : 12'(best_lag_internal);
                        data_valid   <= 1'b1;
                        state        <= IDLE;

                    end else begin
                        current_lag <= current_lag + 1'b1;
                        window_idx  <= '0;
                        current_sum <= '0;

                        addr_v0   <= circ(search_base_ptr, IDX_W'(0));
                        addr_vlag <= circ(search_base_ptr, IDX_W'(current_lag + 1));
                        state     <= ADDR_SETUP;
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule