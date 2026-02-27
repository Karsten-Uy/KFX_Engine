/*
 * lab_pkg.sv
 *
 * Shared parameter package for the AudioFX multi-effects pedalboard.
 *
 * Contains all top-level constants (DSP widths, controller timing, display
 * encodings), the default-parameter lookup function, and common DSP helper
 * functions.  Every module in the design imports this package.
 *
 * Sections
 * --------
 *   1. DSP / top-level constants
 *   2. Default parameter table  (param_default)
 *   3. Seven-segment display encodings
 *   4. FX constants
 *   5. Common DSP functions      (sat16)
 */

package lab_pkg;

    // ----------------------------------------------------------------
    // 1. DSP / Top-Level Constants
    // ----------------------------------------------------------------

    // Audio pipeline
    parameter DATA_W      = 16;
    parameter SAMPLE_RATE = 48000;

    // Controller dimensions
    parameter FX_COUNT    = 16;
    parameter PARAM_COUNT = 8;
    parameter PARAM_W     = 8;
    parameter PARAM_MAX   = 255;  // 2^8 - 1
    parameter PARAM_MIN   = 0;

    // Button timing (cycles at 50 MHz)
    parameter DEBOUNCE_CNT_MAX = 1_000_000;    // ~20 ms
    parameter REPEAT_START_CNT = 15_000_000;   // ~300 ms before auto-repeat begins
    parameter REPEAT_RATE_CNT  = 1_000_000;    // ~20 ms between auto-repeat pulses
    parameter MUTE_START_CNT   = 50_000_000;   // ~1 s hold to engage mute

    // Flash memory
    parameter FLASH_BASE    = 24'h6B0000;      // byte address of parameter save slot
    parameter INCDEC_AMOUNT = 2;

    // Tuner
    parameter MIN_LAG        = 120;
    parameter MAX_LAG        = 1600;
    parameter WINDOW_SIZE    = 8192;              // ~170 ms of audio @ 48 kHz
    parameter AMP_THRESHOLD  = 100;

    // ----------------------------------------------------------------
    // 2. Default Parameter Table
    // ----------------------------------------------------------------

    // Returns the power-on default value for params[fx][param].
    // All unlisted combinations default to 0.
    function automatic logic [PARAM_W-1:0]
        param_default (input int fx, input int param);
        begin
            param_default = '0;

            case (fx)
                0: begin // Input gain
                    if (param == 0) param_default = 8'd32;
                end

                1: begin // Gate
                    case (param)
                        0: param_default = 8'd1;
                        1: param_default = 8'd40;
                        2: param_default = 8'd128;
                    endcase
                end

                2: begin // EQ 1
                    case (param)
                        0: param_default = 8'd0;
                        1: param_default = 8'd4;
                        2: param_default = 8'd128;
                        3: param_default = 8'd128;
                    endcase
                end

                3: begin // Compressor
                    case (param)
                        0: param_default = 8'd32;
                        1: param_default = 8'd0;    // no compression by default
                        2: param_default = 8'd64;
                        3: param_default = 8'd128;
                        4: param_default = 8'd64;
                        5: param_default = 8'd64;
                        6: param_default = 8'd0;
                    endcase
                end

                4: begin // Distortion
                    case (param)
                        0: param_default = 8'd128;
                        1: param_default = 8'd64;
                        2: param_default = 8'd0;
                    endcase
                end

                5: begin // EQ 2
                    case (param)
                        0: param_default = 8'd0;
                        1: param_default = 8'd100;
                        2: param_default = 8'd128;
                        3: param_default = 8'd150;
                    endcase
                end

                6: begin // Chorus
                    case (param)
                        0: param_default = 8'd128;
                        1: param_default = 8'd128;
                        2: param_default = 8'd0;
                    endcase
                end

                7: begin // Spectral gain
                    if (param == 0) param_default = 8'd32;
                end

                8: begin // Delay
                    case (param)
                        0: param_default = 8'd128;
                        1: param_default = 8'd95;
                        2: param_default = 8'd255;
                    endcase
                end

                9: begin // Reverb
                    case (param)
                        0: param_default = 8'd128;
                        1: param_default = 8'd128;
                        2: param_default = 8'd0;
                    endcase
                end

                10: begin // Output gain
                    if (param == 0) param_default = 8'd32;
                end

                default: param_default = '0;
            endcase
        end
    endfunction

    // ----------------------------------------------------------------
    // 3. Seven-Segment Display Encodings
    //
    // Bit order: [6:0] = segments g f e d c b a  (active-low on DE1-SoC).
    // Numeric digits 0–9 and letters A–G are encoded directly.
    // Special symbols (blank, dash, tuner indicators) have named constants
    // and corresponding index values for use with sevseg_display.
    // ----------------------------------------------------------------

    //                              //  6543210
    parameter SEVSEG_SEG_BLANK = 7'b1111111;  // all segments off
    parameter SEVSEG_SEG_LINE  = 7'b0111111;  // centre dash  ( – )

    //                              //  6543210
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

    //                              //  6543210
    parameter SEVSEG_SEG_R     = 7'b0101111;  // lower-case r
    parameter SEVSEG_SEG_P     = 7'b0001100;  // P
    parameter SEVSEG_SEG_UP    = 7'b1011100;  // upward arrow segment
    parameter SEVSEG_SEG_DOWN  = 7'b1100011;  // downward arrow segment
    parameter SEVSEG_SEG_SHARP = 7'b0011100;  // '#' approximation
    parameter SEVSEG_SEG_G     = 7'b0010000;  // G

    // Index values passed to sevseg_display (0–15 = hex digit, 16+ = specials)
    parameter SEVSEG_BLANK_INDEX = 5'd16;
    parameter SEVSEG_LINE_INDEX  = 5'd17;
    parameter SEVSEG_R_INDEX     = 5'd18;
    parameter SEVSEG_P_INDEX     = 5'd19;
    parameter SEVSEG_UP_INDEX    = 5'd20;
    parameter SEVSEG_DOWN_INDEX  = 5'd21;
    parameter SEVSEG_SHARP_INDEX = 5'd22;
    parameter SEVSEG_G_INDEX     = 5'd23;

    // ----------------------------------------------------------------
    // 4. FX Constants
    // ----------------------------------------------------------------

    parameter FX_STAGES = 11;  // number of pipeline stages in the FX chain

    // Compressor / gate shared
    parameter COMP_LOOKAHEAD         = 16;
    parameter logic [15:0] UNITY_Q15 = 16'h7FFF;  // Q1.15 unity gain
    parameter logic [15:0] MIN_GAIN  = 16'd100;

    // Delay / Tap Delay 
    parameter MAX_SAMPLES = 24000;
    parameter MIN_DELAY_MS = 50;
    parameter MAX_DELAY_MS = 500;
    parameter MIN_DELAY_SAMPLES = (MIN_DELAY_MS * SAMPLE_RATE) / 1000;
    parameter MAX_DELAY_SAMPLES = (MAX_DELAY_MS * SAMPLE_RATE) / 1000;
    parameter DELAY_RANGE = MAX_DELAY_SAMPLES - MIN_DELAY_SAMPLES;
    parameter TIMEOUT_CYCLES    = 100_000_000;

    // ----------------------------------------------------------------
    // 5. Common DSP Functions
    // ----------------------------------------------------------------

    // Saturate a 32-bit signed value to the 16-bit signed range [-32768, 32767].
    // The caller is responsible for aligning x so that the desired 16-bit
    // result sits in x[15:0] before calling.
    function automatic signed [15:0] sat16(input signed [31:0] x);
        if      (x > 32'sd32767)  sat16 = 16'sh7FFF;
        else if (x < -32'sd32768) sat16 = -16'sh8000;
        else                      sat16 = x[15:0];
    endfunction

endpackage