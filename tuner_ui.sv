module tuner_ui (
    input  logic [11:0] best_lag,
    output logic [4:0] tuner_vals [5:0]
);
    import lab_pkg::*;

    // Need 17 bits: 96000 = 0x17700, doesn't fit in 16 bits!
    logic [20:0] frequency;
    logic [3:0]  ones, tens, hundreds, thousands;

    always_comb begin
        if (best_lag > 0) 
            frequency = (17'd48000 / {5'b0, best_lag}) * 2;
        else 
            frequency = 0;        

        thousands = (frequency / 1000) % 10;
        hundreds  = (frequency / 100)  % 10;
        tens      = (frequency / 10)   % 10;
        ones      =  frequency         % 10;

        for (int i = 0; i < 6; i++) tuner_vals[i] = SEVSEG_BLANK_INDEX;

        tuner_vals[5] = 5'hF;   // 'F'
        tuner_vals[4] = 5'd18;  // 'r'

        tuner_vals[3] = {1'b0, thousands};
        tuner_vals[2] = {1'b0, hundreds};
        tuner_vals[1] = {1'b0, tens};
        tuner_vals[0] = {1'b0, ones};

        if (thousands == 0) tuner_vals[3] = SEVSEG_BLANK_INDEX;
    end
endmodule