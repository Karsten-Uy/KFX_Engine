module tuner_ui (
    input  logic [11:0] best_lag,
    output logic [4:0] tuner_vals [5:0]
);
    import lab_pkg::*;

    // Intermediate math signals
    logic [15:0] frequency;
    logic [3:0]  ones, tens, hundreds, thousands;

    always_comb begin
        // 1. Calculate Frequency: f = 48000 / lag
        // Using a 16-bit approximation to avoid massive dividers
        if (best_lag > 0) 
            frequency = 16'd48000 / best_lag;
        else 
            frequency = 0;

        // 2. Binary to BCD (Digits extraction)
        thousands = (frequency / 1000) % 10;
        hundreds  = (frequency / 100) % 10;
        tens      = (frequency / 10) % 10;
        ones      = frequency % 10;

        // 3. Map to HEX Array
        // Default everything to blank
        for(int i=0; i<6; i++) tuner_vals[i] = SEVSEG_BLANK_INDEX;

        // Display "Fr" on HEX5 and HEX4 to indicate Frequency Mode
        tuner_vals[5] = 5'hF; // 'F'
        tuner_vals[4] = 5'd18; // 'r' (Assumes SEVSEG_X_INDEX or custom pattern in your pkg)

        // Display the digits on HEX3 down to HEX0
        tuner_vals[3] = {1'b0, thousands};
        tuner_vals[2] = {1'b0, hundreds};
        tuner_vals[1] = {1'b0, tens};
        tuner_vals[0] = {1'b0, ones};
        
        // Zero-blanking for thousands digit to keep it clean
        if (thousands == 0) tuner_vals[3] = SEVSEG_BLANK_INDEX;
    end
endmodule