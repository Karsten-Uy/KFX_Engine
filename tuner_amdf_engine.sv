module tuner_amdf_engine #(
    parameter DATA_W      = 16,
    parameter MAX_LAG     = 2400,
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

    // ---- Circular buffer ----
    logic signed [DATA_W-1:0] buffer [0:BUF_DEPTH-1];
    logic [IDX_W-1:0] wr_ptr;
    logic [IDX_W-1:0] search_base_ptr;

    // ---- Sample interval counter ----
    logic [INTV_W-1:0] sample_ctr;
    logic              start_search;
    logic              buf_ready;       // True once buffer has been filled once

    // ---- Search state ----
    logic [SUM_W-1:0]  current_sum;
    logic [SUM_W-1:0]  min_sum;
    logic [LAG_W-1:0]  current_lag;
    logic [IDX_W-1:0]  window_idx;
    logic [LAG_W-1:0]  best_lag_internal;

    // ---- Pipelined RAM signals ----
    logic [IDX_W-1:0]         addr_v0, addr_vlag;
    logic signed [DATA_W-1:0] v0, vLag;

    // Registered diff (fixes timing: removes combinatorial path from RAM output to sum)
    logic signed [DATA_W:0]   diff_signed_r;
    logic [DATA_W-1:0]        diff_r;

    function automatic logic [IDX_W-1:0] circ(
        input logic [IDX_W-1:0] base,
        input logic [IDX_W-1:0] offset
    );
        circ = (base >= offset) ? (base - offset)
                                : (IDX_W'(BUF_DEPTH) + base - offset);
    endfunction

    // States: ADDR_SETUP is the 1-cycle drain that lets RAM output settle
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
                buf_ready <= 1'b1;   // Buffer has been filled at least once
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

    // ---- Registered diff (pipeline stage 2 — fixes timing) ----
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
            data_valid        <= 1'b0;
            current_lag       <= '0;
            window_idx        <= '0;
            current_sum       <= '0;
            min_sum           <= '1;
            addr_v0           <= '0;
            addr_vlag         <= '0;
        end else begin
            case (state)

                IDLE: begin
                    data_valid <= 1'b0;
                    if (start_search && buf_ready) begin
                        search_base_ptr <= wr_ptr;
                        current_lag     <= LAG_W'(40);
                        window_idx      <= '0;
                        current_sum     <= '0;
                        min_sum         <= '1;

                        // Set addresses for index 0
                        addr_v0   <= circ(wr_ptr, IDX_W'(0));
                        addr_vlag <= circ(wr_ptr, IDX_W'(40));

                        state <= ADDR_SETUP;  // Drain 1 cycle for RAM + diff pipeline
                    end
                end

                // Wait 2 cycles for RAM + registered diff to be valid before accumulating.
                // We use a counter embedded in window_idx: it starts at 0, we burn
                // this cycle advancing the address pipeline, then enter ACCUMULATE.
                ADDR_SETUP: begin
                    // Don't accumulate yet — pipeline not valid
                    // Pre-load address for index 1 (so RAM will have index 0 valid
                    // on first ACCUMULATE cycle after the registered diff settles)
                    addr_v0   <= circ(search_base_ptr, IDX_W'(1));
                    addr_vlag <= circ(search_base_ptr, IDX_W'(1) + IDX_W'(current_lag));
                    window_idx <= IDX_W'(1);
                    state <= ACCUMULATE;
                end

                ACCUMULATE: begin
                    // diff_r is now valid for window_idx - 2 due to 2-stage pipeline.
                    // We start at window_idx=1 after ADDR_SETUP, so by the time
                    // we reach window_idx = WINDOW_SIZE+1, we've accumulated
                    // exactly WINDOW_SIZE valid diffs.
                    current_sum <= current_sum + SUM_W'(diff_r);

                    addr_v0   <= circ(search_base_ptr, window_idx + 1'b1);
                    addr_vlag <= circ(search_base_ptr, (window_idx + 1'b1) + IDX_W'(current_lag));

                    // Run 2 extra cycles to flush the 2-stage pipeline
                    if (window_idx == IDX_W'(WINDOW_SIZE + 1)) begin
                        state <= EVALUATE;
                    end else begin
                        window_idx <= window_idx + 1'b1;
                    end
                end

                EVALUATE: begin
                    if (current_sum < min_sum) begin
                        min_sum           <= current_sum;
                        best_lag_internal <= current_lag;
                    end

                    if (current_lag == LAG_W'(MAX_LAG - 1)) begin
                        best_lag_out <= 12'(best_lag_internal);
                        data_valid   <= 1'b1;
                        state        <= IDLE;
                    end else begin
                        current_lag <= current_lag + 1'b1;
                        window_idx  <= '0;
                        current_sum <= '0;

                        // Set up for next lag, re-enter ADDR_SETUP
                        addr_v0   <= circ(search_base_ptr, IDX_W'(0));
                        addr_vlag <= circ(search_base_ptr, IDX_W'(current_lag + 1));
                        state <= ADDR_SETUP;
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule