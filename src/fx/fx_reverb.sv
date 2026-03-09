module fx_reverb #(
    parameter DATA_W    = 16,
    parameter PARAM_W   = 8,
    parameter MAX_DELAY = 2048
)(
    input  wire                          clk,
    input  wire                          reset_n,
    input  wire signed [1:0][DATA_W-1:0] audio_in,
    output reg  signed [1:0][DATA_W-1:0] audio_out,
    input  wire [PARAM_W-1:0]            fx_size,
    input  wire [PARAM_W-1:0]            fx_damping,
    input  wire [PARAM_W-1:0]            fx_decay,
    input  wire [PARAM_W-1:0]            fx_mix,
    input  wire [PARAM_W-1:0]            fx_width,
    input  wire                          sample_en
);

    // ----------------------------------------------------------------
    // Constants
    // ----------------------------------------------------------------
    localparam ADDR_W  = $clog2(MAX_DELAY);   // 11
    localparam WIDE_W  = 20;                   // internal state precision
    localparam HAD_W   = WIDE_W + 2;           // Hadamard sum of 4 = +2 bits
    localparam MPROD_W = HAD_W + PARAM_W + 1;  // 31 — safe multiply width
    localparam MIN_DLY = 128;

    // ----------------------------------------------------------------
    // Saturation helpers
    // ----------------------------------------------------------------
    function automatic signed [WIDE_W-1:0] sat_w;
        input signed [MPROD_W-1:0] x;
        sat_w = (x >  ((1 << (WIDE_W-1)) - 1)) ?  ((1 << (WIDE_W-1)) - 1) :
                (x < -(1 << (WIDE_W-1)))         ? -(1 << (WIDE_W-1))      :
                                                    x[WIDE_W-1:0];
    endfunction

    function automatic signed [DATA_W-1:0] sat16;
        input signed [MPROD_W-1:0] x;
        sat16 = (x >  32767) ? 16'sh7FFF :
                (x < -32768) ? 16'sh8000 : x[DATA_W-1:0];
    endfunction

    // ----------------------------------------------------------------
    // 4 delay memories — one per FDN tap
    // Lengths use ratios 7:6:5:4 (mutually coprime-ish for good diffusion)
    // max length = 128 + 255*7 = 1913 < 2048 ✓
    // ----------------------------------------------------------------
    (* ramstyle = "M10K" *) reg signed [DATA_W-1:0] mem0 [0:MAX_DELAY-1];
    (* ramstyle = "M10K" *) reg signed [DATA_W-1:0] mem1 [0:MAX_DELAY-1];
    (* ramstyle = "M10K" *) reg signed [DATA_W-1:0] mem2 [0:MAX_DELAY-1];
    (* ramstyle = "M10K" *) reg signed [DATA_W-1:0] mem3 [0:MAX_DELAY-1];

    // wr_ptr driven ONLY from the stage 5 always block (single driver)
    reg [ADDR_W-1:0]        wr_ptr [3:0];
    reg [ADDR_W-1:0]        rd_ptr [3:0];
    reg signed [DATA_W-1:0] rd_q   [3:0];   // registered mem output

    wire [ADDR_W+3:0] dlen_raw [3:0];
    wire [ADDR_W-1:0] dlen     [3:0];
    assign dlen_raw[0] = MIN_DLY + fx_size * 7;
    assign dlen_raw[1] = MIN_DLY + fx_size * 6;
    assign dlen_raw[2] = MIN_DLY + fx_size * 5;
    assign dlen_raw[3] = MIN_DLY + fx_size * 4;
    // max dlen_raw = 1913 < 2048 so upper bits are always 0 — safe truncation
    assign dlen[0] = dlen_raw[0][ADDR_W-1:0];
    assign dlen[1] = dlen_raw[1][ADDR_W-1:0];
    assign dlen[2] = dlen_raw[2][ADDR_W-1:0];
    assign dlen[3] = dlen_raw[3][ADDR_W-1:0];

    // Synchronous read — 1-cycle latency from rd_ptr
    always @(posedge clk) begin
        rd_q[0] <= mem0[rd_ptr[0]];
        rd_q[1] <= mem1[rd_ptr[1]];
        rd_q[2] <= mem2[rd_ptr[2]];
        rd_q[3] <= mem3[rd_ptr[3]];
    end

    // ----------------------------------------------------------------
    // LP filter states  (persistent, written only in stage 3 block)
    // DC-blocker state  (written only in stage 7 block)
    // ----------------------------------------------------------------
    reg signed [WIDE_W-1:0] lp [3:0];
    reg signed [DATA_W-1:0] xp_l, xp_r, yp_l, yp_r;

    // ================================================================
    // STAGE 0 — latch inputs, set read pointers
    // NOTE: wr_ptr is NOT touched here — it lives solely in stage 5
    // ================================================================
    reg                      p0_v;
    reg signed [DATA_W-1:0] p0_in_l, p0_in_r;
    reg signed [WIDE_W-1:0] p0_mono;
    reg [PARAM_W-1:0]        p0_damp, p0_decay, p0_mix, p0_width;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            p0_v      <= 1'b0;
            rd_ptr[0] <= '0; rd_ptr[1] <= '0;
            rd_ptr[2] <= '0; rd_ptr[3] <= '0;
        end else begin
            p0_v <= sample_en;
            if (sample_en) begin
                p0_in_l  <= audio_in[0];
                p0_in_r  <= audio_in[1];
                // Zero-extend before add to prevent signed overflow
                p0_mono  <= WIDE_W'($signed({1'b0, audio_in[0]})
                                  + $signed({1'b0, audio_in[1]})) >>> 1;
                p0_damp  <= fx_damping;
                p0_decay <= fx_decay;
                p0_mix   <= fx_mix;
                p0_width <= fx_width;
                // Circular read pointer: wr - delay (mod MAX_DELAY)
                rd_ptr[0] <= (wr_ptr[0] >= dlen[0]) ? wr_ptr[0] - dlen[0]
                                                     : wr_ptr[0] - dlen[0] + ADDR_W'(MAX_DELAY);
                rd_ptr[1] <= (wr_ptr[1] >= dlen[1]) ? wr_ptr[1] - dlen[1]
                                                     : wr_ptr[1] - dlen[1] + ADDR_W'(MAX_DELAY);
                rd_ptr[2] <= (wr_ptr[2] >= dlen[2]) ? wr_ptr[2] - dlen[2]
                                                     : wr_ptr[2] - dlen[2] + ADDR_W'(MAX_DELAY);
                rd_ptr[3] <= (wr_ptr[3] >= dlen[3]) ? wr_ptr[3] - dlen[3]
                                                     : wr_ptr[3] - dlen[3] + ADDR_W'(MAX_DELAY);
            end
        end
    end

    // ================================================================
    // STAGE 1 — propagate; synchronous memory read completes
    // ================================================================
    reg                      p1_v;
    reg signed [DATA_W-1:0] p1_in_l, p1_in_r;
    reg signed [WIDE_W-1:0] p1_mono;
    reg [PARAM_W-1:0]        p1_damp, p1_decay, p1_mix, p1_width;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) p1_v <= 1'b0;
        else begin
            p1_v    <= p0_v;
            p1_in_l <= p0_in_l; p1_in_r <= p0_in_r;
            p1_mono <= p0_mono;
            p1_damp <= p0_damp; p1_decay <= p0_decay;
            p1_mix  <= p0_mix;  p1_width <= p0_width;
        end
    end

    // ================================================================
    // STAGE 2 — damping multiply (rd_q now valid)
    //   dp[i] = (sign_ext(rd_q[i]) - lp[i]) x damp
    //   4 parallel DSP multipliers inferred here
    // ================================================================
    wire signed [WIDE_W-1:0] dly_sx [3:0];
    assign dly_sx[0] = {{(WIDE_W-DATA_W){rd_q[0][DATA_W-1]}}, rd_q[0]};
    assign dly_sx[1] = {{(WIDE_W-DATA_W){rd_q[1][DATA_W-1]}}, rd_q[1]};
    assign dly_sx[2] = {{(WIDE_W-DATA_W){rd_q[2][DATA_W-1]}}, rd_q[2]};
    assign dly_sx[3] = {{(WIDE_W-DATA_W){rd_q[3][DATA_W-1]}}, rd_q[3]};

    reg                          p2_v;
    reg signed [DATA_W-1:0]     p2_in_l, p2_in_r;
    reg signed [WIDE_W-1:0]     p2_mono;
    reg [PARAM_W-1:0]            p2_decay, p2_mix, p2_width;
    // Product width: WIDE_W (signed) x (PARAM_W+1) (sign-extended unsigned)
    reg signed [WIDE_W+PARAM_W:0] p2_dp [3:0];

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            p2_v     <= 1'b0;
            p2_dp[0] <= '0; p2_dp[1] <= '0;
            p2_dp[2] <= '0; p2_dp[3] <= '0;
        end else begin
            p2_v     <= p1_v;
            p2_in_l  <= p1_in_l; p2_in_r <= p1_in_r;
            p2_mono  <= p1_mono;
            p2_decay <= p1_decay; p2_mix <= p1_mix; p2_width <= p1_width;
            // {1'b0, damp} sign-extends the unsigned param to signed
            p2_dp[0] <= (dly_sx[0] - lp[0]) * $signed({1'b0, p1_damp});
            p2_dp[1] <= (dly_sx[1] - lp[1]) * $signed({1'b0, p1_damp});
            p2_dp[2] <= (dly_sx[2] - lp[2]) * $signed({1'b0, p1_damp});
            p2_dp[3] <= (dly_sx[3] - lp[3]) * $signed({1'b0, p1_damp});
        end
    end

    // ================================================================
    // STAGE 3 — update LP states, apply Hadamard mixing matrix
    //
    //   lp_new[i] = lp[i] + dp[i] >> 8        (IIR lowpass update)
    //
    //   Unnormalized H4 matrix (all adds/subtracts — zero multipliers):
    //     had[0] = lp[0] + lp[1] + lp[2] + lp[3]
    //     had[1] = lp[0] - lp[1] + lp[2] - lp[3]
    //     had[2] = lp[0] + lp[1] - lp[2] - lp[3]
    //     had[3] = lp[0] - lp[1] - lp[2] + lp[3]
    //
    //   Spectral norm of H4 = 2, so feedback gain = 2 * decay/512 = decay/256.
    //   At max decay (255): gain ~0.996 — very long tail without instability.
    // ================================================================

    // Combinational LP update used both to write lp[] and feed Hadamard
    // dp bits [WIDE_W+PARAM_W-1 : PARAM_W] = arithmetic >>8, WIDE_W bits wide
    wire signed [WIDE_W-1:0] lp_new [3:0];
    assign lp_new[0] = lp[0] + $signed(p2_dp[0][WIDE_W+PARAM_W-1:PARAM_W]);
    assign lp_new[1] = lp[1] + $signed(p2_dp[1][WIDE_W+PARAM_W-1:PARAM_W]);
    assign lp_new[2] = lp[2] + $signed(p2_dp[2][WIDE_W+PARAM_W-1:PARAM_W]);
    assign lp_new[3] = lp[3] + $signed(p2_dp[3][WIDE_W+PARAM_W-1:PARAM_W]);

    reg                      p3_v;
    reg signed [DATA_W-1:0] p3_in_l, p3_in_r;
    reg signed [WIDE_W-1:0] p3_mono;
    reg [PARAM_W-1:0]        p3_decay, p3_mix, p3_width;
    reg signed [HAD_W-1:0]  p3_had [3:0];   // +2 bits for sum of 4
    reg signed [WIDE_W-1:0] p3_lp  [3:0];   // snapshot for stereo extraction

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            p3_v  <= 1'b0;
            lp[0] <= '0; lp[1] <= '0; lp[2] <= '0; lp[3] <= '0;
        end else begin
            p3_v    <= p2_v;
            p3_in_l <= p2_in_l; p3_in_r <= p2_in_r;
            p3_mono <= p2_mono;
            p3_decay <= p2_decay; p3_mix <= p2_mix; p3_width <= p2_width;
            if (p2_v) begin
                // Persist LP states for next sample
                lp[0] <= lp_new[0]; lp[1] <= lp_new[1];
                lp[2] <= lp_new[2]; lp[3] <= lp_new[3];
                // Snapshot for stereo output extraction (stages 5+)
                p3_lp[0] <= lp_new[0]; p3_lp[1] <= lp_new[1];
                p3_lp[2] <= lp_new[2]; p3_lp[3] <= lp_new[3];
                // H4 mixing (normalisation compensated by >>9 in stage 5)
                p3_had[0] <= HAD_W'($signed(lp_new[0])) + HAD_W'($signed(lp_new[1]))
                           + HAD_W'($signed(lp_new[2])) + HAD_W'($signed(lp_new[3]));
                p3_had[1] <= HAD_W'($signed(lp_new[0])) - HAD_W'($signed(lp_new[1]))
                           + HAD_W'($signed(lp_new[2])) - HAD_W'($signed(lp_new[3]));
                p3_had[2] <= HAD_W'($signed(lp_new[0])) + HAD_W'($signed(lp_new[1]))
                           - HAD_W'($signed(lp_new[2])) - HAD_W'($signed(lp_new[3]));
                p3_had[3] <= HAD_W'($signed(lp_new[0])) - HAD_W'($signed(lp_new[1]))
                           - HAD_W'($signed(lp_new[2])) + HAD_W'($signed(lp_new[3]));
            end
        end
    end

    // ================================================================
    // STAGE 4 — decay multiply
    //   dec_prod[i] = had[i] x decay
    //   4 parallel DSP multipliers inferred
    // ================================================================
    reg                       p4_v;
    reg signed [DATA_W-1:0]  p4_in_l, p4_in_r;
    reg signed [WIDE_W-1:0]  p4_mono;
    reg [PARAM_W-1:0]         p4_mix, p4_width;
    reg signed [WIDE_W-1:0]  p4_lp [3:0];
    // HAD_W (signed) x (PARAM_W+1) (sign-ext unsigned) = HAD_W+PARAM_W+1 = MPROD_W
    reg signed [MPROD_W-1:0]  p4_dec [3:0];

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            p4_v     <= 1'b0;
            p4_dec[0] <= '0; p4_dec[1] <= '0;
            p4_dec[2] <= '0; p4_dec[3] <= '0;
        end else begin
            p4_v     <= p3_v;
            p4_in_l  <= p3_in_l; p4_in_r <= p3_in_r;
            p4_mono  <= p3_mono;
            p4_mix   <= p3_mix;  p4_width <= p3_width;
            p4_lp[0] <= p3_lp[0]; p4_lp[1] <= p3_lp[1];
            p4_lp[2] <= p3_lp[2]; p4_lp[3] <= p3_lp[3];
            p4_dec[0] <= p3_had[0] * $signed({1'b0, p3_decay});
            p4_dec[1] <= p3_had[1] * $signed({1'b0, p3_decay});
            p4_dec[2] <= p3_had[2] * $signed({1'b0, p3_decay});
            p4_dec[3] <= p3_had[3] * $signed({1'b0, p3_decay});
        end
    end

    // ================================================================
    // STAGE 5 — write delay memories, compute wet signals, width multiply
    //
    //   fb[i] = dec_prod[i] >> 9
    //     >>9 = >>8 (param scale) + >>1 (compensates H4 spectral norm of 2)
    //     -> effective gain = decay/256, stable for all decay < 256
    //
    //   Stereo: L <- channels 0,2 ; R <- channels 1,3
    //     (interleaved taps give natural decorrelation)
    //
    //   wr_ptr reset and increment ONLY here — single driver
    // ================================================================
    wire signed [WIDE_W-1:0] fb [3:0];
    assign fb[0] = $signed(p4_dec[0][MPROD_W-2:9]);
    assign fb[1] = $signed(p4_dec[1][MPROD_W-2:9]);
    assign fb[2] = $signed(p4_dec[2][MPROD_W-2:9]);
    assign fb[3] = $signed(p4_dec[3][MPROD_W-2:9]);

    wire signed [WIDE_W-1:0] wet_l_raw = (p4_lp[0] + p4_lp[2]) >>> 1;
    wire signed [WIDE_W-1:0] wet_r_raw = (p4_lp[1] + p4_lp[3]) >>> 1;

    // Width: mid/side blend
    wire signed [WIDE_W-1:0] mid_w  = (wet_l_raw + wet_r_raw) >>> 1;
    wire signed [WIDE_W-1:0] side_w = (wet_l_raw - wet_r_raw) >>> 1;

    reg                       p5_v;
    reg signed [DATA_W-1:0]  p5_in_l, p5_in_r;
    reg signed [WIDE_W-1:0]  p5_mid;
    reg [PARAM_W-1:0]         p5_mix;
    reg signed [MPROD_W-1:0]  p5_width_prod;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            p5_v          <= 1'b0;
            p5_width_prod <= '0;
            // Single driver for wr_ptr — reset lives here only
            wr_ptr[0] <= '0; wr_ptr[1] <= '0;
            wr_ptr[2] <= '0; wr_ptr[3] <= '0;
        end else begin
            p5_v    <= p4_v;
            p5_in_l <= p4_in_l; p5_in_r <= p4_in_r;
            p5_mid  <= mid_w;
            p5_mix  <= p4_mix;
            // Width multiply (1 DSP)
            p5_width_prod <= side_w * $signed({1'b0, p4_width});
            // Write feedback into delay lines and advance pointers
            if (p4_v) begin
                mem0[wr_ptr[0]] <= sat16(MPROD_W'($signed(p4_mono)) + MPROD_W'($signed(fb[0])));
                mem1[wr_ptr[1]] <= sat16(MPROD_W'($signed(p4_mono)) + MPROD_W'($signed(fb[1])));
                mem2[wr_ptr[2]] <= sat16(MPROD_W'($signed(p4_mono)) + MPROD_W'($signed(fb[2])));
                mem3[wr_ptr[3]] <= sat16(MPROD_W'($signed(p4_mono)) + MPROD_W'($signed(fb[3])));
                wr_ptr[0] <= (wr_ptr[0] == MAX_DELAY-1) ? '0 : wr_ptr[0] + 1'b1;
                wr_ptr[1] <= (wr_ptr[1] == MAX_DELAY-1) ? '0 : wr_ptr[1] + 1'b1;
                wr_ptr[2] <= (wr_ptr[2] == MAX_DELAY-1) ? '0 : wr_ptr[2] + 1'b1;
                wr_ptr[3] <= (wr_ptr[3] == MAX_DELAY-1) ? '0 : wr_ptr[3] + 1'b1;
            end
        end
    end

    // ================================================================
    // STAGE 6 — mix multiply
    //   width-adjusted wet:  wet_l = mid + side*width/256
    //                        wet_r = mid - side*width/256
    //   mix: (wet - dry) x mix  [dry added back in stage 7]
    //   2 DSP multipliers
    // ================================================================
    wire signed [WIDE_W-1:0] side_sc  = $signed(p5_width_prod[WIDE_W+PARAM_W-1:PARAM_W]);
    wire signed [WIDE_W-1:0] wet_l_f  = p5_mid + side_sc;
    wire signed [WIDE_W-1:0] wet_r_f  = p5_mid - side_sc;

    wire signed [WIDE_W-1:0] in_l_sx  = {{(WIDE_W-DATA_W){p5_in_l[DATA_W-1]}}, p5_in_l};
    wire signed [WIDE_W-1:0] in_r_sx  = {{(WIDE_W-DATA_W){p5_in_r[DATA_W-1]}}, p5_in_r};

    reg                       p6_v;
    reg signed [DATA_W-1:0]  p6_in_l, p6_in_r;
    reg signed [MPROD_W-1:0]  p6_mix_l, p6_mix_r;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            p6_v     <= 1'b0;
            p6_mix_l <= '0; p6_mix_r <= '0;
        end else begin
            p6_v    <= p5_v;
            p6_in_l <= p5_in_l; p6_in_r <= p5_in_r;
            // (wet - dry) x mix — dry is added back in stage 7
            p6_mix_l <= (wet_l_f - in_l_sx) * $signed({1'b0, p5_mix});
            p6_mix_r <= (wet_r_f - in_r_sx) * $signed({1'b0, p5_mix});
        end
    end

    // ================================================================
    // STAGE 7 — final output + DC blocker
    //   out  = dry + (wet - dry) * mix / 256
    //   DC blocker: y[n] = x[n] - x[n-1] + (255/256) * y[n-1]
    // ================================================================
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            audio_out <= '0;
            xp_l <= '0; xp_r <= '0;
            yp_l <= '0; yp_r <= '0;
        end else if (p6_v) begin
            // Use locals declared with automatic for combinational intermediate
            begin : dc_block
                logic signed [MPROD_W-1:0] raw_l, raw_r, dc_l, dc_r;
                // Mix: dry + scaled (wet-dry)
                raw_l = MPROD_W'($signed(p6_in_l))
                      + $signed(p6_mix_l[WIDE_W+PARAM_W-1:PARAM_W]);
                raw_r = MPROD_W'($signed(p6_in_r))
                      + $signed(p6_mix_r[WIDE_W+PARAM_W-1:PARAM_W]);
                // DC blocker
                dc_l  = raw_l - MPROD_W'($signed(xp_l))
                      + (MPROD_W'($signed(yp_l)) * 255) >>> 8;
                dc_r  = raw_r - MPROD_W'($signed(xp_r))
                      + (MPROD_W'($signed(yp_r)) * 255) >>> 8;
                audio_out[0] <= sat16(dc_l);
                audio_out[1] <= sat16(dc_r);
                xp_l <= sat16(raw_l);
                xp_r <= sat16(raw_r);
                yp_l <= sat16(dc_l);
                yp_r <= sat16(dc_r);
            end
        end
    end

    // ----------------------------------------------------------------
    // Simulation initialisation
    // ----------------------------------------------------------------
    integer ii;
    initial begin
        for (ii = 0; ii < MAX_DELAY; ii = ii + 1) begin
            mem0[ii] = '0; mem1[ii] = '0;
            mem2[ii] = '0; mem3[ii] = '0;
        end
    end

endmodule