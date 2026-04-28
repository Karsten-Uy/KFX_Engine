/*
 * tuner_display.sv
 *
 * Converts a Q12.4 lag value from tuner_yin_engine into six 7-segment
 * display indices.  Two modes selectable via mode_sel:
 *
 *   Note mode  (mode_sel = 0)
 *     Identifies the nearest chromatic note in D#2..F4 and shows:
 *       HEX5 = note letter        HEX4 = '#' (or blank)
 *       HEX3 = octave digit       HEX2 = '-' if flat (else blank)
 *       HEX1 = cents tens digit   HEX0 = cents units digit
 *     "00" with no sign means in tune.
 *     All six digits show LINE when best_lag_q4 == 0 (no signal).
 *
 *   Frequency mode  (mode_sel = 1)
 *     Displays the computed frequency in Hz:
 *       HEX5 = 'F'   HEX4 = 'r'   HEX3..HEX0 = digits (leading 0 blanked)
 *     When best_lag_q4 == 0, HEX3..HEX0 show LINE.
 *
 * Lag-to-frequency conversion
 * ---------------------------
 *   The tuner engine runs at 96 kHz effective sample rate, so
 *     frequency = 96000 / lag_int     (where lag_int = best_lag_q4 >> 4)
 *
 * Cents computation
 * -----------------
 *   For small offsets,
 *     cents ≈ 1731 · (target_q4 - measured_q4) / target_q4
 *   We avoid a runtime divide by storing per-note  inv_factor_q16  =
 *   round(1731 · 65536 / target_q4)  in the note table, then
 *     cents = (diff_q4 · inv_factor_q16) >>> 16
 *   Convention: positive cents = sharp, negative = flat.
 *
 * Note lookup
 * -----------
 *   Boundaries placed at the integer-lag midpoint between adjacent
 *   target lags.  Priority order is highest pitch first (smallest lag)
 *   so the first matching condition wins.  Lookup uses the integer
 *   part of best_lag_q4.
 *
 * Ports
 * -----
 *   best_lag_q4 — 16-bit Q12.4 fundamental period from tuner_yin_engine
 *                 (0 = no signal)
 *   mode_sel    — 0 = note + cents display, 1 = frequency display
 *   tuner_vals  — six 5-bit indices for sevseg_display, [5] = leftmost
 */

module tuner_display (
    input  logic [15:0] best_lag_q4,
    input  logic        mode_sel,
    output logic [4:0]  tuner_vals [5:0]
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Frequency Calculation  (uses integer part of best_lag_q4)
    // ----------------------------------------------------------------

    logic [11:0] best_lag_int;
    logic [20:0] frequency;
    logic [3:0]  ones, tens, hundreds, thousands;

    assign best_lag_int = best_lag_q4[15:4];

    always_comb begin
        frequency = (best_lag_int > 12'd0) ? (21'd96000 / {9'b0, best_lag_int}) : 21'd0;
        thousands = (frequency / 1000) % 10;
        hundreds  = (frequency / 100)  % 10;
        tens      = (frequency / 10)   % 10;
        ones      =  frequency         % 10;
    end

    // ----------------------------------------------------------------
    // Chromatic Note Table
    //
    //   target          ideal lag (= 96000 / note_hz)
    //   inv_factor_q16  round(1731 · 65536 / (target · 16))
    //                   = round(1731 · 4096 / target)
    //                   used for the cents calculation:
    //                     cents = (diff_q4 · inv_factor_q16) >>> 16
    //                   where diff_q4 = (target << 4) - measured_q4
    // ----------------------------------------------------------------

    typedef struct packed {
        logic [4:0]  letter;
        logic        is_sharp;
        logic [4:0]  octave;
        logic [11:0] target;
        logic [15:0] inv_factor_q16;
    } note_t;

    // ---- Octave 2 ----
    localparam note_t N_Ds2 = '{5'd13,          1'b1, 5'd2, 12'd1234, 16'd5746};
    localparam note_t N_E2  = '{5'd14,          1'b0, 5'd2, 12'd1165, 16'd6086};
    localparam note_t N_F2  = '{5'd15,          1'b0, 5'd2, 12'd1099, 16'd6451};
    localparam note_t N_Fs2 = '{5'd15,          1'b1, 5'd2, 12'd1038, 16'd6829};
    localparam note_t N_G2  = '{SEVSEG_G_INDEX, 1'b0, 5'd2, 12'd980,  16'd7233};
    localparam note_t N_Gs2 = '{SEVSEG_G_INDEX, 1'b1, 5'd2, 12'd925,  16'd7664};
    localparam note_t N_A2  = '{5'd10,          1'b0, 5'd2, 12'd873,  16'd8120};
    localparam note_t N_As2 = '{5'd10,          1'b1, 5'd2, 12'd824,  16'd8602};
    localparam note_t N_B2  = '{5'd11,          1'b0, 5'd2, 12'd777,  16'd9123};
    // ---- Octave 3 ----
    localparam note_t N_C3  = '{5'd12,          1'b0, 5'd3, 12'd734,  16'd9657};
    localparam note_t N_Cs3 = '{5'd12,          1'b1, 5'd3, 12'd693,  16'd10228};
    localparam note_t N_D3  = '{5'd13,          1'b0, 5'd3, 12'd654,  16'd10838};
    localparam note_t N_Ds3 = '{5'd13,          1'b1, 5'd3, 12'd617,  16'd11488};
    localparam note_t N_E3  = '{5'd14,          1'b0, 5'd3, 12'd583,  16'd12158};
    localparam note_t N_F3  = '{5'd15,          1'b0, 5'd3, 12'd550,  16'd12888};
    localparam note_t N_Fs3 = '{5'd15,          1'b1, 5'd3, 12'd519,  16'd13662};
    localparam note_t N_G3  = '{SEVSEG_G_INDEX, 1'b0, 5'd3, 12'd490,  16'd14470};
    localparam note_t N_Gs3 = '{SEVSEG_G_INDEX, 1'b1, 5'd3, 12'd462,  16'd15347};
    localparam note_t N_A3  = '{5'd10,          1'b0, 5'd3, 12'd436,  16'd16258};
    localparam note_t N_As3 = '{5'd10,          1'b1, 5'd3, 12'd412,  16'd17205};
    localparam note_t N_B3  = '{5'd11,          1'b0, 5'd3, 12'd389,  16'd18221};
    // ---- Octave 4 ----
    localparam note_t N_C4  = '{5'd12,          1'b0, 5'd4, 12'd367,  16'd19314};
    localparam note_t N_Cs4 = '{5'd12,          1'b1, 5'd4, 12'd346,  16'd20489};
    localparam note_t N_D4  = '{5'd13,          1'b0, 5'd4, 12'd327,  16'd21680};
    localparam note_t N_Ds4 = '{5'd13,          1'b1, 5'd4, 12'd309,  16'd22943};
    localparam note_t N_E4  = '{5'd14,          1'b0, 5'd4, 12'd291,  16'd24360};
    localparam note_t N_F4  = '{5'd15,          1'b0, 5'd4, 12'd275,  16'd25777};

    // ----------------------------------------------------------------
    // Note Lookup  (uses integer best_lag)
    // ----------------------------------------------------------------

    note_t nearest;

    always_comb begin
        if      (best_lag_int < 12'd283)  nearest = N_F4;
        else if (best_lag_int < 12'd300)  nearest = N_E4;
        else if (best_lag_int < 12'd318)  nearest = N_Ds4;
        else if (best_lag_int < 12'd337)  nearest = N_D4;
        else if (best_lag_int < 12'd357)  nearest = N_Cs4;
        else if (best_lag_int < 12'd378)  nearest = N_C4;
        else if (best_lag_int < 12'd401)  nearest = N_B3;
        else if (best_lag_int < 12'd424)  nearest = N_As3;
        else if (best_lag_int < 12'd449)  nearest = N_A3;
        else if (best_lag_int < 12'd476)  nearest = N_Gs3;
        else if (best_lag_int < 12'd505)  nearest = N_G3;
        else if (best_lag_int < 12'd535)  nearest = N_Fs3;
        else if (best_lag_int < 12'd567)  nearest = N_F3;
        else if (best_lag_int < 12'd600)  nearest = N_E3;
        else if (best_lag_int < 12'd636)  nearest = N_Ds3;
        else if (best_lag_int < 12'd674)  nearest = N_D3;
        else if (best_lag_int < 12'd714)  nearest = N_Cs3;
        else if (best_lag_int < 12'd756)  nearest = N_C3;
        else if (best_lag_int < 12'd801)  nearest = N_B2;
        else if (best_lag_int < 12'd849)  nearest = N_As2;
        else if (best_lag_int < 12'd899)  nearest = N_A2;
        else if (best_lag_int < 12'd953)  nearest = N_Gs2;
        else if (best_lag_int < 12'd1009) nearest = N_G2;
        else if (best_lag_int < 12'd1069) nearest = N_Fs2;
        else if (best_lag_int < 12'd1132) nearest = N_F2;
        else if (best_lag_int < 12'd1200) nearest = N_E2;
        else                              nearest = N_Ds2;
    end

    // ----------------------------------------------------------------
    // Cents Calculation
    //
    //   diff_q4   = (target << 4) - measured_q4               (signed)
    //   prod      = diff_q4 · inv_factor_q16                  (signed)
    //   cents     = prod >>> 16                               (signed)
    //
    // Convention:
    //   diff_q4 > 0  ⇒  measured period < target  ⇒  pitch sharp ⇒  cents > 0
    //   diff_q4 < 0  ⇒  measured period > target  ⇒  pitch flat  ⇒  cents < 0
    //
    // Then split into sign-magnitude for the two-digit display.
    // ----------------------------------------------------------------

    logic signed [16:0] diff_q4;
    logic signed [33:0] cents_prod;
    logic signed [9:0]  cents;
    logic               cents_neg;
    logic [6:0]         cents_mag;
    logic [3:0]         cents_tens, cents_units;

    assign diff_q4    = $signed({1'b0, nearest.target, 4'b0}) - $signed({1'b0, best_lag_q4});
    assign cents_prod = diff_q4 * $signed({1'b0, nearest.inv_factor_q16});
    assign cents      = cents_prod[25:16];                 // ≈ ±99 in normal use

    assign cents_neg  = cents[9];
    assign cents_mag   = cents_neg ? 7'(-cents) : 7'(cents);
    assign cents_tens  = 4'((cents_mag / 7'd10) % 4'd10);
    assign cents_units = 4'(cents_mag % 7'd10);

    // ----------------------------------------------------------------
    // Output Mux
    //
    // Note mode layout:
    //   HEX5 = letter   HEX4 = '#' or blank   HEX3 = octave digit
    //   HEX2 = '-' if flat (else blank)
    //   HEX1 = cents tens   HEX0 = cents units
    //
    // Frequency mode layout:
    //   HEX5 = 'F'    HEX4 = 'r'    HEX3..HEX0 = Hz (leading zeros blanked)
    // ----------------------------------------------------------------

    always_comb begin
        for (int i = 0; i < 6; i++) tuner_vals[i] = SEVSEG_BLANK_INDEX;

        if (!mode_sel) begin
            if (best_lag_q4 != 16'd0) begin
                tuner_vals[5] = nearest.letter;
                tuner_vals[4] = nearest.is_sharp ? SEVSEG_SHARP_INDEX : SEVSEG_BLANK_INDEX;
                tuner_vals[3] = nearest.octave;
                tuner_vals[2] = cents_neg ? SEVSEG_LINE_INDEX : SEVSEG_BLANK_INDEX;
                tuner_vals[1] = {1'b0, cents_tens};
                tuner_vals[0] = {1'b0, cents_units};
            end else begin
                for (int i = 0; i < 6; i++) tuner_vals[i] = SEVSEG_LINE_INDEX;
            end

        end else begin
            tuner_vals[5] = 5'd15;          // 'F'
            tuner_vals[4] = SEVSEG_R_INDEX;

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
