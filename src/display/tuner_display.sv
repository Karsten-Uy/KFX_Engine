/*
 * tuner_display.sv
 *
 * Converts a Q12.4 lag value from tuner_yin_engine into six 7-segment
 * display indices.  Two modes selectable via mode_sel:
 *
 *   Note mode  (mode_sel = 0)
 *     Identifies the nearest chromatic note in D#2..F4 and shows:
 *       HEX5 = note letter   HEX4 = '#' (or blank)
 *       HEX3 = octave digit  HEX2 = blank
 *       HEX1 = blank         HEX0 = tuning indicator
 *     Indicator: '^' = flat (tighten), 'V' = sharp (loosen),
 *                '-' = in tune (within IN_TUNE_CENTS).
 *     All six digits show LINE when best_lag_q4 == 0 (no signal).
 *
 *   Frequency mode  (mode_sel = 1)
 *     Displays the computed frequency in Hz:
 *       HEX5 = 'F'   HEX4 = 'r'   HEX3..HEX0 = digits (leading 0 blanked)
 *     When best_lag_q4 == 0, HEX3..HEX0 show LINE.
 *
 * Note classification + hysteresis
 * --------------------------------
 *   Boundaries are stored as Q12.4 geometric means between adjacent
 *   note targets (50 cents from each note centre).  A naïve "pick the
 *   nearest" classifier flickers between adjacent notes when the lag
 *   sits near a boundary, since each YIN update has a few cents of
 *   jitter.  We keep a `held_note` register and only switch when the
 *   lag drifts farther than SWITCH_CENTS from the held note's target —
 *   i.e. SWITCH_CENTS - 50 cents past the geometric-mean boundary.
 *
 * Cents computation
 * -----------------
 *   For small offsets,
 *     cents ≈ 1731 · (target_q4 - measured_q4) / target_q4
 *   We avoid a runtime divide by storing per-note inv_factor_q16 =
 *   round(1731 · 4096 / target) in the note table, then
 *     cents = (diff_q4 · inv_factor_q16) >>> 16
 *   Convention: positive cents = sharp, negative = flat.
 *
 * Pipeline
 * --------
 *   Stage 0 — boundary lookup → candidate
 *   Stage 1 — register candidate, lag, validity
 *   Stage 2 — cents-vs-held + hysteresis update + frequency divide
 *   Stage 3 — registered output mux
 */

module tuner_display (
    input  logic        clk,
    input  logic        reset_n,
    input  logic [15:0] best_lag_q4,
    input  logic        mode_sel,
    output logic [4:0]  tuner_vals [5:0]
);

    import lab_pkg::*;

    // ±5 cents window counts as "in tune"
    localparam int IN_TUNE_CENTS = 5;
    // Boundary sits at ~50 cents.  60 = 10-cent hysteresis margin past
    // the boundary before we accept a switch to the adjacent note.
    localparam int SWITCH_CENTS  = 60;

    // ----------------------------------------------------------------
    // Chromatic Note Table
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
    // Stage 0  (combinational) — Boundary lookup
    // ----------------------------------------------------------------

    note_t candidate_c;
    logic  signal_ok_c;

    assign signal_ok_c = (best_lag_q4 != 16'd0);

    always_comb begin
        if      (best_lag_q4 < 16'd4527)  candidate_c = N_F4;
        else if (best_lag_q4 < 16'd4799)  candidate_c = N_E4;
        else if (best_lag_q4 < 16'd5085)  candidate_c = N_Ds4;
        else if (best_lag_q4 < 16'd5382)  candidate_c = N_D4;
        else if (best_lag_q4 < 16'd5701)  candidate_c = N_Cs4;
        else if (best_lag_q4 < 16'd6045)  candidate_c = N_C4;
        else if (best_lag_q4 < 16'd6404)  candidate_c = N_B3;
        else if (best_lag_q4 < 16'd6782)  candidate_c = N_As3;
        else if (best_lag_q4 < 16'd7181)  candidate_c = N_A3;
        else if (best_lag_q4 < 16'd7611)  candidate_c = N_Gs3;
        else if (best_lag_q4 < 16'd8069)  candidate_c = N_G3;
        else if (best_lag_q4 < 16'd8546)  candidate_c = N_Fs3;
        else if (best_lag_q4 < 16'd9059)  candidate_c = N_F3;
        else if (best_lag_q4 < 16'd9596)  candidate_c = N_E3;
        else if (best_lag_q4 < 16'd10166) candidate_c = N_Ds3;
        else if (best_lag_q4 < 16'd10774) candidate_c = N_D3;
        else if (best_lag_q4 < 16'd11411) candidate_c = N_Cs3;
        else if (best_lag_q4 < 16'd12084) candidate_c = N_C3;
        else if (best_lag_q4 < 16'd12803) candidate_c = N_B2;
        else if (best_lag_q4 < 16'd13571) candidate_c = N_As2;
        else if (best_lag_q4 < 16'd14378) candidate_c = N_A2;
        else if (best_lag_q4 < 16'd15233) candidate_c = N_Gs2;
        else if (best_lag_q4 < 16'd16139) candidate_c = N_G2;
        else if (best_lag_q4 < 16'd17092) candidate_c = N_Fs2;
        else if (best_lag_q4 < 16'd18104) candidate_c = N_F2;
        else if (best_lag_q4 < 16'd19185) candidate_c = N_E2;
        else                              candidate_c = N_Ds2;
    end

    // ----------------------------------------------------------------
    // Stage 1  (registered) — Latch candidate, lag, validity
    // ----------------------------------------------------------------

    note_t       candidate_s1;
    logic [15:0] best_lag_q4_s1;
    logic [11:0] best_lag_int_s1;
    logic        signal_ok_s1;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            candidate_s1    <= '0;
            best_lag_q4_s1  <= '0;
            best_lag_int_s1 <= '0;
            signal_ok_s1    <= 1'b0;
        end else begin
            candidate_s1    <= candidate_c;
            best_lag_q4_s1  <= best_lag_q4;
            best_lag_int_s1 <= best_lag_q4[15:4];
            signal_ok_s1    <= signal_ok_c;
        end
    end

    // ----------------------------------------------------------------
    // Stage 2  (combinational compute against held_note)
    //   • cents_c — for hysteresis decision *and* for the indicator
    //   • frequency_c — combinational divide
    // ----------------------------------------------------------------

    note_t held_note;
    logic  held_valid;

    logic signed [16:0] diff_q4_c;
    logic signed [33:0] cents_prod_c;
    logic signed [9:0]  cents_c;
    logic [20:0]        frequency_c;

    assign diff_q4_c    = $signed({1'b0, held_note.target, 4'b0}) -
                          $signed({1'b0, best_lag_q4_s1});
    assign cents_prod_c = diff_q4_c * $signed({1'b0, held_note.inv_factor_q16});
    assign cents_c      = cents_prod_c[25:16];

    assign frequency_c  = (best_lag_int_s1 > 12'd0)
                              ? (21'd96000 / {9'b0, best_lag_int_s1})
                              : 21'd0;

    logic should_switch;
    assign should_switch = (cents_c >  $signed(10'(SWITCH_CENTS))) ||
                           (cents_c < -$signed(10'(SWITCH_CENTS)));

    // ----------------------------------------------------------------
    // Stage 2  (registered) — Hysteresis update + display registers
    //
    // held_note keeps its value unless |cents_c| > SWITCH_CENTS, at
    // which point we adopt the freshly-computed candidate.  On the
    // switch cycle the indicator shows LINE; the next cycle it
    // refreshes against the new held_note for accurate ^/V/-.
    // ----------------------------------------------------------------

    note_t       displayed_note_s2;
    logic        signal_ok_s2;
    logic        mode_sel_s2;
    logic [4:0]  indicator_s2;
    logic [20:0] frequency_s2;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            held_note         <= '0;
            held_valid        <= 1'b0;
            displayed_note_s2 <= '0;
            signal_ok_s2      <= 1'b0;
            mode_sel_s2       <= 1'b0;
            indicator_s2      <= SEVSEG_BLANK_INDEX;
            frequency_s2      <= '0;
        end else begin
            signal_ok_s2 <= signal_ok_s1;
            mode_sel_s2  <= mode_sel;
            frequency_s2 <= frequency_c;

            if (!signal_ok_s1) begin
                held_valid        <= 1'b0;
                displayed_note_s2 <= '0;
                indicator_s2      <= SEVSEG_BLANK_INDEX;
            end else if (!held_valid || should_switch) begin
                held_note         <= candidate_s1;
                held_valid        <= 1'b1;
                displayed_note_s2 <= candidate_s1;
                indicator_s2      <= SEVSEG_LINE_INDEX;
            end else begin
                displayed_note_s2 <= held_note;
                if      (cents_c >  $signed(10'(IN_TUNE_CENTS)))
                    indicator_s2 <= SEVSEG_DOWN_INDEX;
                else if (cents_c < -$signed(10'(IN_TUNE_CENTS)))
                    indicator_s2 <= SEVSEG_UP_INDEX;
                else
                    indicator_s2 <= SEVSEG_LINE_INDEX;
            end
        end
    end

    // Frequency BCD digits
    logic [3:0] f_thousands, f_hundreds, f_tens, f_ones;
    assign f_thousands = 4'((frequency_s2 / 21'd1000) % 21'd10);
    assign f_hundreds  = 4'((frequency_s2 / 21'd100)  % 21'd10);
    assign f_tens      = 4'((frequency_s2 / 21'd10)   % 21'd10);
    assign f_ones      = 4'( frequency_s2             % 21'd10);

    // ----------------------------------------------------------------
    // Stage 3  (registered output) — Mode-dependent layout
    // ----------------------------------------------------------------

    logic [4:0] tuner_vals_n [5:0];

    always_comb begin
        for (int i = 0; i < 6; i++) tuner_vals_n[i] = SEVSEG_BLANK_INDEX;

        if (!mode_sel_s2) begin
            if (signal_ok_s2) begin
                tuner_vals_n[5] = displayed_note_s2.letter;
                tuner_vals_n[4] = displayed_note_s2.is_sharp ? SEVSEG_SHARP_INDEX
                                                             : SEVSEG_BLANK_INDEX;
                tuner_vals_n[3] = displayed_note_s2.octave;
                tuner_vals_n[2] = SEVSEG_BLANK_INDEX;
                tuner_vals_n[1] = SEVSEG_BLANK_INDEX;
                tuner_vals_n[0] = indicator_s2;
            end else begin
                for (int i = 0; i < 6; i++) tuner_vals_n[i] = SEVSEG_LINE_INDEX;
            end
        end else begin
            tuner_vals_n[5] = 5'd15;            // 'F'
            tuner_vals_n[4] = SEVSEG_R_INDEX;
            if (frequency_s2 != 21'd0) begin
                if (f_thousands != 4'd0)
                    tuner_vals_n[3] = {1'b0, f_thousands};
                tuner_vals_n[2] = {1'b0, f_hundreds};
                tuner_vals_n[1] = {1'b0, f_tens};
                tuner_vals_n[0] = {1'b0, f_ones};
            end else begin
                for (int i = 0; i < 4; i++) tuner_vals_n[i] = SEVSEG_LINE_INDEX;
            end
        end
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            for (int i = 0; i < 6; i++) tuner_vals[i] <= SEVSEG_BLANK_INDEX;
        end else begin
            for (int i = 0; i < 6; i++) tuner_vals[i] <= tuner_vals_n[i];
        end
    end

endmodule
