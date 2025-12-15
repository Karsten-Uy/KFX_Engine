

/*
 * FX parameter controller
 * - Debounced inc / dec keys
 * - Single-step on press
 * - Auto-repeat on hold
 */

module controller #(
    parameter FX_COUNT    = 16,
    parameter PARAM_COUNT = 8,
    parameter PARAM_W     = 7,

    // Debounce + repeat timing (50 MHz)
    parameter DEBOUNCE_CNT_MAX = 1_000_000,   // ~20 ms
    parameter REPEAT_START_CNT = 15_000_000,  // ~300 ms
    parameter REPEAT_RATE_CNT  = 2_000_000    // ~40 ms
)(
    input  logic                            clk,
    input  logic                            reset_n,

    // Raw hardware controls
    input  logic [$clog2(FX_COUNT)-1:0]     sw_fx_sel,
    input  logic [$clog2(PARAM_COUNT)-1:0]  sw_param_sel,
    input  logic                            key_inc,
    input  logic                            key_dec,

    // Parameter storage
    output logic [PARAM_W-1:0]              params [0:FX_COUNT-1][0:PARAM_COUNT-1],

    // Current selection
    output logic [$clog2(FX_COUNT)-1:0]     fx_sel,
    output logic [$clog2(PARAM_COUNT)-1:0]  param_sel,
    output logic [PARAM_W-1:0]              current_value
);

    // ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;

    // ---------------- Selection ----------------
    assign fx_sel        = sw_fx_sel;
    assign param_sel     = sw_param_sel;
    assign current_value = params[fx_sel][param_sel];

    // ---------------- Debounce Signals ----------------
    logic key_inc_sync0, key_inc_sync1, key_inc_stable;
    logic key_dec_sync0, key_dec_sync1, key_dec_stable;

    logic [$clog2(DEBOUNCE_CNT_MAX)-1:0] key_inc_cnt, key_dec_cnt;

    // ---------------- Edge Detect ----------------
    logic key_inc_prev, key_dec_prev;
    logic key_inc_pulse, key_dec_pulse;

    // ---------------- Auto Repeat ----------------
    logic [$clog2(REPEAT_START_CNT)-1:0] inc_hold_cnt, dec_hold_cnt;
    logic [$clog2(REPEAT_RATE_CNT)-1:0]  inc_repeat_cnt, dec_repeat_cnt;
    logic inc_repeat_pulse, dec_repeat_pulse;

    // ---------------- PARAM STORAGE ----------------
    integer fx, p;
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            for (fx = 0; fx < FX_COUNT; fx++)
                for (p = 0; p < PARAM_COUNT; p++)
                    params[fx][p] <= param_default(fx, p);
        end else begin
            // Increment (saturating)
            if (key_inc_pulse || inc_repeat_pulse) begin
                if (params[fx_sel][param_sel] >= PARAM_MAX - INCDEC_AMOUNT)
                    params[fx_sel][param_sel] <= PARAM_MAX;
                else
                    params[fx_sel][param_sel] <=
                        params[fx_sel][param_sel] + INCDEC_AMOUNT;
            end

            // Decrement (saturating)
            else if (key_dec_pulse || dec_repeat_pulse) begin
                if (params[fx_sel][param_sel] <= PARAM_MIN + INCDEC_AMOUNT)
                    params[fx_sel][param_sel] <= PARAM_MIN;
                else
                    params[fx_sel][param_sel] <=
                        params[fx_sel][param_sel] - INCDEC_AMOUNT;
            end
        end
    end

    // ---------------- DEBOUNCE (BOTH KEYS) ----------------
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            key_inc_sync0  <= 0;
            key_inc_sync1  <= 0;
            key_inc_stable <= 0;
            key_inc_cnt    <= '0;

            key_dec_sync0  <= 0;
            key_dec_sync1  <= 0;
            key_dec_stable <= 0;
            key_dec_cnt    <= '0;
        end else begin
            // Synchronizers
            key_inc_sync0 <= key_inc;
            key_inc_sync1 <= key_inc_sync0;
            key_dec_sync0 <= key_dec;
            key_dec_sync1 <= key_dec_sync0;

            // INC debounce
            if (key_inc_sync1 == key_inc_stable)
                key_inc_cnt <= '0;
            else if (key_inc_cnt == DEBOUNCE_CNT_MAX-1) begin
                key_inc_stable <= key_inc_sync1;
                key_inc_cnt    <= '0;
            end else
                key_inc_cnt <= key_inc_cnt + 1'b1;

            // DEC debounce
            if (key_dec_sync1 == key_dec_stable)
                key_dec_cnt <= '0;
            else if (key_dec_cnt == DEBOUNCE_CNT_MAX-1) begin
                key_dec_stable <= key_dec_sync1;
                key_dec_cnt    <= '0;
            end else
                key_dec_cnt <= key_dec_cnt + 1'b1;
        end
    end

    // ---------------- EDGE DETECT ----------------
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            key_inc_prev  <= 0;
            key_dec_prev  <= 0;
            key_inc_pulse <= 0;
            key_dec_pulse <= 0;
        end else begin
            key_inc_pulse <= key_inc_stable & ~key_inc_prev;
            key_dec_pulse <= key_dec_stable & ~key_dec_prev;

            key_inc_prev <= key_inc_stable;
            key_dec_prev <= key_dec_stable;
        end
    end

    // ---------------- AUTO REPEAT ----------------
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            inc_hold_cnt     <= '0;
            inc_repeat_cnt   <= '0;
            inc_repeat_pulse <= 0;

            dec_hold_cnt     <= '0;
            dec_repeat_cnt   <= '0;
            dec_repeat_pulse <= 0;
        end else begin
            // INC repeat
            inc_repeat_pulse <= 0;
            if (key_inc_stable) begin
                if (inc_hold_cnt < REPEAT_START_CNT)
                    inc_hold_cnt <= inc_hold_cnt + 1'b1;
                else if (inc_repeat_cnt == REPEAT_RATE_CNT-1) begin
                    inc_repeat_cnt   <= '0;
                    inc_repeat_pulse <= 1'b1;
                end else
                    inc_repeat_cnt <= inc_repeat_cnt + 1'b1;
            end else begin
                inc_hold_cnt   <= '0;
                inc_repeat_cnt <= '0;
            end

            // DEC repeat
            dec_repeat_pulse <= 0;
            if (key_dec_stable) begin
                if (dec_hold_cnt < REPEAT_START_CNT)
                    dec_hold_cnt <= dec_hold_cnt + 1'b1;
                else if (dec_repeat_cnt == REPEAT_RATE_CNT-1) begin
                    dec_repeat_cnt   <= '0;
                    dec_repeat_pulse <= 1'b1;
                end else
                    dec_repeat_cnt <= dec_repeat_cnt + 1'b1;
            end else begin
                dec_hold_cnt   <= '0;
                dec_repeat_cnt <= '0;
            end
        end
    end

endmodule
