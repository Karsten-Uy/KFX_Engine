/*
 * display.sv
 *
 * Top-level display controller: drives LEDR and HEX0–HEX5 from controller state
 * and the tuner engine output.
 *
 * Normal mode  (is_mute = 0)
 * --------------------------
 *   HEX5 = 'F' (FX label)    HEX4 = fx_sel index    HEX3 = 'P' (param label)
 *   HEX2 = param_sel index   HEX1 = 'b' if fsm_busy, else blank
 *   LEDR  = bar-graph of current_value (always at least 1 LED lit)
 *
 * Mute / tuner mode  (is_mute = 1)
 * ----------------------------------
 *   All six HEX digits are taken from tuner_display, showing either the
 *   nearest note name + tuning indicator, or the frequency in Hz (SW[9]).
 *
 * Tuner silence timeout
 * ---------------------
 *   tuner_valid is a single-cycle pulse at ~16 Hz when a signal is present.
 *   best_lag is latched on every pulse and the silence counter resets.
 *   If TIMEOUT_CYCLES (~500 ms) elapse with no pulse, the latch is cleared
 *   so tuner_display receives best_lag == 0 and shows dashes.
 *
 * Ports
 * -----
 *   fx_sel        — current FX index (from controller)
 *   param_sel     — current parameter index (from controller)
 *   current_value — params[fx_sel][param_sel], used for the LEDR bar graph
 *   fsm_busy      — high while save / load is in progress; shows 'b' on HEX1
 *   is_mute       — switches all HEX digits to the tuner display
 *   tuner_best_lag — raw lag from tuner_yin_engine
 *   tuner_valid   — single-cycle pulse when tuner_best_lag is updated
 *   SW[9]         — tuner display mode: 0 = note, 1 = frequency
 */

module display #(
    parameter FX_COUNT    = 16,
    parameter PARAM_COUNT = 8,
    parameter PARAM_W     = 8
)(
    input logic                           clk,
    input logic                           reset_n,
    input logic [$clog2(FX_COUNT)-1:0]    fx_sel,
    input logic [$clog2(PARAM_COUNT)-1:0] param_sel,
    input logic [PARAM_W-1:0]             current_value,
    input logic                           fsm_busy,
    input logic                           is_mute,
    input logic [$clog2(BANK_COUNT)-1:0]  bank_sel,
    input logic [11:0]                    tuner_best_lag,
    input logic                           tuner_valid,
    input logic [9:0]                     SW,

    output logic [9:0] LEDR,
    output logic [6:0] HEX0,
    output logic [6:0] HEX1,
    output logic [6:0] HEX2,
    output logic [6:0] HEX3,
    output logic [6:0] HEX4,
    output logic [6:0] HEX5
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Tuner Silence Timeout
    //
    // Latch best_lag on every valid pulse and reset the counter.
    // Once TIMEOUT_CYCLES have elapsed with no new pulse, zero the latch
    // so tuner_display shows dashes.  The counter saturates after timeout
    // rather than rolling over, so the latch is only cleared once.
    // ----------------------------------------------------------------

    localparam int TIMEOUT_CYCLES = 25_000_000;  // 500 ms @ 50 MHz

    logic [11:0] tuner_lag_latch;
    logic [24:0] silence_cnt;  // 25 bits covers 33 M cycles

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            tuner_lag_latch <= 12'd0;
            silence_cnt     <= '0;
        end else if (tuner_valid) begin
            tuner_lag_latch <= tuner_best_lag;
            silence_cnt     <= '0;
        end else if (silence_cnt < 25'(TIMEOUT_CYCLES)) begin
            silence_cnt <= silence_cnt + 1'b1;
        end else begin
            tuner_lag_latch <= 12'd0;  // clear once on timeout; counter stays saturated
        end
    end

    // ----------------------------------------------------------------
    // Seven-Segment Drivers
    // ----------------------------------------------------------------

    logic [4:0] val_HEX0, val_HEX1, val_HEX2,
                val_HEX3, val_HEX4, val_HEX5;

    sevseg_display H0 (.value(val_HEX0), .HEX(HEX0));
    sevseg_display H1 (.value(val_HEX1), .HEX(HEX1));
    sevseg_display H2 (.value(val_HEX2), .HEX(HEX2));
    sevseg_display H3 (.value(val_HEX3), .HEX(HEX3));
    sevseg_display H4 (.value(val_HEX4), .HEX(HEX4));
    sevseg_display H5 (.value(val_HEX5), .HEX(HEX5));

    // ----------------------------------------------------------------
    // Tuner Display Submodule
    // ----------------------------------------------------------------

    logic [4:0] tuner_HEX [5:0];

    tuner_display TUNER_DISPLAY (
        .best_lag  (tuner_lag_latch),  // 0 when silent → shows dashes
        .mode_sel  (SW[9]),
        .tuner_vals(tuner_HEX)
    );

    // ----------------------------------------------------------------
    // HEX Display Logic
    //
    // Normal mode defaults; overridden entirely by tuner when muted.
    // ----------------------------------------------------------------

    always_comb begin
        // Normal mode defaults
        val_HEX5 = 5'hF;             // 'F' for FX
        val_HEX4 = fx_sel;
        val_HEX3 = SEVSEG_P_INDEX;   // 'P' for param
        val_HEX2 = {1'b0, param_sel};
        val_HEX1 = fsm_busy ? 5'hB : SEVSEG_BLANK_INDEX;  // 'b' while busy
        val_HEX0 = bank_sel;

        // Mute mode: hand all digits to the tuner display
        if (is_mute) begin
            val_HEX5 = tuner_HEX[5];
            val_HEX4 = tuner_HEX[4];
            val_HEX3 = tuner_HEX[3];
            val_HEX2 = tuner_HEX[2];
            val_HEX1 = tuner_HEX[1];
            val_HEX0 = tuner_HEX[0];
        end
    end

    // ----------------------------------------------------------------
    // LEDR Bar Graph
    //
    // Maps current_value (0–255) onto 1–10 LEDs.  The bar always shows
    // at least one LED so the user can tell the display is active at zero.
    // ----------------------------------------------------------------

    localparam int LED_COUNT = 10;
    localparam int MAX_VAL   = (1 << PARAM_W) - 1;

    logic [3:0] led_level;

    always_comb begin
        LEDR = '0;

        if (current_value == 0) begin
            led_level = 1;
        end else begin
            led_level = (current_value * LED_COUNT + MAX_VAL) / MAX_VAL;
            if      (led_level < 1)         led_level = 1;
            else if (led_level > LED_COUNT) led_level = LED_COUNT;
        end

        for (int i = 0; i < LED_COUNT; i++)
            if (i < led_level)
                LEDR[LED_COUNT - 1 - i] = 1'b1;
    end

endmodule