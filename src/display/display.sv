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

    // -----------------------------------------------------------------------
    // Silence timeout
    //
    // tuner_valid is a single-cycle pulse (~16 Hz when signal is present).
    // Latch best_lag on every pulse and reset the silence counter.
    // If no pulse arrives for TIMEOUT_CYCLES (~500 ms), zero the latch so
    // tuner_ui sees best_lag == 0 and shows blank digits.
    // -----------------------------------------------------------------------
    localparam int TIMEOUT_CYCLES = 25_000_000; // 500 ms @ 50 MHz

    logic [11:0] tuner_lag_latch;
    logic [24:0] silence_cnt;           // 25 bits covers 33 M cycles

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
            // Only zero the latch once on the exact timeout transition,
            // not every cycle after — silence_cnt stays saturated
            tuner_lag_latch <= 12'd0;
        end
end

    // -----------------------------------------------------------------------
    // Seven-segment drivers
    // -----------------------------------------------------------------------
    logic [4:0] val_HEX0, val_HEX1, val_HEX2,
                val_HEX3, val_HEX4, val_HEX5;

    sevseg_display H0 (val_HEX0, HEX0);
    sevseg_display H1 (val_HEX1, HEX1);
    sevseg_display H2 (val_HEX2, HEX2);
    sevseg_display H3 (val_HEX3, HEX3);
    sevseg_display H4 (val_HEX4, HEX4);
    sevseg_display H5 (val_HEX5, HEX5);

    localparam int LED_COUNT = 10;
    localparam int MAX_VAL   = (1 << PARAM_W) - 1;

    logic [3:0] led_level;
    logic [4:0] tuner_HEX [5:0];

    // Feed the stable latch — 0 when silent → tuner_ui shows blank
    tuner_ui TUNER_UI (
        .best_lag   (tuner_lag_latch),
        .mode_sel   (SW[9]),
        .tuner_vals (tuner_HEX)
    );

    // -----------------------------------------------------------------------
    // HEX display logic
    // -----------------------------------------------------------------------
    always_comb begin
        val_HEX0 = SEVSEG_BLANK_INDEX;
        val_HEX1 = SEVSEG_BLANK_INDEX;
        val_HEX2 = SEVSEG_BLANK_INDEX;
        val_HEX3 = SEVSEG_BLANK_INDEX;
        val_HEX4 = SEVSEG_BLANK_INDEX;
        val_HEX5 = SEVSEG_BLANK_INDEX;

        val_HEX5 = 5'hF;
        val_HEX3 = SEVSEG_P_INDEX;
        val_HEX4 = fx_sel;
        val_HEX2 = {1'd0, param_sel};

        if (fsm_busy)
            val_HEX1 = SEVSEG_SEG_B;

        if (is_mute) begin
            val_HEX5 = tuner_HEX[5];
            val_HEX4 = tuner_HEX[4];
            val_HEX3 = tuner_HEX[3];
            val_HEX2 = tuner_HEX[2];
            val_HEX1 = tuner_HEX[1];
            val_HEX0 = tuner_HEX[0];
        end
    end

    // -----------------------------------------------------------------------
    // LEDR bar display
    // -----------------------------------------------------------------------
    always_comb begin
        LEDR = '0;

        if (current_value == 0) begin
            led_level = 1;
        end else begin
            led_level = (current_value * LED_COUNT + MAX_VAL) / MAX_VAL;
            if (led_level < 1)              led_level = 1;
            else if (led_level > LED_COUNT) led_level = LED_COUNT;
        end

        for (int i = 0; i < LED_COUNT; i++)
            if (i < led_level)
                LEDR[LED_COUNT - 1 - i] = 1'b1;
    end

endmodule