module sevseg_display(
    input logic [4:0] value,
    output logic [6:0] HEX
);
    // ---------------- PACKAGE IMPORTS ----------------

    import lab_pkg::*;

    // ---------------- MAIN PROCESS ----------------
    
    always_comb begin        
        case(value)
            5'd0    : HEX = SEVSEG_SEG_ZERO;
            5'd1    : HEX = SEVSEG_SEG_ONE;
            5'd2    : HEX = SEVSEG_SEG_TWO;
            5'd3    : HEX = SEVSEG_SEG_THREE;
            5'd4    : HEX = SEVSEG_SEG_FOUR;
            5'd5    : HEX = SEVSEG_SEG_FIVE;
            5'd6    : HEX = SEVSEG_SEG_SIX;
            5'd7    : HEX = SEVSEG_SEG_SEVEN;
            5'd8    : HEX = SEVSEG_SEG_EIGHT;
            5'd9    : HEX = SEVSEG_SEG_NINE;
            5'd10   : HEX = SEVSEG_SEG_A;
            5'd11   : HEX = SEVSEG_SEG_B;
            5'd12   : HEX = SEVSEG_SEG_C;
            5'd13   : HEX = SEVSEG_SEG_D;
            5'd14   : HEX = SEVSEG_SEG_E;
            5'd15   : HEX = SEVSEG_SEG_F;

            // value = 5'd16
            SEVSEG_BLANK_INDEX : HEX = SEVSEG_SEG_BLANK;

            // value = 5'd17
            SEVSEG_LINE_INDEX  : HEX = SEVSEG_SEG_LINE;

            default : HEX = SEVSEG_SEG_BLANK; // SHOULD NOT HAPPEN
        endcase
    end

endmodule