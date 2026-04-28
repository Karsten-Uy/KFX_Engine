/*
    Distortion with Amp Dynamics (Sag, Variable Bias, Tone, and DC Blocking)
    (Bit-width stable and phase-aligned)
    NEW: Anti-aliasing Amp Sandwich with safe transient handling.
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
    
    // Amp Parameters
    input  logic [PARAM_W-1:0]                  fx_bias, 
    input  logic [PARAM_W-1:0]                  fx_sag,  
    input  logic [PARAM_W-1:0]                  fx_tone, 
    
    // Amp Realism Parameters
    input  logic [PARAM_W-1:0]                  fx_tightness, 
    input  logic [PARAM_W-1:0]                  fx_smooth,    
    
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
            if (audio_in[i] == NEG_ONE) abs_in[i] = ONE;
            else                        abs_in[i] = (audio_in[i][15]) ? -$signed(audio_in[i]) : audio_in[i];
            
            env_next[i] = env_state[i] + (($signed(abs_in[i]) - $signed(env_state[i])) >>> 9);
            sag_reduction[i] = (env_state[i][15:8] * fx_sag) >> 2; 
            
            if (sag_reduction[i] > drive_base) drive_dynamic[i] = 16'h0010; 
            else                               drive_dynamic[i] = drive_base - sag_reduction[i];
        end
    end

    // -----------------------------------------------------------------------
    // PRE-EMPHASIS & PRE-CLIP TIGHTNESS (High-Pass)
    // -----------------------------------------------------------------------
    logic signed [15:0] audio_prev[1:0];
    logic signed [16:0] emph[1:0];
    logic signed [15:0] dry_dly[1:0][3:0]; 
    logic signed [15:0] dynamic_bias;
    
    // Tightness (HPF) State - WIDENED TO PREVENT TRANSIENT WRAP
    logic signed [16:0] pre_lp_state[1:0];
    logic signed [17:0] pre_lp_diff[1:0];
    logic signed [27:0] pre_lp_mult[1:0];
    logic signed [31:0] pre_lp_next_full[1:0];
    logic signed [16:0] pre_lp_next_safe[1:0];
    
    logic signed [17:0] pre_hp_out_full[1:0];
    logic signed [15:0] pre_hp_out_safe[1:0];

    assign dynamic_bias = {1'b0, fx_bias} << 4; 

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            emph[i] = $signed(audio_in[i]) + 
                      ($signed($signed(audio_in[i]) - $signed(audio_prev[i])) >>> 2);
                      
            // Expanded width math to catch explosive transients
            pre_lp_diff[i]      = $signed(emph[i]) - $signed(pre_lp_state[i]);
            pre_lp_mult[i]      = $signed(pre_lp_diff[i]) * $signed({1'b0, fx_tightness});
            pre_lp_next_full[i] = $signed(pre_lp_state[i]) + ($signed(pre_lp_mult[i]) >>> 10);
            
            // Safe clamp before truncating to register width
            pre_lp_next_safe[i] = 17'(sat16(pre_lp_next_full[i])); 
            
            pre_hp_out_full[i]  = $signed(emph[i]) - $signed(pre_lp_state[i]);
            pre_hp_out_safe[i]  = sat16(32'(pre_hp_out_full[i])); // Feed this to the drive
        end
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
            product[i] = $signed(pre_hp_out_safe[i]) * $signed({1'b0, drive_dynamic[i]});
            x_raw[i]   = product_reg[i] >>> 8;

            if      ($signed(x_raw[i]) + $signed(32'(dynamic_bias)) >  $signed(32'(ONE)))    x[i] =  ONE;
            else if ($signed(x_raw[i]) + $signed(32'(dynamic_bias)) < -$signed(32'(ONE)))    x[i] = NEG_ONE;
            else                                                                             x[i] = x_raw[i][15:0] + dynamic_bias;
        end
    end

    // -----------------------------------------------------------------------
    // STAGE 2 & 3 — POLYNOMIAL PIPELINE & POST-CLIP SMOOTHING
    // -----------------------------------------------------------------------
    (* multstyle = "logic" *) logic signed [31:0] x_sq[1:0];
    (* multstyle = "logic" *) logic signed [47:0] x_cb[1:0];
    
    logic signed [15:0] x_reg_1[1:0], x_reg_2[1:0];
    logic signed [31:0] x_sq_reg[1:0];
    logic signed [47:0] x_cb_reg[1:0];

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            x_sq[i] = $signed(x[i])        * $signed(x[i]);
            x_cb[i] = $signed(x_sq_reg[i]) * $signed(x_reg_1[i]);
        end
    end

    logic signed [15:0] cubic_term[1:0], cubic_div3[1:0], distorted_raw[1:0];
    logic signed [17:0] cubic_sum[1:0];
    logic signed [15:0] dc_state[1:0], dc_next[1:0], distorted_clean[1:0];
    logic signed [16:0] dc_diff[1:0]; 
    logic signed [15:0] distorted_reg[1:0];
    
    // Smooth (LPF) State - WIDENED TO PREVENT TRANSIENT WRAP
    logic signed [15:0] post_lp_state[1:0];
    logic signed [16:0] post_lp_diff[1:0];
    logic signed [26:0] post_lp_mult[1:0];
    logic signed [31:0] fizz_tamed_full[1:0];
    logic signed [15:0] fizz_tamed_safe[1:0];
    
    logic [8:0] coeff_smooth;
    assign coeff_smooth = 9'd256 - {1'b0, fx_smooth}; 

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            cubic_term[i] = $signed(x_cb_reg[i]) >>> 30;
            cubic_sum[i]  = $signed(cubic_term[i])        + 
                            ($signed(cubic_term[i]) >>> 2) + 
                            ($signed(cubic_term[i]) >>> 4) + 
                            ($signed(cubic_term[i]) >>> 6);
            cubic_div3[i] = $signed(cubic_sum[i]) >>> 2;

            if      (x_reg_2[i] >=  ONE)  distorted_raw[i] =  TWO_THRD;
            else if (x_reg_2[i] <= NEG_ONE) distorted_raw[i] = -TWO_THRD;
            else                           distorted_raw[i] = $signed(x_reg_2[i]) - cubic_div3[i];
            
            dc_diff[i] = $signed(17'(distorted_raw[i])) - $signed(17'(dc_state[i]));
            dc_next[i] = $signed(dc_state[i]) + 16'(dc_diff[i] >>> 12);
            distorted_clean[i] = sat16(dc_diff[i]);
            
            // Expanded width math to catch explosive transients
            post_lp_diff[i]    = $signed(distorted_clean[i]) - $signed(post_lp_state[i]);
            post_lp_mult[i]    = $signed(post_lp_diff[i]) * $signed({1'b0, coeff_smooth});
            fizz_tamed_full[i] = $signed(post_lp_state[i]) + ($signed(post_lp_mult[i]) >>> 8);
            
            // Safe clamp before truncating
            fizz_tamed_safe[i] = sat16(fizz_tamed_full[i]);
        end
    end

    // -----------------------------------------------------------------------
    // MIX + MAKEUP GAIN 
    // -----------------------------------------------------------------------
    (* multstyle = "logic" *) logic signed [24:0] mix_product[1:0];
    (* multstyle = "logic" *) logic signed [23:0] makeup_product[1:0];
    logic signed [15:0] mix_res[1:0], mix_reg[1:0], makeup[1:0];

    always_comb begin
        for (int i = 0; i < 2; i++) begin
            mix_product[i] = ($signed(distorted_reg[i]) - $signed(dry_dly[i][3])) * $signed({1'b0, fx_mix});
            mix_res[i]     = sat16($signed(dry_dly[i][3]) + ($signed(mix_product[i]) >>> 8));
            
            makeup_product[i] = $signed(mix_reg[i]) * $signed({1'b0, fx_makeup_gain});
            makeup[i]         = sat16($signed(makeup_product[i]) >>> 7);
        end
    end

    // -----------------------------------------------------------------------
    // SPEAKER CABINET 
    // -----------------------------------------------------------------------
    logic signed [15:0] cab1[1:0], cab2[1:0], cab1_n[1:0], cab2_n[1:0];
    logic signed [16:0] d1[1:0],   d2[1:0];
    logic signed [26:0] cab1_mult[1:0], cab2_mult[1:0]; 
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
                pre_lp_state[i]  <= '0;
                product_reg[i]   <= '0;
                x_reg_1[i]       <= '0;
                x_reg_2[i]       <= '0;
                x_sq_reg[i]      <= '0;
                x_cb_reg[i]      <= '0;
                dc_state[i]      <= '0;
                post_lp_state[i] <= '0;
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
                
                pre_lp_state[i]  <= pre_lp_next_safe[i];
                
                dry_dly[i][0] <= audio_in[i];
                dry_dly[i][1] <= dry_dly[i][0];
                dry_dly[i][2] <= dry_dly[i][1];
                dry_dly[i][3] <= dry_dly[i][2];
                
                product_reg[i]   <= product[i];
                x_sq_reg[i]      <= x_sq[i];
                x_reg_1[i]       <= x[i];
                x_cb_reg[i]      <= x_cb[i];
                x_reg_2[i]       <= x_reg_1[i];
                
                dc_state[i]      <= dc_next[i];
                
                post_lp_state[i] <= fizz_tamed_safe[i];
                distorted_reg[i] <= fizz_tamed_safe[i];
                
                mix_reg[i]       <= mix_res[i];
                cab1[i]          <= cab1_n[i];
                cab2[i]          <= cab2_n[i];
            end
        end
    end

    // -----------------------------------------------------------------------
    // OUTPUT
    //
    // True bypass when fx_mix == 0.  Without this the cabinet IIR (cab1/cab2)
    // runs continuously and accumulates per-pole truncation noise even on
    // banks that don't use distortion — and at high fx_tone the cabinet
    // coefficient (safe_tone/256) exceeds 1.0 and amplifies upstream noise.
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            for (int i = 0; i < 2; i++)
                audio_out[i] <= (fx_mix == '0) ? audio_in[i] : cab2_n[i];
        end
    end

endmodule