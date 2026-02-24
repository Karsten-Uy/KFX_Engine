module tuner_ui (
    input  logic [11:0] best_lag,
    input  logic        mode_sel,   // 0 = frequency display, 1 = note display
    output logic [4:0]  tuner_vals [5:0]
);
    import lab_pkg::*;

    // -----------------------------------------------------------------------
    // Frequency calculation
    // 96000 = 0x17700 — needs 17 bits minimum, use 21 to be safe
    // -----------------------------------------------------------------------
    logic [20:0] frequency;
    logic [3:0]  ones, tens, hundreds, thousands;

    always_comb begin
        frequency = (best_lag > 12'd0) ? (21'd96000 / {9'b0, best_lag}) : 21'd0;

        thousands = (frequency / 1000) % 10;
        hundreds  = (frequency / 100)  % 10;
        tens      = (frequency / 10)   % 10;
        ones      =  frequency         % 10;
    end

    // -----------------------------------------------------------------------
    // Note detection via lag comparison
    //
    // Target lags: 96000 / open-string frequency
    //   E2 = 82.41 Hz  → lag 1165
    //   A2 = 110.00 Hz → lag  873
    //   D3 = 146.83 Hz → lag  654
    //   G3 = 196.00 Hz → lag  490
    //   B3 = 246.94 Hz → lag  389
    //   E4 = 329.63 Hz → lag  291
    //
    // Range boundaries are midpoints between adjacent target lags:
    //   E4 < 340 <= B3 < 440 <= G3 < 572 <= D3 < 764 <= A2 < 1019 <= E2
    //
    // Tuning tolerance ±3% of target lag (~±50 cents, half a semitone):
    //   In-tune window shown as LINE on HEX0.
    //   Lag too high (freq too low)  → need to tighten string → show UP
    //   Lag too low  (freq too high) → need to loosen string  → show DOWN
    // -----------------------------------------------------------------------

    // Note encoding for HEX (letter + octave)
    // Using hex digits as letters where possible:
    //   E → index 14 (SEVSEG_SEG_E)
    //   A → index 10 (SEVSEG_SEG_A)
    //   D → index 13 (SEVSEG_SEG_D)
    //   G → index  6 (digit '6' visually resembles lowercase 'G' on 7-seg)
    //   b → index 11 (SEVSEG_SEG_B, lowercase b)
    // Octave → plain digit index (2, 3, 4)

    typedef struct packed {
        logic [4:0] letter;   // sevseg index for note letter
        logic [4:0] octave;   // sevseg index for octave digit
        logic [11:0] target;  // ideal lag
        logic [11:0] tol;     // ±tolerance in lag counts
    } note_t;

    // Six guitar open strings
    localparam note_t NOTE_E2 = '{5'd14, 5'd2, 12'd1165, 12'd35};
    localparam note_t NOTE_A2 = '{5'd10, 5'd2, 12'd873,  12'd26};
    localparam note_t NOTE_D3 = '{5'd13, 5'd3, 12'd654,  12'd20};
    localparam note_t NOTE_G3 = '{5'd6,  5'd3, 12'd490,  12'd15};
    localparam note_t NOTE_B3 = '{5'd11, 5'd3, 12'd389,  12'd12};
    localparam note_t NOTE_E4 = '{5'd14, 5'd4, 12'd291,  12'd9};

    note_t nearest;
    logic [4:0] indicator;

    always_comb begin
        // ---- Nearest note by lag range (midpoint boundaries) ----
        if      (best_lag < 12'd340)  nearest = NOTE_E4;
        else if (best_lag < 12'd440)  nearest = NOTE_B3;
        else if (best_lag < 12'd572)  nearest = NOTE_G3;
        else if (best_lag < 12'd764)  nearest = NOTE_D3;
        else if (best_lag < 12'd1019) nearest = NOTE_A2;
        else                          nearest = NOTE_E2;

        // ---- Tuning indicator for HEX0 ----
        // lag within tolerance → in tune
        // lag > target+tol    → freq too low → tighten → UP arrow
        // lag < target-tol    → freq too high → loosen → DOWN arrow
        if (best_lag == 12'd0) begin
            indicator = SEVSEG_LINE_INDEX;          // no signal — show dash
        end else if (best_lag >= (nearest.target - nearest.tol) &&
                     best_lag <= (nearest.target + nearest.tol)) begin
            indicator = SEVSEG_LINE_INDEX;          // in tune
        end else if (best_lag > nearest.target) begin
            indicator = SEVSEG_UP_INDEX;            // too flat  → tune up
        end else begin
            indicator = SEVSEG_DOWN_INDEX;          // too sharp → tune down
        end
    end

    // -----------------------------------------------------------------------
    // Output mux — frequency vs note mode
    // -----------------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < 6; i++) tuner_vals[i] = SEVSEG_BLANK_INDEX;

        if (mode_sel) begin
            // ---- Frequency mode: Fr XXX ----
            tuner_vals[5] = 5'hF;           // 'F'
            tuner_vals[4] = SEVSEG_R_INDEX; // 'r'

            if (frequency != 21'd0) begin
                if (thousands != 4'd0)
                    tuner_vals[3] = {1'b0, thousands};
                tuner_vals[2] = {1'b0, hundreds};
                tuner_vals[1] = {1'b0, tens};
                tuner_vals[0] = {1'b0, ones};
            end else begin
                // No signal — show dashes on lower four digits
                for (int i = 0; i < 4; i++) tuner_vals[i] = SEVSEG_LINE_INDEX;
            end

        end else begin
            // ---- Note mode: [blank] [letter] [octave] [blank] [blank] [indicator] ----
            //
            // Example display for G3 in tune:
            //   HEX5=blank  HEX4='6'(G)  HEX3='3'  HEX2=blank  HEX1=blank  HEX0=LINE
            // Example for B3 sharp (too high, loosen):
            //   HEX5=blank  HEX4='b'     HEX3='3'  HEX2=blank  HEX1=blank  HEX0=DOWN

            if (best_lag != 'd0) begin
                tuner_vals[4] = nearest.letter;
                tuner_vals[3] = nearest.octave;
                tuner_vals[0] = indicator;
            end else begin
                // No signal — all dashes
                for (int i = 0; i < 6; i++) tuner_vals[i] = SEVSEG_LINE_INDEX;
            end
        end
    end

endmodule