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

    localparam BUF_DEPTH       = MAX_LAG + WINDOW_SIZE;
    localparam LAG_W           = $clog2(MAX_LAG + 1);
    localparam IDX_W           = $clog2(BUF_DEPTH);
    localparam SUM_W           = $clog2(WINDOW_SIZE * 65536);
    localparam SEARCH_INTERVAL = 8192;
    localparam INTV_W          = $clog2(SEARCH_INTERVAL + 1);
    localparam MIN_SEARCH_LAG  = 80;    // 96000/80  = 1200 Hz ceiling (safe margin)

    // Sub-harmonic rejection:
    // During the scan we track TWO minimums:
    //   - global:    best over [MIN_SEARCH_LAG .. MAX_LAG-1]
    //   - lo:        best over [MIN_SEARCH_LAG .. HALF_MAX_LAG]
    //
    // HALF_MAX_LAG = 1600 → 96000/1600 = 60 Hz, covers all 6 guitar strings.
    //
    // At the end we prefer `best_lag_lo` unless the global minimum is more than
    // 2^SUBHARM_SHIFT (= 4×) better.  A sub-harmonic at 2T is typically only
    // 10–50% lower than T, so 4× catches it; genuine 30 Hz (lag=3200, outside
    // lo range) has an AMDF much lower than anything in lo range so global wins.
    localparam HALF_MAX_LAG  = MAX_LAG / 2;   // 1600
    localparam SUBHARM_SHIFT = 2;             // prefer lo unless global is 4× better

    // ---- Circular buffer ----
    logic signed [DATA_W-1:0] buffer [0:BUF_DEPTH-1];
    logic [IDX_W-1:0] wr_ptr;
    logic [IDX_W-1:0] search_base_ptr;

    // ---- Sample interval counter ----
    logic [INTV_W-1:0] sample_ctr;
    logic              start_search;
    logic              buf_ready;

    // ---- Search state ----
    logic [SUM_W-1:0]  current_sum;
    logic [SUM_W-1:0]  min_sum;           // global minimum AMDF value
    logic [SUM_W-1:0]  min_sum_lo;        // lo-range minimum AMDF value
    logic [LAG_W-1:0]  current_lag;
    logic [IDX_W-1:0]  window_idx;
    logic [LAG_W-1:0]  best_lag_internal; // lag of global minimum
    logic [LAG_W-1:0]  best_lag_lo;       // lag of lo-range minimum

    // ---- Pipelined RAM signals ----
    logic [IDX_W-1:0]         addr_v0, addr_vlag;
    logic signed [DATA_W-1:0] v0, vLag;
    logic signed [DATA_W:0]   diff_signed_r;
    logic [DATA_W-1:0]        diff_r;

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

    // ---- RAM read (1-cycle latency) ----
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
            best_lag_internal <= '0;
            best_lag_lo       <= LAG_W'(MIN_SEARCH_LAG);
            data_valid        <= 1'b0;
            current_lag       <= '0;
            window_idx        <= '0;
            current_sum       <= '0;
            min_sum           <= '1;
            min_sum_lo        <= '1;
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
                        min_sum_lo        <= '1;
                        best_lag_internal <= LAG_W'(MIN_SEARCH_LAG);
                        best_lag_lo       <= LAG_W'(MIN_SEARCH_LAG);

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

                    if (window_idx == IDX_W'(WINDOW_SIZE + 1)) begin
                        state <= EVALUATE;
                    end else begin
                        window_idx <= window_idx + 1'b1;
                    end
                end

                EVALUATE: begin
                    // Always update global minimum
                    if (current_sum < min_sum) begin
                        min_sum           <= current_sum;
                        best_lag_internal <= current_lag;
                    end

                    // Update lo-range minimum (covers 60–1200 Hz displayed,
                    // i.e. all 6 standard guitar strings)
                    if (current_lag <= LAG_W'(HALF_MAX_LAG) &&
                            current_sum < min_sum_lo) begin
                        min_sum_lo  <= current_sum;
                        best_lag_lo <= current_lag;
                    end

                    if (current_lag == LAG_W'(MAX_LAG - 1)) begin
                        // Sub-harmonic rejection:
                        // Prefer best_lag_lo (higher freq, truer fundamental) unless
                        // the global minimum is 4× better — which only happens for
                        // genuine sub-bass (<60 Hz) whose lag falls outside lo range.
                        if ((min_sum_lo >> SUBHARM_SHIFT) <= min_sum)
                            best_lag_out <= 12'(best_lag_lo);
                        else
                            best_lag_out <= 12'(best_lag_internal);

                        data_valid <= 1'b1;
                        state      <= IDLE;
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