/*
 * lab_pkg.sv
 *
 * Shared parameter package for the AudioFX multi-effects pedalboard.
 *
 * Sections
 * --------
 *   1. DSP / top-level constants
 *   2. Default parameter table  (param_default — now bank-aware)
 *   3. Seven-segment display encodings
 *   4. FX constants
 *   5. Common DSP functions      (sat16)
 *
 * Bank presets (power-on defaults)
 * ---------------------------------
 *   Bank 0  CLEAN    — unity gain, no distortion, light reverb
 *   Bank 1  CRUNCH   — moderate drive, mid-boost EQ
 *   Bank 2  LEAD     — high drive, compressed, delay + reverb
 *   Bank 3  AMBIENT  — clean, heavy chorus, long reverb, no distortion
 *
 * param_default(bank, fx, param) is the single entry-point. It delegates
 * to one of four private helper functions so each preset is self-contained
 * and easy to edit without touching the others.
 */

package lab_pkg;

    // ----------------------------------------------------------------
    // 1. DSP / Top-Level Constants
    // ----------------------------------------------------------------

    parameter DATA_W      = 16;
    parameter SAMPLE_RATE = 48000;

    parameter BANK_COUNT  = 4;
    parameter FX_COUNT    = 16;
    parameter PARAM_COUNT = 8;
    parameter PARAM_W     = 8;
    parameter PARAM_MAX   = 255;
    parameter PARAM_MIN   = 0;

    parameter DEBOUNCE_CNT_MAX = 1_000_000;
    parameter REPEAT_START_CNT = 15_000_000;
    parameter REPEAT_RATE_CNT  = 1_000_000;
    parameter MUTE_START_CNT   = 50_000_000;

    // Flash memory layout:
    //   sentinel word (1) | bank0 params | bank1 params | bank2 params | bank3 params
    //   Total param words = BANK_COUNT * FX_COUNT * PARAM_COUNT = 4*16*8 = 512
    parameter FLASH_BASE    = 24'h6B0000;
    parameter INCDEC_AMOUNT = 2;

    parameter MIN_LAG        = 120;
    parameter MAX_LAG        = 1600;
    parameter WINDOW_SIZE    = 8192;
    parameter AMP_THRESHOLD  = 100;

    // ----------------------------------------------------------------
    // 2. Default Parameter Table
    //
    // Public entry-point:  param_default(bank, fx, param)
    //
    // FX index map (shared across all banks)
    //   0  Input Gain       [0]=gain
    //   1  Noise Gate       [0]=threshold [1]=attack [2]=release [3]=knee [4]=depth
    //   2  EQ 1 (pre-dist)  [0]=sub [1]=low [2]=mid [3]=high
    //   3  Compressor        [0]=thresh [1]=ratio [2]=attack [3]=release
    //                        [4]=input_gain [5]=makeup_gain [7]=mix
    //   4  Distortion        [0]=drive [1]=makeup_gain [7]=mix
    //   5  EQ 2 (post-dist)  [0]=sub [1]=low [2]=mid [3]=high
    //   6  Chorus            [0]=rate [1]=depth [7]=mix
    //   7  Expression Gain   [0]=gain
    //   8  Delay             [0]=time [1]=feedback [7]=mix
    //   9  Reverb            [0]=size [1]=damping [7]=mix
    //  10  Output Gain       [0]=gain
    //
    // Encoding convention (8-bit, 0-255):
    //   Gain / level  128 = unity  (x1.0)
    //   Mix           0   = dry    255 = fully wet
    //   Off           mix = 0
    // ----------------------------------------------------------------

    // ---- Bank 0 : CLEAN ----------------------------------------
    // Transparent signal path: unity gain everywhere, no distortion,
    // gentle reverb tail just to add air.
    function automatic logic [PARAM_W-1:0]
            bank0_default(input int fx, input int param);
        bank0_default = '0;
        case (fx)
            0:  if (param==0) bank0_default = 8'd128;           // input gain unity
            1:  case (param)
                    0: bank0_default = 8'd1;                     // gate off
                    1: bank0_default = 8'd40;
                    2: bank0_default = 8'd128;
                endcase
            2:  case (param)
                    0: bank0_default = 8'd0;
                    1: bank0_default = 8'd4;                     // slight low cut
                    2: bank0_default = 8'd128;
                    3: bank0_default = 8'd128;
                endcase
            3:  case (param)
                    0: bank0_default = 8'd32;
                    1: bank0_default = 8'd0;                     // comp off
                    2: bank0_default = 8'd64;
                    3: bank0_default = 8'd128;
                    4: bank0_default = 8'd64;
                    5: bank0_default = 8'd64;
                endcase
            4:  case (param)
                    0: bank0_default = 8'd128;
                    1: bank0_default = 8'd64;
                    7: bank0_default = 8'd0;                     // distortion off
                endcase
            5:  case (param)
                    0: bank0_default = 8'd0;
                    1: bank0_default = 8'd100;
                    2: bank0_default = 8'd128;
                    3: bank0_default = 8'd150;
                endcase
            6:  case (param)
                    0: bank0_default = 8'd128;
                    1: bank0_default = 8'd128;
                    7: bank0_default = 8'd0;                     // chorus off
                endcase
            7:  if (param==0) bank0_default = 8'd128;
            8:  case (param)
                    0: bank0_default = 8'd128;
                    1: bank0_default = 8'd95;
                    7: bank0_default = 8'd0;                     // delay off
                endcase
            9:  case (param)
                    0: bank0_default = 8'd100;
                    1: bank0_default = 8'd160;
                    7: bank0_default = 8'd40;                    // light reverb
                endcase
            10: if (param==0) bank0_default = 8'd128;
        endcase
    endfunction

    // ---- Bank 1 : CRUNCH ----------------------------------------
    // Classic rock crunch — mild drive, mid-pushed EQ, punchy comp.
    function automatic logic [PARAM_W-1:0]
            bank1_default(input int fx, input int param);
        bank1_default = '0;
        case (fx)
            0:  if (param==0) bank1_default = 8'd140;
            1:  case (param)
                    0: bank1_default = 8'd1;
                    1: bank1_default = 8'd40;
                    2: bank1_default = 8'd100;
                endcase
            2:  case (param)
                    0: bank1_default = 8'd0;
                    1: bank1_default = 8'd40;
                    2: bank1_default = 8'd160;   
                    3: bank1_default = 8'd140;
                endcase
            3:  case (param)
                    0: bank1_default = 8'd60;
                    1: bank1_default = 8'd128;
                    2: bank1_default = 8'd50;
                    3: bank1_default = 8'd110;
                    4: bank1_default = 8'd255;
                    5: bank1_default = 8'd255;
                    7: bank1_default = 8'd255;
                endcase
            4:  case (param)
                    0: bank1_default = 8'd255;       
                    1: bank1_default = 8'd50;
                    2: bank1_default = 8'd50;
                    3: bank1_default = 8'd0;
                    4: bank1_default = 8'd230;
                    5: bank1_default = 8'd30;
                    6: bank1_default = 8'd230;
                    7: bank1_default = 8'd255;
                endcase
            5:  case (param)
                    0: bank1_default = 8'd0;
                    1: bank1_default = 8'd90;
                    2: bank1_default = 8'd140;
                    3: bank1_default = 8'd170;     
                endcase
            6:  case (param)
                    0: bank1_default = 8'd128;
                    1: bank1_default = 8'd128;
                    7: bank1_default = 8'd0;
                endcase
            7:  if (param==0) bank1_default = 8'd128;
            8:  case (param)
                    0: bank1_default = 8'd100;     
                    1: bank1_default = 8'd60;
                    7: bank1_default = 8'd60;
                endcase
            9:  case (param)
                    0: bank1_default = 8'd80;
                    1: bank1_default = 8'd150;
                    7: bank1_default = 8'd0;
                endcase
            10: if (param==0) bank1_default = 8'd1;
        endcase
    endfunction

    // ---- Bank 2 : LEAD ----------------------------------------
    // High-gain lead tone — hard compression, heavy saturation,
    // long dotted-eighth delay, lush reverb.
    function automatic logic [PARAM_W-1:0]
            bank2_default(input int fx, input int param);
        bank2_default = '0;
        case (fx)
            0:  if (param==0) bank2_default = 8'd150;
            1:  case (param)
                    0: bank2_default = 8'd1;
                    1: bank2_default = 8'd30;
                    2: bank2_default = 8'd80;
                endcase
            2:  case (param)
                    0: bank2_default = 8'd0;
                    1: bank2_default = 8'd60;                    // low cut
                    2: bank2_default = 8'd150;
                    3: bank2_default = 8'd130;
                endcase
            3:  case (param)
                    0: bank2_default = 8'd80;
                    1: bank2_default = 8'd140;                   // ratio ~4:1
                    2: bank2_default = 8'd30;                    // fast attack
                    3: bank2_default = 8'd100;
                    4: bank2_default = 8'd100;
                    5: bank2_default = 8'd100;
                    7: bank2_default = 8'd220;
                endcase
            4:  case (param)
                    0: bank2_default = 8'd220;                   // high gain
                    1: bank2_default = 8'd90;
                    7: bank2_default = 8'd240;
                endcase
            5:  case (param)
                    0: bank2_default = 8'd0;
                    1: bank2_default = 8'd70;
                    2: bank2_default = 8'd160;
                    3: bank2_default = 8'd180;
                endcase
            6:  case (param)
                    0: bank2_default = 8'd128;
                    1: bank2_default = 8'd128;
                    7: bank2_default = 8'd0;                     // no chorus on lead
                endcase
            7:  if (param==0) bank2_default = 8'd128;
            8:  case (param)
                    0: bank2_default = 8'd170;                   // dotted-eighth
                    1: bank2_default = 8'd120;
                    7: bank2_default = 8'd80;
                endcase
            9:  case (param)
                    0: bank2_default = 8'd190;
                    1: bank2_default = 8'd100;
                    7: bank2_default = 8'd90;
                endcase
            10: if (param==0) bank2_default = 8'd64;
        endcase
    endfunction

    // ---- Bank 3 : AMBIENT ----------------------------------------
    // Clean, wide, and spacious — heavy chorus, cathedral reverb,
    // long delay, no distortion.
    function automatic logic [PARAM_W-1:0]
            bank3_default(input int fx, input int param);
        bank3_default = '0;
        case (fx)
            0:  if (param==0) bank3_default = 8'd128;
            1:  case (param)
                    0: bank3_default = 8'd1; 
                    1: bank3_default = 8'd40;
                    2: bank3_default = 8'd200;
                endcase
            2:  case (param)
                    0: bank3_default = 8'd30;
                    1: bank3_default = 8'd120;
                    2: bank3_default = 8'd110;
                    3: bank3_default = 8'd100;
                endcase
            3:  case (param)
                    0: bank3_default = 8'd32;
                    1: bank3_default = 8'd0;                     // comp off
                    2: bank3_default = 8'd64;
                    3: bank3_default = 8'd128;
                    4: bank3_default = 8'd64;
                    5: bank3_default = 8'd64;
                endcase
            4:  case (param)
                    0: bank3_default = 8'd128;
                    1: bank3_default = 8'd64;
                    7: bank3_default = 8'd0;                     // distortion off
                endcase
            5:  case (param)
                    0: bank3_default = 8'd20;
                    1: bank3_default = 8'd110;
                    2: bank3_default = 8'd120;
                    3: bank3_default = 8'd90;                    // roll off highs
                endcase
            6:  case (param)
                    0: bank3_default = 8'd90;                    // slow rate
                    1: bank3_default = 8'd180;                   // deep
                    7: bank3_default = 8'd160;                   // mostly wet
                endcase
            7:  if (param==0) bank3_default = 8'd128;
            8:  case (param)
                    0: bank3_default = 8'd200;
                    1: bank3_default = 8'd140;
                    7: bank3_default = 8'd100;
                endcase
            9:  case (param)
                    0: bank3_default = 8'd230;                   // huge room
                    1: bank3_default = 8'd80;                    // low damping
                    7: bank3_default = 8'd150;
                endcase
            10: if (param==0) bank3_default = 8'd120;
        endcase
    endfunction

    // ---- Public entry-point ----------------------------------------
    // Use in controller.sv reset block:
    //   all_params[k][i][j] <= param_default(k, i, j);
    // Adding a bank = add a helper above + one case arm here.
    function automatic logic [PARAM_W-1:0]
            param_default(input int bank, input int fx, input int param);
        case (bank)
            0:       param_default = bank0_default(fx, param);
            1:       param_default = bank1_default(fx, param);
            2:       param_default = bank2_default(fx, param);
            3:       param_default = bank3_default(fx, param);
            default: param_default = bank0_default(fx, param);  // fallback = clean
        endcase
    endfunction

    // ----------------------------------------------------------------
    // 3. Seven-Segment Display Encodings
    // ----------------------------------------------------------------

    parameter SEVSEG_SEG_BLANK = 7'b1111111;
    parameter SEVSEG_SEG_LINE  = 7'b0111111;

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

    parameter SEVSEG_SEG_R     = 7'b0101111;
    parameter SEVSEG_SEG_P     = 7'b0001100;
    parameter SEVSEG_SEG_UP    = 7'b1011100;
    parameter SEVSEG_SEG_DOWN  = 7'b1100011;
    parameter SEVSEG_SEG_SHARP = 7'b0011100;
    parameter SEVSEG_SEG_G     = 7'b0010000;

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

    parameter FX_STAGES = 11;

    parameter COMP_LOOKAHEAD         = 16;
    parameter logic [15:0] UNITY_Q15 = 16'h7FFF;
    parameter logic [15:0] MIN_GAIN  = 16'd100;

    parameter MAX_SAMPLES        = 24000;
    parameter MIN_DELAY_MS       = 50;
    parameter MAX_DELAY_MS       = 500;
    parameter MIN_DELAY_SAMPLES  = (MIN_DELAY_MS * SAMPLE_RATE) / 1000;
    parameter MAX_DELAY_SAMPLES  = (MAX_DELAY_MS * SAMPLE_RATE) / 1000;
    parameter DELAY_RANGE        = MAX_DELAY_SAMPLES - MIN_DELAY_SAMPLES;
    parameter TIMEOUT_CYCLES     = 100_000_000;

    // ----------------------------------------------------------------
    // 5. Common DSP Functions
    // ----------------------------------------------------------------

    function automatic signed [15:0] sat16(input signed [31:0] x);
        if      (x > 32'sd32767)  sat16 = 16'sh7FFF;
        else if (x < -32'sd32768) sat16 = -16'sh8000;
        else                      sat16 = x[15:0];
    endfunction

endpackage