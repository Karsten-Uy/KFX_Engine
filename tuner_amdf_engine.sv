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

    // Range boundaries and sub-harmonic relationships (at 96 kHz):
    //
    //   hi  [80..500]:  High E (291), B (389), G (490) fundamentals
    //                   Their half-periods (146, 195, 245) are ALSO in hi range.
    //                   Their 2T sub-harmonics (582, 778, 980) are in mid range.
    //
    //   mid [501..1600]: D (654), A (873), Low E (1165) fundamentals
    //                   D/A half-periods (327, 436) are in hi range.
    //                   D sub-harmonic (1308) is in mid range.
    //                   A/Low-E sub-harmonics (1746, 2330) are in global range.
    //
    //   global:         fallback; no guitar fundamental lives here.
    //
    // ---------------------------------------------------------------
    // Hi-range tracker — plain minimum, NO hysteresis:
    //   Half-periods of hi-range strings (e.g. G at lag 245) appear in the
    //   search before their fundamentals (G at lag 490).  For guitar, AMDF at
    //   the fundamental is clearly lower than at T/2, so simple minimum
    //   tracking naturally picks the fundamental.  Adding hysteresis here was
    //   wrong: it prevented the fundamental from displacing the half-period
    //   when the improvement was less than 25%, causing G to lock onto lag 245
    //   (392 Hz instead of 196 Hz).
    //
    // Mid-range tracker — 25% hysteresis:
    //   D's sub-harmonic (lag ~1308) is also inside mid range and appears after
    //   the fundamental (lag ~654).  The 25% bar stops it from displacing the
    //   shorter (fundamental) lag when the two AMDF scores are close.
    //
    // HI_MID cascade — 3× threshold:
    //   hi wins if  min_sum_hi <= 3 × min_sum_mid
    //   3× is the sweet spot between two failure modes:
    //     • Too tight (2×): High E/B sub-harmonics in mid range are only
    //       ~1.5–2× worse than the hi fundamental → sub-harmonic wins ✗
    //     • Too loose (4×): D/A half-periods in hi range are 5–10× worse
    //       than the mid fundamental, but 4× lets them slip through ✗
    //   At 3×: hi strings still win (their mid sub-harmonic is < 3× worse),
    //   while D/A correctly fall through (their hi half-period is > 3× worse).
    //   Expressed as (mid << 1) + mid to avoid a hardware multiplier.
    //
    // MID_GLOB cascade — 8× threshold (shift by 3):
    //   Low E / A sub-harmonics in global range can be 3–4× lower than the
    //   mid fundamental.  8× ensures mid always wins.
    localparam HI_LAG_MAX             = 500;
    localparam MID_LAG_MAX            = 1600;
    localparam MID_GLOB_CASCADE_SHIFT = 3;   // 8× — mid vs global

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
                    // Global minimum — plain minimum, no hysteresis
                    if (current_sum < min_sum) begin
                        min_sum           <= current_sum;
                        best_lag_internal <= current_lag;
                    end

                    // Hi-range minimum [MIN_SEARCH_LAG .. HI_LAG_MAX]
                    // Captures High E (291), B (389), G (490).
                    //
                    // Plain minimum — NO hysteresis here.
                    // Half-periods of these strings (146, 195, 245) also fall
                    // in hi range and are encountered first.  For guitar, the
                    // AMDF at the true fundamental is clearly lower than at T/2,
                    // so simple minimum tracking naturally picks the right lag.
                    // Hysteresis was previously blocking the fundamental (e.g. G
                    // at 490) from beating its half-period (245) when the margin
                    // was < 25%, causing G to read an octave too high.
                    if (current_lag <= LAG_W'(HI_LAG_MAX) &&
                            current_sum < min_sum_hi) begin
                        min_sum_hi  <= current_sum;
                        best_lag_hi <= current_lag;
                    end

                    // Mid-range minimum [HI_LAG_MAX+1 .. MID_LAG_MAX]
                    // Captures D (654), A (873), Low E (1165).
                    //
                    // 25% hysteresis: a later (longer-lag) candidate must beat
                    // the current best by > 25% to displace it.  This prevents
                    // D's in-range sub-harmonic (lag ~1308) from displacing the
                    // fundamental (lag ~654) when both scores are low.
                    if (current_lag > LAG_W'(HI_LAG_MAX) &&
                            current_lag <= LAG_W'(MID_LAG_MAX) &&
                            current_sum < (min_sum_mid - (min_sum_mid >> 2))) begin
                        min_sum_mid  <= current_sum;
                        best_lag_mid <= current_lag;
                    end

                    if (current_lag == LAG_W'(MAX_LAG - 1)) begin

                        // Cascade preference: hi > mid > global
                        //
                        // HI_MID: 3× threshold  →  (mid << 1) + mid
                        //   Hi wins if min_sum_hi <= 3 × min_sum_mid.
                        //   High E/B/G: their mid sub-harmonics are 1.5–2.5× worse
                        //   than the hi fundamental → comfortably within 3× → hi wins.
                        //   D/A: their hi half-periods are 5–10× worse than the mid
                        //   fundamental → exceed 3× → fall through to mid.
                        //   (Cannot use a simple shift for 3×; expressed as shift+add.)
                        //
                        // MID_GLOB: 8× threshold  →  (min_sum << MID_GLOB_CASCADE_SHIFT)
                        //   Mid wins if min_sum_mid <= 8 × min_sum_global.
                        //   Low E / A sub-harmonics in global range can be 3–4× lower
                        //   than the mid fundamental, so 8× ensures mid always wins.
                        if (min_sum_hi <= (min_sum_mid << 1) + min_sum_mid)
                            best_lag_out <= 12'(best_lag_hi);
                        else if (min_sum_mid <= (min_sum << MID_GLOB_CASCADE_SHIFT))
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