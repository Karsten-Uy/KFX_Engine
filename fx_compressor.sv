// ============================================================
//  fx_compressor.sv  (rev 7 — Full Feature: Anti-Buzz + Gains)
// ============================================================

module fx_compressor #(
    parameter DATA_W            = 16,
    parameter PARAM_W           = 8,
    parameter LOOKAHEAD_SAMPLES = 8 
)(
    input  logic                          clk,
    input  logic                          reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,
    output logic signed [1:0][DATA_W-1:0] audio_out,
    // Compressor Core Params
    input  logic [PARAM_W-1:0]            fx_threshold,
    input  logic [PARAM_W-1:0]            fx_ratio,
    input  logic [PARAM_W-1:0]            fx_attack,
    input  logic [PARAM_W-1:0]            fx_release,
    // Gain Params (Linear 0..255, where 64 = 1.0x Unity)
    input  logic [PARAM_W-1:0]            fx_input_gain,
    input  logic [PARAM_W-1:0]            fx_makeup_gain,
    input  logic                          sample_en
);

    // --- Local constants ---
    localparam GAIN_W  = DATA_W;          // Q15 gain word
    localparam PROD_W  = DATA_W + GAIN_W; // 32-bit internal products
    localparam logic [GAIN_W-1:0] GAIN_UNITY = 16'h7FFF; 

    // --- 1. Input Gain Stage ---
    // Multiplies signal before Sidechain and Delay line.
    logic signed [1:0][DATA_W-1:0] audio_pre;

    always_ff @(posedge clk or negedge reset_n) begin : input_gain_ff
        if (!reset_n) audio_pre <= '0;
        else if (sample_en) begin
            automatic logic signed [DATA_W+PARAM_W:0] pre_l, pre_r;
            pre_l = $signed(audio_in[0]) * $signed({1'b0, fx_input_gain});
            pre_r = $signed(audio_in[1]) * $signed({1'b0, fx_input_gain});
            
            // Normalize (64=Unity) and Saturate to prevent wrap-around clipping
            audio_pre[0] <= (pre_l >>> 6 > 32767)  ? 16'h7FFF : (pre_l >>> 6 < -32768) ? 16'h8000 : pre_l[15+6:6];
            audio_pre[1] <= (pre_r >>> 6 > 32767)  ? 16'h7FFF : (pre_r >>> 6 < -32768) ? 16'h8000 : pre_r[15+6:6];
        end
    end

    // --- 2. Sidechain: Absolute Value + Stereo Peak ---
    logic [DATA_W-1:0] abs_l, abs_r, peak;
    always_comb begin
        abs_l = (audio_pre[0][DATA_W-1]) ? (audio_pre[0] == 16'h8000 ? 16'h7FFF : DATA_W'(-audio_pre[0])) : DATA_W'(audio_pre[0]);
        abs_r = (audio_pre[1][DATA_W-1]) ? (audio_pre[1] == 16'h8000 ? 16'h7FFF : DATA_W'(-audio_pre[1])) : DATA_W'(audio_pre[1]);
        peak  = (abs_l > abs_r) ? abs_l : abs_r;
    end

    // --- 3. Envelope Follower ---
    logic [DATA_W-1:0] env;
    logic [3:0] atk_s, rel_s;
    assign atk_s = fx_attack[PARAM_W-1 -: 4] | 4'd1;
    assign rel_s = fx_release[PARAM_W-1 -: 4] | 4'd1;

    always_ff @(posedge clk or negedge reset_n) begin : env_ff
        if (!reset_n) env <= '0;
        else if (sample_en) begin
            if (peak > env) env <= env + ((peak - env) >> atk_s);
            else            env <= env - ((env - peak) >> rel_s);
        end
    end

    // --- 4. Gain Target Calculation ---
    logic [DATA_W-1:0] threshold_lin;
    logic [DATA_W-1:0] comp_level;
    logic              below_threshold;

    assign threshold_lin = {fx_threshold, 8'h00};
    
    always_comb begin
        below_threshold = (env <= threshold_lin) || (env == 0);
        if (below_threshold) comp_level = '0;
        else                 comp_level = threshold_lin + ((env - threshold_lin) >> fx_ratio[7:5]);
    end

    // --- 5. High-Precision Sequential Divider ---
    // Computes: gain_target = (comp_level << 15) / env
    logic [DATA_W-1:0] dv_comp, dv_env;
    logic              dv_bypass;
    logic [DATA_W:0]   dv_rem; 
    logic [GAIN_W-1:0] dv_quot;
    logic [4:0]        dv_cnt;
    logic              dv_done;

    logic [DATA_W:0] trial;

    always_ff @(posedge clk or negedge reset_n) begin : divider_ff
        if (!reset_n) begin
            {dv_comp, dv_env, dv_cnt, dv_done} <= '0;
            dv_bypass <= 1'b1;
        end else begin
            dv_done <= 1'b0;
            if (sample_en) begin
                dv_comp   <= comp_level;
                dv_env    <= env;
                dv_bypass <= below_threshold;
                dv_rem    <= {1'b0, comp_level}; 
                dv_quot   <= '0;
                dv_cnt    <= 5'd16;
            end else if (dv_cnt != 0) begin
                // Trial subtraction for Q15 result
                trial = {dv_rem[DATA_W-1:0], 1'b0};
                if (trial >= {1'b0, dv_env}) begin
                    dv_rem <= trial - {1'b0, dv_env};
                    dv_quot[dv_cnt-1] <= 1'b1;
                end else begin
                    dv_rem <= trial;
                    dv_quot[dv_cnt-1] <= 1'b0;
                end
                dv_cnt <= dv_cnt - 1;
                if (dv_cnt == 5'd1) dv_done <= 1'b1;
            end
        end
    end

    logic [GAIN_W-1:0] gain_target_r;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) gain_target_r <= GAIN_UNITY;
        else if (dv_done) gain_target_r <= dv_bypass ? GAIN_UNITY : dv_quot;
    end

    // --- 6. High-Speed Smoother (The "Anti-Buzz" Engine) ---
    logic [GAIN_W-1:0] gain_smooth;
    always_ff @(posedge clk or negedge reset_n) begin : gain_smooth_ff
        if (!reset_n) gain_smooth <= GAIN_UNITY;
        else begin 
            // Updating at 50MHz instead of 48kHz removes audible stepping.
            if (gain_target_r < gain_smooth)
                gain_smooth <= gain_smooth - ((gain_smooth - gain_target_r) >> (atk_s + 10));
            else
                gain_smooth <= gain_smooth + ((gain_target_r - gain_smooth) >> (rel_s + 10));
        end
    end

    // --- 7. Lookahead Delay ---
    logic signed [1:0][DATA_W-1:0] audio_lookahead [0:LOOKAHEAD_SAMPLES-1];
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) for (int i=0; i<LOOKAHEAD_SAMPLES; i++) audio_lookahead[i] <= '0;
        else if (sample_en) begin
            audio_lookahead[0] <= audio_pre;
            for (int i=1; i<LOOKAHEAD_SAMPLES; i++) audio_lookahead[i] <= audio_lookahead[i-1];
        end
    end

    // --- 8. Output Stage: Compression + Makeup Gain + Rounding ---

    logic signed [PROD_W-1:0] p_l, p_r;
    logic signed [PROD_W+PARAM_W:0] m_l, m_r;
    
    always_ff @(posedge clk or negedge reset_n) begin : apply_gain_ff
        if (!reset_n) audio_out <= '0;
        else if (sample_en) begin
            
            // Apply Compression
            p_l = $signed(audio_lookahead[LOOKAHEAD_SAMPLES-1][0]) * $signed({1'b0, gain_smooth});
            p_r = $signed(audio_lookahead[LOOKAHEAD_SAMPLES-1][1]) * $signed({1'b0, gain_smooth});
            
            // Apply Makeup Gain
            m_l = (p_l >>> 15) * $signed({1'b0, fx_makeup_gain});
            m_r = (p_r >>> 15) * $signed({1'b0, fx_makeup_gain});

            // Normalize (64=Unity), Saturate, and Round
            audio_out[0] <= (m_l >>> 6 > 32767)  ? 16'h7FFF : (m_l >>> 6 < -32768) ? 16'h8000 : m_l[15+6:6];
            audio_out[1] <= (m_r >>> 6 > 32767)  ? 16'h7FFF : (m_r >>> 6 < -32768) ? 16'h8000 : m_r[15+6:6];
        end
    end

endmodule