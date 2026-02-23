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

    localparam BUF_DEPTH      = MAX_LAG + WINDOW_SIZE;
    localparam LAG_W          = $clog2(MAX_LAG + 1);
    localparam IDX_W          = $clog2(BUF_DEPTH);
    localparam SUM_W          = $clog2(WINDOW_SIZE * 65536);
    localparam SEARCH_INTERVAL = 8192;
    localparam INTV_W         = $clog2(SEARCH_INTERVAL + 1);
    localparam MIN_SEARCH_LAG = 80;

    // Range boundaries — chosen so guitar string fundamentals are separated
    // from their own sub-harmonics:
    //
    //   hi  [80..500]:  High E(291), B(389), G(490) fundamentals
    //                   2T of those would be 582+, safely in mid range
    //   mid [501..1600]: D(653), A(873), Low E(1170) fundamentals
    //   global:          fallback for genuine sub-bass
    //
    // Cascade preference: prefer hi unless mid AMDF is more than CASCADE_SHIFT
    // times better (i.e. hi is spurious noise). Then prefer mid over global
    // with same check.
    localparam HI_LAG_MAX     = 500;
    localparam MID_LAG_MAX    = 1600;
    localparam CASCADE_SHIFT  = 1;   // 2^1 = 2× threshold; increase if low strings
                                     // wrongly trigger hi range

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

    // Three range trackers
    logic [SUM_W-1:0]  min_sum;         // global
    logic [SUM_W-1:0]  min_sum_hi;      // hi range  [80..500]
    logic [SUM_W-1:0]  min_sum_mid;     // mid range [501..1600]

    logic [LAG_W-1:0]  current_lag;
    logic [IDX_W-1:0]  window_idx;

    logic [LAG_W-1:0]  best_lag_internal;
    logic [LAG_W-1:0]  best_lag_hi;
    logic [LAG_W-1:0]  best_lag_mid;

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
            best_lag_hi       <= LAG_W'(MIN_SEARCH_LAG);
            best_lag_mid      <= LAG_W'(MIN_SEARCH_LAG);
            data_valid        <= 1'b0;
            current_lag       <= '0;
            window_idx        <= '0;
            current_sum       <= '0;
            min_sum           <= '1;
            min_sum_hi        <= '1;
            min_sum_mid       <= '1;
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
                        min_sum_hi        <= '1;
                        min_sum_mid       <= '1;
                        best_lag_internal <= LAG_W'(MIN_SEARCH_LAG);
                        best_lag_hi       <= LAG_W'(MIN_SEARCH_LAG);
                        best_lag_mid      <= LAG_W'(MIN_SEARCH_LAG);

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
                    // Global minimum
                    if (current_sum < min_sum) begin
                        min_sum           <= current_sum;
                        best_lag_internal <= current_lag;
                    end

                    // Hi-range minimum [MIN_SEARCH_LAG .. HI_LAG_MAX]
                    // Captures High E (291), B (389), G (490)
                    // Their 2T sub-harmonics are 582+ so cannot appear here
                    if (current_lag <= LAG_W'(HI_LAG_MAX) &&
                            current_sum < min_sum_hi) begin
                        min_sum_hi  <= current_sum;
                        best_lag_hi <= current_lag;
                    end

                    // Mid-range minimum [HI_LAG_MAX+1 .. MID_LAG_MAX]
                    // Captures D (653), A (873), Low E (1170)
                    // Also contains sub-harmonics of high strings, but cascade
                    // logic below suppresses those by preferring hi-range
                    if (current_lag > LAG_W'(HI_LAG_MAX) &&
                            current_lag <= LAG_W'(MID_LAG_MAX) &&
                            current_sum < min_sum_mid) begin
                        min_sum_mid  <= current_sum;
                        best_lag_mid <= current_lag;
                    end

                    if (current_lag == LAG_W'(MAX_LAG - 1)) begin

                        // Cascade preference: hi > mid > global
                        //
                        // Use hi_range if its best AMDF is within CASCADE_SHIFT
                        // times the mid_range best. When a low string is played,
                        // hi_range has no good match (min_sum_hi stays near '1)
                        // while min_sum_mid is small, so the shift easily separates
                        // them and we fall through to mid_range.
                        //
                        // When B or High E is played, both hi_range (fundamental)
                        // and mid_range (sub-harmonic) have low AMDF, but hi_range
                        // is within 2× of mid_range, so we correctly pick hi_range.
                        if (min_sum_hi <= (min_sum_mid << CASCADE_SHIFT))
                            best_lag_out <= 12'(best_lag_hi);
                        else if (min_sum_mid <= (min_sum << CASCADE_SHIFT))
                            best_lag_out <= 12'(best_lag_mid);
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