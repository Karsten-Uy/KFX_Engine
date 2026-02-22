/*
    
    Makes the LEDRs and HEX0 display meaningful information.

        LEDR[9:0]:
            - shows the current parameter value using the LEDs as
            a bar, with all 10 LEDs on representing 255 and just 1
            LED showing means a very low or 0 value
        
        HEX5 & HEX4:
            - Shows the current FX selected, HEX5 will always show "F"
            and HEX4 will display a number between "0" and "F" which
            represents which FX in the chain is selected for view/modification

        HEX3 & HEX2:
            - From the selected FX, shows which parameter is currently
            selected. HEX3 will always show "P" and HEX2 will display a 
            number between "0" and "7" which FX parameter is selected
            for view/modification

 */

module display #(
    parameter FX_COUNT    = 16,
    parameter PARAM_COUNT = 8,
    parameter PARAM_W     = 8
)(
    
    input logic [$clog2(FX_COUNT)-1:0]    fx_sel,    // 4 bits
    input logic [$clog2(PARAM_COUNT)-1:0] param_sel, // 3 bits
    input logic [PARAM_W-1:0]             current_value,
    input logic                           fsm_busy,
    input logic                           is_mute,
    input logic [11:0]                    tuner_best_lag,

    // UI feedback
    output logic [9:0] LEDR,
    output logic [6:0] HEX0,
    output logic [6:0] HEX1,
    output logic [6:0] HEX2,
    output logic [6:0] HEX3,
    output logic [6:0] HEX4,
    output logic [6:0] HEX5

);

	// ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;

    // ---------------- INTERNAL SIGNALS ----------------

    logic [4:0] val_HEX0;
    logic [4:0] val_HEX1;
    logic [4:0] val_HEX2;
    logic [4:0] val_HEX3;
    logic [4:0] val_HEX4;
    logic [4:0] val_HEX5;

    sevseg_display H0 (val_HEX0, HEX0);
    sevseg_display H1 (val_HEX1, HEX1);
    sevseg_display H2 (val_HEX2, HEX2);
    sevseg_display H3 (val_HEX3, HEX3);
    sevseg_display H4 (val_HEX4, HEX4);
    sevseg_display H5 (val_HEX5, HEX5);

    localparam int LED_COUNT = 10;
    localparam int MAX_VAL   = (1 << PARAM_W) - 1;

    logic [3:0] led_level;  // 0–10
    logic [4:0] tuner_HEX [5:0];

    // ---------------- MAIN LOGIC ----------------

    // Tuner UI
    tuner_ui TUNER_UI (
        .best_lag(tuner_best_lag),
        .tuner_vals(tuner_HEX)
    );
    
    // HEX display logic
    always_comb begin

        val_HEX0 = SEVSEG_BLANK_INDEX;
        val_HEX1 = SEVSEG_BLANK_INDEX;
        val_HEX2 = SEVSEG_BLANK_INDEX;
        val_HEX3 = SEVSEG_BLANK_INDEX;
        val_HEX4 = SEVSEG_BLANK_INDEX;
        val_HEX5 = SEVSEG_BLANK_INDEX;

        // Static Letters on Display
        val_HEX5 = 5'hF;
        val_HEX3 = SEVSEG_P_INDEX;

        // FX Selected
        val_HEX4 = fx_sel;

        // Param Selected
        val_HEX2 = {1'd0,param_sel};

        if (fsm_busy) begin
            val_HEX1 = SEVSEG_B_INDEX;
        end

        if (is_mute) begin
            val_HEX5 = tuner_HEX[5];
            val_HEX4 = tuner_HEX[4];
            val_HEX3 = tuner_HEX[3];
            val_HEX2 = tuner_HEX[2];
            val_HEX1 = tuner_HEX[1];
            val_HEX0 = tuner_HEX[0];
        end

    end

    // LEDR display logic
    always_comb begin
        LEDR = '0;

        if (current_value == 0) begin
            led_level = 1;
        end else begin
            led_level = (current_value * LED_COUNT + MAX_VAL) / MAX_VAL;

            if (led_level < 1)
                led_level = 1;
            else if (led_level > LED_COUNT)
                led_level = LED_COUNT;
        end

        // Light LEDs from [9] downward
        for (int i = 0; i < LED_COUNT; i++) begin
            if (i < led_level)
                LEDR[LED_COUNT - 1 - i] = 1'b1;
        end
    end

endmodule