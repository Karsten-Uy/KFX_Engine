/*
    Distortion with Amp Dynamics (Sag, Variable Bias, Tone, and DC Blocking)
    (Bit-width stable and phase-aligned)
*/

module fx_distortion #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                                clk,
    input  logic                                reset_n,
    input  logic signed [1:0][DATA_W-1:0]       audio_in,
    output logic signed [1:0][DATA_W-1:0]       audio_out,
    
    // Original Parameters
    input  logic [PARAM_W-1:0]                  fx_drive,
    input  logic [PARAM_W-1:0]                  fx_makeup_gain,
    input  logic [PARAM_W-1:0]                  fx_mix,
    
    // New Amp Parameters
    input  logic [PARAM_W-1:0]                  fx_bias, // 0 = symmetric, 255 = heavily asymmetric
    input  logic [PARAM_W-1:0]                  fx_sag,  // 0 = tight/solid-state, 255 = vintage tube sag
    input  logic [PARAM_W-1:0]                  fx_tone, // Cabinet low-pass cutoff
    
    input  logic                                sample_en
);

    import lab_pkg::*;

    // -----------------------------------------------------------------------
    // CONSTANTS
    // -----------------------------------------------------------------------
    localparam signed [15:0] ONE      =  16'sd32767;
    localparam signed [15:0] NEG_ONE  = -16'sd32767;
    localparam signed [15:0] TWO_THRD =  16'sd21845;

    // -----------------------------------------------------------------------
    // ENVELOPE FOLLOWER & POWER SUPPLY SAG
    // -----------------------------------------------------------------------
    logic signed [15:0] abs_in[1:0];
    logic signed [15:0] env_state[1:0]; 
    logic signed [15:0] env_next[1:0];
    
    (* multstyle = "logic" *) logic [15:0] sag_reduction[1:0]; 
    logic [15:0] drive_base;
    logic [15:0] drive_dynamic[1:0];

    assign drive_base = 16'h0100 + ({8'h00, fx_drive} << 5); 

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            // Guard against taking absolute value of -32768
            if (audio_in[i] == NEG_ONE) abs_in[i] = ONE;
            else                        abs_in[i] = (audio_in[i][15]) ? -$signed(audio_in[i]) : audio_in[i];
            
            env_next[i] = env_state[i] + (($signed(abs_in[i]) - $signed(env_state[i])) >>> 9);
            sag_reduction[i] = (env_state[i][15:8] * fx_sag) >> 2; 
            
            if (sag_reduction[i] > drive_base) drive_dynamic[i] = 16'h0010; 
            else                               drive_dynamic[i] = drive_base - sag_reduction[i];
        end
    end

    // -----------------------------------------------------------------------
    // PRE-EMPHASIS & DRY DELAY PIPELINE
    // -----------------------------------------------------------------------
    logic signed [15:0] audio_prev[1:0];
    logic signed [16:0] emph[1:0];
    logic signed [15:0] dry_dly[1:0][3:0]; // 4-stage delay to align dry with wet mix

    logic signed [15:0] dynamic_bias;
    assign dynamic_bias = {1'b0, fx_bias} << 4; 

    always_comb begin
        for (int i = 0; i < 2; i++)
            emph[i] = $signed(audio_in[i]) + 
                      ($signed($signed(audio_in[i]) - $signed(audio_prev[i])) >>> 2);
    end

    // -----------------------------------------------------------------------
    // STAGE 1 — DRIVE 
    // -----------------------------------------------------------------------
    logic signed [31:0] product[1:0];
    logic signed [31:0] product_reg[1:0];
    logic signed [31:0] x_raw[1:0];  
    logic signed [15:0] x[1:0];      

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            product[i] = $signed(sat16(emph[i])) * $signed({1'b0, drive_dynamic[i]});
            x_raw[i]   = product_reg[i] >>> 8;

            if      ($signed(x_raw[i]) + $signed(32'(dynamic_bias)) >  $signed(32'(ONE)))    x[i] =  ONE;
            else if ($signed(x_raw[i]) + $signed(32'(dynamic_bias)) < -$signed(32'(ONE)))    x[i] = NEG_ONE;
            else                                                                             x[i] = x_raw[i][15:0] + dynamic_bias;
        end
    end

    // -----------------------------------------------------------------------
    // STAGE 2 & 3 — POLYNOMIAL PIPELINE
    // -----------------------------------------------------------------------
    (* multstyle = "logic" *) logic signed [31:0] x_sq[1:0];
    (* multstyle = "logic" *) logic signed [47:0] x_cb[1:0];
    
    // Phase alignment registers for x
    logic signed [15:0] x_reg_1[1:0];
    logic signed [15:0] x_reg_2[1:0];
    logic signed [31:0] x_sq_reg[1:0];
    logic signed [47:0] x_cb_reg[1:0];

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            x_sq[i] = $signed(x[i])        * $signed(x[i]);
            // Multiply x^2[n] by x[n] to get true x^3
            x_cb[i] = $signed(x_sq_reg[i]) * $signed(x_reg_1[i]);
        end
    end

    logic signed [15:0] cubic_term[1:0];
    logic signed [17:0] cubic_sum[1:0];
    logic signed [15:0] cubic_div3[1:0];
    logic signed [15:0] distorted_raw[1:0];
    
    // DC Blocking state
    logic signed [15:0] dc_state[1:0];
    logic signed [15:0] dc_next[1:0];
    logic signed [16:0] dc_diff[1:0];     // Explicit 17-bit for subtraction
    logic signed [15:0] distorted_clean[1:0];
    logic signed [15:0] distorted_reg[1:0];

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            cubic_term[i] = $signed(x_cb_reg[i]) >>> 30;
            cubic_sum[i]  = $signed(cubic_term[i])        + 
                            ($signed(cubic_term[i]) >>> 2) + 
                            ($signed(cubic_term[i]) >>> 4) + 
                            ($signed(cubic_term[i]) >>> 6);
            cubic_div3[i] = $signed(cubic_sum[i]) >>> 2;

            // Subtract cubic from the properly delayed x
            if      (x_reg_2[i] >=  ONE)   distorted_raw[i] =  TWO_THRD;
            else if (x_reg_2[i] <= NEG_ONE) distorted_raw[i] = -TWO_THRD;
            else                           distorted_raw[i] = $signed(x_reg_2[i]) - cubic_div3[i];
            
            // 17-bit explicit DC tracking subtraction
            dc_diff[i] = $signed(17'(distorted_raw[i])) - $signed(17'(dc_state[i]));
            dc_next[i] = $signed(dc_state[i]) + 16'(dc_diff[i] >>> 12);
            distorted_clean[i] = sat16(dc_diff[i]);
        end
    end

    // -----------------------------------------------------------------------
    // MIX + MAKEUP GAIN 
    // -----------------------------------------------------------------------
    (* multstyle = "logic" *) logic signed [24:0] mix_product[1:0];
    (* multstyle = "logic" *) logic signed [23:0] makeup_product[1:0];
    logic signed [15:0] mix_res[1:0];
    logic signed [15:0] mix_reg[1:0];
    logic signed [15:0] makeup[1:0];

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            // Mix against the properly delayed dry signal
            mix_product[i] = ($signed(distorted_reg[i]) - $signed(dry_dly[i][3])) * $signed({1'b0, fx_mix});
            mix_res[i]     = sat16($signed(dry_dly[i][3]) + ($signed(mix_product[i]) >>> 8));
            
            makeup_product[i] = $signed(mix_reg[i]) * $signed({1'b0, fx_makeup_gain});
            makeup[i]         = sat16($signed(makeup_product[i]) >>> 7);
        end
    end

    // -----------------------------------------------------------------------
    // SPEAKER CABINET (Fixed 27-bit Multiplications)
    // -----------------------------------------------------------------------
    logic signed [15:0] cab1[1:0], cab2[1:0];
    logic signed [16:0] d1[1:0],   d2[1:0];
    logic signed [26:0] cab1_mult[1:0], cab2_mult[1:0]; // Explict width to prevent overflow
    logic signed [15:0] cab1_n[1:0], cab2_n[1:0];
    
    logic [8:0] safe_tone;
    assign safe_tone = {1'b0, fx_tone} + 9'd10; 

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            d1[i] = $signed(makeup[i])  - $signed(cab1[i]);
            cab1_mult[i] = $signed(d1[i]) * $signed({1'b0, safe_tone});
            cab1_n[i] = $signed(cab1[i]) + 16'(cab1_mult[i] >>> 8);

            d2[i] = $signed(cab1_n[i]) - $signed(cab2[i]);
            cab2_mult[i] = $signed(d2[i]) * $signed({1'b0, safe_tone});
            cab2_n[i] = $signed(cab2[i]) + 16'(cab2_mult[i] >>> 8);
        end
    end

    // -----------------------------------------------------------------------
    // PIPELINE REGISTERS
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            for (int i = 0; i < 2; i++) begin
                audio_prev[i]    <= '0;
                env_state[i]     <= '0;
                product_reg[i]   <= '0;
                x_reg_1[i]       <= '0;
                x_reg_2[i]       <= '0;
                x_sq_reg[i]      <= '0;
                x_cb_reg[i]      <= '0;
                dc_state[i]      <= '0;
                distorted_reg[i] <= '0;
                mix_reg[i]       <= '0;
                cab1[i]          <= '0;
                cab2[i]          <= '0;
                for (int j = 0; j < 4; j++) dry_dly[i][j] <= '0;
            end
        end else if (sample_en) begin
            for (int i = 0; i < 2; i++) begin
                audio_prev[i]    <= audio_in[i];
                env_state[i]     <= env_next[i];
                
                // Shift dry signal to match processing latency
                dry_dly[i][0] <= audio_in[i];
                dry_dly[i][1] <= dry_dly[i][0];
                dry_dly[i][2] <= dry_dly[i][1];
                dry_dly[i][3] <= dry_dly[i][2];
                
                product_reg[i]   <= product[i];
                
                // Keep the polynomials phase-aligned
                x_sq_reg[i]      <= x_sq[i];
                x_reg_1[i]       <= x[i];
                x_cb_reg[i]      <= x_cb[i];
                x_reg_2[i]       <= x_reg_1[i];
                
                dc_state[i]      <= dc_next[i];
                distorted_reg[i] <= distorted_clean[i];
                mix_reg[i]       <= mix_res[i];
                cab1[i]          <= cab1_n[i];
                cab2[i]          <= cab2_n[i];
            end
        end
    end

    // -----------------------------------------------------------------------
    // OUTPUT
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            for (int i = 0; i < 2; i++)
                audio_out[i] <= cab2_n[i];
        end
    end

endmodule