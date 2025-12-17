

package lab_pkg;

    // Top Level
	parameter DATA_W = 16;

    // Controller
    parameter FX_COUNT    = 16;
    parameter PARAM_COUNT = 8;
    parameter PARAM_W     = 8;
    parameter PARAM_MAX   = 255; // 2^7 - 1
    parameter PARAM_MIN   = 0;   // 2^0 - 1
    parameter DEBOUNCE_CNT_MAX = 1_000_000;
    parameter REPEAT_START_CNT = 15_000_000;  // ~300 ms
    parameter REPEAT_RATE_CNT  = 2_000_000;    // ~40 ms

    parameter INCDEC_AMOUNT = 2; // ~20 ms @ 50 MHz

    // Default parameter lookup function
    function automatic logic [PARAM_W-1:0]
        param_default (input int fx, input int param);
        begin
            // Default everything to zero
            param_default = '0;

            case (fx)
                0: begin // Input gain
                    if (param == 0) param_default = 8'd127;
                end

                1: begin // Gate
                    case (param)
                        0: param_default = 8'd10;
                        1: param_default = 8'd40;
                        2: param_default = 8'd5;
                    endcase
                end

                2: begin // EQ
                    case (param)
                        0: param_default = 8'd32;
                        1: param_default = 8'd32;
                        2: param_default = 8'd32;
                        3: param_default = 8'd32;
                    endcase
                end

                3: begin // Compressor
                    case (param)
                        0: param_default = 8'd32;
                        1: param_default = 8'd4;
                        2: param_default = 8'd64;
                        3: param_default = 8'd64;
                    endcase
                end

                8: begin // Output gain
                    if (param == 0) param_default = 8'd127;
                end

                default: begin
                    param_default = '0;
                end
            endcase
        end
    endfunction


    // 7 Segment Display Definitions
                                //  6543210
    parameter SEVSEG_SEG_BLANK = 7'b1111111;
    parameter SEVSEG_SEG_LINE  = 7'b0111111;

                                //  6543210
    parameter SEVSEG_SEG_ZERO  = 7'b1000000;
    parameter SEVSEG_SEG_ONE   = 7'b1111001;    
    parameter SEVSEG_SEG_TWO   = 7'b0100100;    
    parameter SEVSEG_SEG_THREE = 7'b0110000;    
    parameter SEVSEG_SEG_FOUR  = 7'b0011001;    
    parameter SEVSEG_SEG_FIVE  = 7'b0010010;
    parameter SEVSEG_SEG_SIX   = 7'b0000010;    
    parameter SEVSEG_SEG_SEVEN = 7'b1111000;
    parameter SEVSEG_SEG_EIGHT = 7'b0000000;
    parameter SEVSEG_SEG_NINE  = 7'b0010000;
    parameter SEVSEG_SEG_A     = 7'b0001000;
    parameter SEVSEG_SEG_B     = 7'b0000011;
    parameter SEVSEG_SEG_C     = 7'b1000110;
    parameter SEVSEG_SEG_D     = 7'b0100001;
    parameter SEVSEG_SEG_E     = 7'b0000110;
    parameter SEVSEG_SEG_F     = 7'b0001110;

    parameter SEVSEG_BLANK_INDEX = 5'd16;
    parameter SEVSEG_LINE_INDEX  = 5'd17;

    // ------------------- DSP Params -------------------
    parameter FX_STAGES = 9;

    // Compressor
    parameter COMP_LOOKAHEAD = 16;
    parameter ROUND_BIAS = 1 << 14;
    // parameter logic [15:0] UNITY_Q15 = 16'd32766;  // SAFE unity
    parameter logic [15:0] UNITY_Q15 = 16'h7FFF;  // SAFE unity
    parameter logic [15:0] MIN_GAIN  = 16'd100;

    // ------------------- DSP Functions ---------------
    
    // Saturate to 16-bit signed range
    // NOTE: value needs to be shifted correctly in x to be in the first 16 bits of x
    function automatic signed [15:0] sat16(input signed [31:0] x);
        if (x > 32'sd32767)
            sat16 = 16'sh7FFF;
        else if (x < -32'sd32768)
            sat16 = -16'sh8000;
        else
            sat16 = x[15:0];
    endfunction

endpackage
