/*
 * Displays paremeter value that is currently being edited
 */

// TODO: Make it actaully display something meaningful and not just numbers

module display #(
    parameter FX_COUNT    = 16,
    parameter PARAM_COUNT = 8,
    parameter PARAM_W     = 7
)(
    
    input logic [$clog2(FX_COUNT)-1:0]    fx_sel,    // 4 bits
    input logic [$clog2(PARAM_COUNT)-1:0] param_sel, // 3 bits
    input logic [PARAM_W-1:0]             current_value,
    input logic [9:0]                     SW,

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

    // ---------------- MAIN LOGIC ----------------
    
    always_comb begin

        val_HEX0 = SEVSEG_BLANK_INDEX;
        val_HEX1 = SEVSEG_BLANK_INDEX;
        val_HEX2 = SEVSEG_BLANK_INDEX;
        val_HEX3 = SEVSEG_BLANK_INDEX;
        val_HEX4 = SEVSEG_BLANK_INDEX;
        val_HEX5 = SEVSEG_BLANK_INDEX;

        // FX Selected
        val_HEX5 = fx_sel;

        // Param Selected
        val_HEX4 = {1'd0,param_sel};

        if (SW[0]) begin
            val_HEX0 = SEVSEG_LINE_INDEX;
        end

    end

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