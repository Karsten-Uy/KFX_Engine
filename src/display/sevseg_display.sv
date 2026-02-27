/*
 * sevseg_display.sv
 *
 * Index-to-segment decoder for a single active-low 7-segment display on the DE1-SoC.
 *
 * Accepts a 5-bit index and drives the 7-segment pattern registered in lab_pkg.
 * Indices 0–15 map to hex digits; indices 16–23 map to special symbols (blank,
 * dash, letters, and tuner indicators).  Any out-of-range index produces blank.
 *
 * Index map (mirrors the SEVSEG_*_INDEX constants in lab_pkg)
 * -----------------------------------------------------------
 *    0–15  hex digits 0–9, A–F
 *      16  BLANK  — all segments off
 *      17  LINE   — centre dash  ( – )
 *      18  r      — lower-case r
 *      19  P
 *      20  UP     — upward arrow approximation
 *      21  DOWN   — downward arrow approximation
 *      22  #      — sharp sign approximation
 *      23  G
 *
 * Ports
 * -----
 *   value — 5-bit index selecting the character to display
 *   HEX   — 7-bit active-low segment output (g f e d c b a)
 */

module sevseg_display (
    input  logic [4:0] value,
    output logic [6:0] HEX
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Index-to-Segment Decode
    // ----------------------------------------------------------------

    always_comb begin
        case (value)
            5'd0:  HEX = SEVSEG_SEG_ZERO;
            5'd1:  HEX = SEVSEG_SEG_ONE;
            5'd2:  HEX = SEVSEG_SEG_TWO;
            5'd3:  HEX = SEVSEG_SEG_THREE;
            5'd4:  HEX = SEVSEG_SEG_FOUR;
            5'd5:  HEX = SEVSEG_SEG_FIVE;
            5'd6:  HEX = SEVSEG_SEG_SIX;
            5'd7:  HEX = SEVSEG_SEG_SEVEN;
            5'd8:  HEX = SEVSEG_SEG_EIGHT;
            5'd9:  HEX = SEVSEG_SEG_NINE;
            5'd10: HEX = SEVSEG_SEG_A;
            5'd11: HEX = SEVSEG_SEG_B;
            5'd12: HEX = SEVSEG_SEG_C;
            5'd13: HEX = SEVSEG_SEG_D;
            5'd14: HEX = SEVSEG_SEG_E;
            5'd15: HEX = SEVSEG_SEG_F;

            SEVSEG_BLANK_INDEX: HEX = SEVSEG_SEG_BLANK;
            SEVSEG_LINE_INDEX:  HEX = SEVSEG_SEG_LINE;
            SEVSEG_R_INDEX:     HEX = SEVSEG_SEG_R;
            SEVSEG_P_INDEX:     HEX = SEVSEG_SEG_P;
            SEVSEG_UP_INDEX:    HEX = SEVSEG_SEG_UP;
            SEVSEG_DOWN_INDEX:  HEX = SEVSEG_SEG_DOWN;
            SEVSEG_SHARP_INDEX: HEX = SEVSEG_SEG_SHARP;
            SEVSEG_G_INDEX:     HEX = SEVSEG_SEG_G;

            default: HEX = SEVSEG_SEG_BLANK;  // unreachable with valid indices
        endcase
    end

endmodule