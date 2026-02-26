module tuner_ui (
    input  logic [11:0] best_lag,
    input  logic        mode_sel,   // 0 = note display, 1 = frequency display
    output logic [4:0]  tuner_vals [5:0]
);
    import lab_pkg::*;

    // -----------------------------------------------------------------------
    // Frequency calculation  (96000 needs 17 bits, 21 is safe)
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
    // Chromatic note table
    //
    // Target lags = 96000 / note_freq_hz
    // Coverage: D#2 (lag 1234) up to F4 (lag 275) — slightly beyond E2..E4
    //
    // Note letters use package hex-digit indices where applicable:
    //   A=10  B=11  C=12  D=13  E=14  F=15  G=SEVSEG_G_INDEX(23)
    // Sharp flag drives HEX4; octave digit (2/3/4) goes on HEX3.
    // Tolerance = target >> 5  (~3.1%, ~half a semitone each side).
    // -----------------------------------------------------------------------
    typedef struct packed {
        logic [4:0]  letter;    // sevseg index for note name
        logic        is_sharp;
        logic [4:0]  octave;    // plain digit index (2, 3, or 4)
        logic [11:0] target;    // ideal lag
        logic [11:0] tol;       // ±tolerance (lag counts)
    } note_t;

    // ---- Octave 2 ----
    localparam note_t N_Ds2 = '{5'd13, 1'b1, 5'd2, 12'd1234, 12'd39}; // D#2 / Eb2
    localparam note_t N_E2  = '{5'd14, 1'b0, 5'd2, 12'd1165, 12'd36};
    localparam note_t N_F2  = '{5'd15, 1'b0, 5'd2, 12'd1099, 12'd34};
    localparam note_t N_Fs2 = '{5'd15, 1'b1, 5'd2, 12'd1038, 12'd32}; // F#2
    localparam note_t N_G2  = '{SEVSEG_G_INDEX, 1'b0, 5'd2, 12'd980,  12'd31};
    localparam note_t N_Gs2 = '{SEVSEG_G_INDEX, 1'b1, 5'd2, 12'd925,  12'd29}; // G#2
    localparam note_t N_A2  = '{5'd10, 1'b0, 5'd2, 12'd873,  12'd27};
    localparam note_t N_As2 = '{5'd10, 1'b1, 5'd2, 12'd824,  12'd26}; // A#2 / Bb2
    localparam note_t N_B2  = '{5'd11, 1'b0, 5'd2, 12'd777,  12'd24};
    // ---- Octave 3 ----
    localparam note_t N_C3  = '{5'd12, 1'b0, 5'd3, 12'd734,  12'd23};
    localparam note_t N_Cs3 = '{5'd12, 1'b1, 5'd3, 12'd693,  12'd22}; // C#3
    localparam note_t N_D3  = '{5'd13, 1'b0, 5'd3, 12'd654,  12'd20};
    localparam note_t N_Ds3 = '{5'd13, 1'b1, 5'd3, 12'd617,  12'd19}; // D#3 / Eb3
    localparam note_t N_E3  = '{5'd14, 1'b0, 5'd3, 12'd583,  12'd18};
    localparam note_t N_F3  = '{5'd15, 1'b0, 5'd3, 12'd550,  12'd17};
    localparam note_t N_Fs3 = '{5'd15, 1'b1, 5'd3, 12'd519,  12'd16}; // F#3
    localparam note_t N_G3  = '{SEVSEG_G_INDEX, 1'b0, 5'd3, 12'd490,  12'd15};
    localparam note_t N_Gs3 = '{SEVSEG_G_INDEX, 1'b1, 5'd3, 12'd462,  12'd14}; // G#3
    localparam note_t N_A3  = '{5'd10, 1'b0, 5'd3, 12'd436,  12'd14};
    localparam note_t N_As3 = '{5'd10, 1'b1, 5'd3, 12'd412,  12'd13}; // A#3 / Bb3
    localparam note_t N_B3  = '{5'd11, 1'b0, 5'd3, 12'd389,  12'd12};
    // ---- Octave 4 ----
    localparam note_t N_C4  = '{5'd12, 1'b0, 5'd4, 12'd367,  12'd11};
    localparam note_t N_Cs4 = '{5'd12, 1'b1, 5'd4, 12'd346,  12'd11}; // C#4
    localparam note_t N_D4  = '{5'd13, 1'b0, 5'd4, 12'd327,  12'd10};
    localparam note_t N_Ds4 = '{5'd13, 1'b1, 5'd4, 12'd309,  12'd10}; // D#4 / Eb4
    localparam note_t N_E4  = '{5'd14, 1'b0, 5'd4, 12'd291,  12'd9};
    localparam note_t N_F4  = '{5'd15, 1'b0, 5'd4, 12'd275,  12'd9};

    // -----------------------------------------------------------------------
    // Note lookup — midpoint boundaries between adjacent lags
    // -----------------------------------------------------------------------
    note_t  nearest;
    logic [4:0] indicator;

    always_comb begin
        // Priority: lowest lag (highest pitch) first
        if      (best_lag < 12'd283) nearest = N_F4;
        else if (best_lag < 12'd300) nearest = N_E4;
        else if (best_lag < 12'd318) nearest = N_Ds4;
        else if (best_lag < 12'd337) nearest = N_D4;
        else if (best_lag < 12'd357) nearest = N_Cs4;
        else if (best_lag < 12'd378) nearest = N_C4;
        else if (best_lag < 12'd401) nearest = N_B3;
        else if (best_lag < 12'd424) nearest = N_As3;
        else if (best_lag < 12'd449) nearest = N_A3;
        else if (best_lag < 12'd476) nearest = N_Gs3;
        else if (best_lag < 12'd505) nearest = N_G3;
        else if (best_lag < 12'd535) nearest = N_Fs3;
        else if (best_lag < 12'd567) nearest = N_F3;
        else if (best_lag < 12'd600) nearest = N_E3;
        else if (best_lag < 12'd636) nearest = N_Ds3;
        else if (best_lag < 12'd674) nearest = N_D3;
        else if (best_lag < 12'd714) nearest = N_Cs3;
        else if (best_lag < 12'd756) nearest = N_C3;
        else if (best_lag < 12'd801) nearest = N_B2;
        else if (best_lag < 12'd849) nearest = N_As2;
        else if (best_lag < 12'd899) nearest = N_A2;
        else if (best_lag < 12'd953) nearest = N_Gs2;
        else if (best_lag < 12'd1009) nearest = N_G2;
        else if (best_lag < 12'd1069) nearest = N_Fs2;
        else if (best_lag < 12'd1132) nearest = N_F2;
        else if (best_lag < 12'd1200) nearest = N_E2;
        else                          nearest = N_Ds2;

        // ---- Tuning indicator ----
        // lag == 0          → no signal → dash
        // within ±tol       → in tune   → LINE
        // lag > target+tol  → too flat  → UP   (tighten)
        // lag < target-tol  → too sharp → DOWN (loosen)
        if (best_lag == 12'd0) begin
            indicator = SEVSEG_LINE_INDEX;
        end else if (best_lag >= (nearest.target - nearest.tol) &&
                     best_lag <= (nearest.target + nearest.tol)) begin
            indicator = SEVSEG_LINE_INDEX;
        end else if (best_lag > nearest.target) begin
            indicator = SEVSEG_UP_INDEX;
        end else begin
            indicator = SEVSEG_DOWN_INDEX;
        end
    end

    // -----------------------------------------------------------------------
    // Output mux — note mode (0) vs frequency mode (1)
    //
    // Note mode layout:
    //   HEX5 = letter   HEX4 = '#' or blank   HEX3 = octave
    //   HEX2 = blank    HEX1 = blank           HEX0 = indicator
    //
    // Frequency mode layout:
    //   HEX5 = 'F'   HEX4 = 'r'   HEX3..HEX0 = digits (zero-blanked)
    // -----------------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < 6; i++) tuner_vals[i] = SEVSEG_BLANK_INDEX;

        if (!mode_sel) begin
            // ---- Note mode ----
            if (best_lag != 12'd0) begin
                tuner_vals[5] = nearest.letter;
                tuner_vals[4] = nearest.is_sharp ? SEVSEG_SHARP_INDEX
                                                  : SEVSEG_BLANK_INDEX;
                tuner_vals[3] = nearest.octave;
                // HEX2, HEX1 stay blank
                tuner_vals[0] = indicator;
            end else begin
                for (int i = 0; i < 6; i++) tuner_vals[i] = SEVSEG_LINE_INDEX;
            end

        end else begin
            // ---- Frequency mode ----
            tuner_vals[5] = 5'd15;           // 'F'
            tuner_vals[4] = SEVSEG_R_INDEX;  // 'r'

            if (frequency != 21'd0) begin
                if (thousands != 4'd0)
                    tuner_vals[3] = {1'b0, thousands};
                tuner_vals[2] = {1'b0, hundreds};
                tuner_vals[1] = {1'b0, tens};
                tuner_vals[0] = {1'b0, ones};
            end else begin
                for (int i = 0; i < 4; i++) tuner_vals[i] = SEVSEG_LINE_INDEX;
            end
        end
    end

endmodule