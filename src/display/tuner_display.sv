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
 *   frequency = 96000 / (best_lag_q4 >> 4)
 *
 * Cents computation
 * -----------------
 *   For small offsets,
 *     cents ≈ 1731 · (target_q4 - measured_q4) / target_q4
 *   We avoid a runtime divide by storing per-note  inv_factor_q16  =
 *   round(1731 · 4096 / target)  in the note table, then
 *     cents = (diff_q4 · inv_factor_q16) >>> 16
 *   Convention: positive cents = sharp, negative = flat.
 *
 * Pipeline
 * --------
 *   The lookup, multiply, and BCD divides are pushed through three
 *   pipeline stages (lookup → cents/freq compute → BCD digits).
 *   Without these registers Quartus has to fit a 17×17 multiplier,
 *   a 28-way priority MUX, and a chain of constant divisions in
 *   one combinational web — the fitter time blows up.  At ~50 MHz
 *   the three-stage delay is 60 ns total, invisible on a 7-segment.
 *
 * Ports
 * -----
 *   clk, reset_n
 *   best_lag_q4 — 16-bit Q12.4 lag from tuner_yin_engine (0 = no signal)
 *   mode_sel    — 0 = note + cents display, 1 = frequency display
 *   tuner_vals  — six 5-bit indices for sevseg_display, [5] = leftmost
 */

module tuner_display (
    input  logic        clk,
    input  logic        reset_n,
    input  logic [15:0] best_lag_q4,
    input  logic        mode_sel,
    output logic [4:0]  tuner_vals [5:0]
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Chromatic Note Table
    //
    //   target          ideal lag (= 96000 / note_hz)
    //   inv_factor_q16  round(1731 · 4096 / target), used as
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
    // Stage 0  (combinational)
    //   • Note lookup from integer lag
    //   • Lag and validity captured for the next stage
    // ----------------------------------------------------------------

    logic [11:0] best_lag_int;
    note_t       nearest_c;
    logic        signal_ok_c;

    assign best_lag_int = best_lag_q4[15:4];
    assign signal_ok_c  = (best_lag_q4 != 16'd0);

    always_comb begin
        if      (best_lag_int < 12'd283)  nearest_c = N_F4;
        else if (best_lag_int < 12'd300)  nearest_c = N_E4;
        else if (best_lag_int < 12'd318)  nearest_c = N_Ds4;
        else if (best_lag_int < 12'd337)  nearest_c = N_D4;
        else if (best_lag_int < 12'd357)  nearest_c = N_Cs4;
        else if (best_lag_int < 12'd378)  nearest_c = N_C4;
        else if (best_lag_int < 12'd401)  nearest_c = N_B3;
        else if (best_lag_int < 12'd424)  nearest_c = N_As3;
        else if (best_lag_int < 12'd449)  nearest_c = N_A3;
        else if (best_lag_int < 12'd476)  nearest_c = N_Gs3;
        else if (best_lag_int < 12'd505)  nearest_c = N_G3;
        else if (best_lag_int < 12'd535)  nearest_c = N_Fs3;
        else if (best_lag_int < 12'd567)  nearest_c = N_F3;
        else if (best_lag_int < 12'd600)  nearest_c = N_E3;
        else if (best_lag_int < 12'd636)  nearest_c = N_Ds3;
        else if (best_lag_int < 12'd674)  nearest_c = N_D3;
        else if (best_lag_int < 12'd714)  nearest_c = N_Cs3;
        else if (best_lag_int < 12'd756)  nearest_c = N_C3;
        else if (best_lag_int < 12'd801)  nearest_c = N_B2;
        else if (best_lag_int < 12'd849)  nearest_c = N_As2;
        else if (best_lag_int < 12'd899)  nearest_c = N_A2;
        else if (best_lag_int < 12'd953)  nearest_c = N_Gs2;
        else if (best_lag_int < 12'd1009) nearest_c = N_G2;
        else if (best_lag_int < 12'd1069) nearest_c = N_Fs2;
        else if (best_lag_int < 12'd1132) nearest_c = N_F2;
        else if (best_lag_int < 12'd1200) nearest_c = N_E2;
        else                              nearest_c = N_Ds2;
    end

    // ----------------------------------------------------------------
    // Stage 1  (registered)
    //   • Latch nearest, lag, signal-ok flag
    //   • Compute cents and integer frequency
    // ----------------------------------------------------------------

    note_t              nearest_s1;
    logic [15:0]        best_lag_q4_s1;
    logic [11:0]        best_lag_int_s1;
    logic               signal_ok_s1;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            nearest_s1      <= '0;
            best_lag_q4_s1  <= '0;
            best_lag_int_s1 <= '0;
            signal_ok_s1    <= 1'b0;
        end else begin
            nearest_s1      <= nearest_c;
            best_lag_q4_s1  <= best_lag_q4;
            best_lag_int_s1 <= best_lag_int;
            signal_ok_s1    <= signal_ok_c;
        end
    end

    // Combinational compute on Stage 1's registered inputs
    logic signed [16:0] diff_q4_c;
    logic signed [33:0] cents_prod_c;
    logic signed [9:0]  cents_c;
    logic [20:0]        frequency_c;

    assign diff_q4_c    = $signed({1'b0, nearest_s1.target, 4'b0}) -
                          $signed({1'b0, best_lag_q4_s1});
    assign cents_prod_c = diff_q4_c * $signed({1'b0, nearest_s1.inv_factor_q16});
    assign cents_c      = cents_prod_c[25:16];

    assign frequency_c  = (best_lag_int_s1 > 12'd0)
                              ? (21'd96000 / {9'b0, best_lag_int_s1})
                              : 21'd0;

    // ----------------------------------------------------------------
    // Stage 2  (registered)
    //   • Latch cents and frequency
    //   • BCD digits computed combinationally on the cheap (small Wb)
    // ----------------------------------------------------------------

    note_t       nearest_s2;
    logic        signal_ok_s2;
    logic        mode_sel_s2;
    logic signed [9:0] cents_s2;
    logic [20:0] frequency_s2;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            nearest_s2   <= '0;
            signal_ok_s2 <= 1'b0;
            mode_sel_s2  <= 1'b0;
            cents_s2     <= '0;
            frequency_s2 <= '0;
        end else begin
            nearest_s2   <= nearest_s1;
            signal_ok_s2 <= signal_ok_s1;
            mode_sel_s2  <= mode_sel;
            cents_s2     <= cents_c;
            frequency_s2 <= frequency_c;
        end
    end

    // Cents BCD (7-bit magnitude → /10, %10) — small enough that
    // Quartus' constant-divisor folding handles it cheaply
    logic        cents_neg;
    logic [6:0]  cents_mag;
    logic [3:0]  cents_tens, cents_units;
    assign cents_neg   = cents_s2[9];
    assign cents_mag   = cents_neg ? 7'(-cents_s2) : 7'(cents_s2);
    assign cents_tens  = 4'((cents_mag / 7'd10) % 4'd10);
    assign cents_units = 4'(cents_mag % 7'd10);

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
                tuner_vals_n[5] = nearest_s2.letter;
                tuner_vals_n[4] = nearest_s2.is_sharp ? SEVSEG_SHARP_INDEX
                                                     : SEVSEG_BLANK_INDEX;
                tuner_vals_n[3] = nearest_s2.octave;
                tuner_vals_n[2] = cents_neg ? SEVSEG_LINE_INDEX
                                            : SEVSEG_BLANK_INDEX;
                tuner_vals_n[1] = {1'b0, cents_tens};
                tuner_vals_n[0] = {1'b0, cents_units};
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
