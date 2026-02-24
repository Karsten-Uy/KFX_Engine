/*

    Reverb module that implements the Schroeder Reverberator that uses a combination 
    of parallel feedback comb filters and series all-pass filters to simulate reverberation
    in a room

    Parameters:
        fx_size     - Controls the "size" of the room AKA delay times (0-255)
        fx_damping  - Controls how much the reverberation is damped (0-255)
        fx_mix      - Mix control determining how much of the wet signal is in
                      the output of this FX. (fx_mix == 0) => all dry, 
                      (fx_mix == 255) => all wet

    Architecture uses a two-stage filter design:
    
    Stage 1 - Parallel Feedback Comb Filters (4 filters per channel, L+R independent):
        Creates the initial reverb tail with different delay times. Each comb filter
        implements the following difference equation where g is the feedback gain
        (controlled by fx_damping), and d is the delay time (controlled by fx_size):
        
            y[n] = x[n] + g * y[n-d]
            output[n] = y[n-d]
        
        The four comb filters have prime number base delays to avoid modal resonances.
        Delays are larger than the original for a longer, more room-like tail:
            - Comb 1: 1557 samples (~32ms) base delay
            - Comb 2: 1617 samples (~34ms) base delay  
            - Comb 3: 1871 samples (~39ms) base delay
            - Comb 4: 1997 samples (~42ms) base delay
        
        fx_size scales these delays: delay = base_delay * (1.0 + fx_size/256)
        
        All comb outputs (per channel) are summed together.
    
    Stage 2 - Series Allpass Filters (3 filters per channel, cascaded):
        Diffuses the summed comb output without changing frequency response.
        Each allpass filter implements the difference equation where g = 0.5
        and d is a fixed delay:
        
            y[n] = -g*x[n] + x[n-d] + g*y[n-d]
        
        The three allpass filters have fixed delays:
            - Allpass 1: 556 samples (~12ms)
            - Allpass 2: 441 samples (~9ms)
            - Allpass 3: 341 samples (~7ms)  ← new stage for smoother tail
    
    Signal flow (per channel):
        Audio In (L or R) → [Comb1..4] → Sum → Divide by 4 →
        Allpass1 → Allpass2 → Allpass3 → Wet Signal → Mix with Dry → Audio Out
    
    The output is:
        audio_out[n] = (wet_signal[n] * fx_mix + dry_signal[n] * (256 - fx_mix)) / 256
    
    Latency = 5 Samples (one extra vs. original due to added allpass stage)

    Changes from original:
        - True stereo: independent L/R comb+allpass banks (8 comb lines, 6 allpass lines)
        - Larger base delays for a longer reverb tail
        - Higher feedback ceiling (damping_factor max raised to ~248) for slower decay
        - Third allpass stage for smoother, less metallic tail texture

*/

module fx_reverb #(
    parameter DATA_W  = 16,
    parameter PARAM_W = 8
)(
    input  logic                          clk,
    input  logic                          reset_n,
    input  logic signed [1:0][DATA_W-1:0] audio_in,   // Stereo input
    output logic signed [1:0][DATA_W-1:0] audio_out,  // Stereo output
    input  logic [PARAM_W-1:0]            fx_size,
    input  logic [PARAM_W-1:0]            fx_damping,
    input  logic [PARAM_W-1:0]            fx_mix,
    input  logic                          sample_en
);

    // ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;
        
    // ---------------- CONSTANTS ----------------
    // Schroeder Reverb: 4 parallel comb filters + 3 series allpass filters, per channel
    // Prime number delays for natural sound (avoid modal resonances)
    // Delays are larger than original for a longer, more room-like tail

    // Comb filter delays (in samples at 48kHz)
    localparam COMB1_BASE = 1557;  // ~32ms (was 1117)
    localparam COMB2_BASE = 1617;  // ~34ms (was 1171)
    localparam COMB3_BASE = 1871;  // ~39ms (was 1277)
    localparam COMB4_BASE = 1997;  // ~42ms (was 1356)
    
    // Allpass filter delays
    localparam ALLPASS1_DELAY = 556;   // ~12ms
    localparam ALLPASS2_DELAY = 441;   // ~9ms
    localparam ALLPASS3_DELAY = 341;   // ~7ms (new stage)
    
    // Maximum delay for buffer sizing.
    // At max fx_size (255), delay = base * (1 + 255/256) ≈ base * 2.
    // So MAX = COMB4_BASE * 2 = 3994, round up to a clean value.
    localparam MAX_COMB_DELAY  = 3994;
    localparam COMB_ADDR_W     = $clog2(MAX_COMB_DELAY);
    localparam ALLPASS_ADDR_W  = $clog2(ALLPASS1_DELAY);  // largest allpass delay
    
    // Allpass coefficient (fixed at 0.5 for stability)
    localparam ALLPASS_COEF = 8'd128;
    
    // ---------------- INTERNAL SIGNALS ----------------

    // Delay calculations (shared L/R, same room geometry)
    logic [COMB_ADDR_W-1:0] comb1_delay, comb2_delay, comb3_delay, comb4_delay;

    // Feedback / damping
    logic [7:0] comb_feedback;
    logic [7:0] damping_factor;

    // ------ LEFT channel comb filter signals ------
    logic signed [DATA_W-1:0]   comb1L_out,     comb2L_out,     comb3L_out,     comb4L_out;
    logic signed [DATA_W-1:0]   comb1L_delayed, comb2L_delayed, comb3L_delayed, comb4L_delayed;
    logic signed [DATA_W-1:0]   comb1L_in,      comb2L_in,      comb3L_in,      comb4L_in;
    logic signed [31:0]         comb1L_fb,      comb2L_fb,      comb3L_fb,      comb4L_fb;
    logic signed [DATA_W+1:0]   comb_sum_L;

    // ------ RIGHT channel comb filter signals ------
    logic signed [DATA_W-1:0]   comb1R_out,     comb2R_out,     comb3R_out,     comb4R_out;
    logic signed [DATA_W-1:0]   comb1R_delayed, comb2R_delayed, comb3R_delayed, comb4R_delayed;
    logic signed [DATA_W-1:0]   comb1R_in,      comb2R_in,      comb3R_in,      comb4R_in;
    logic signed [31:0]         comb1R_fb,      comb2R_fb,      comb3R_fb,      comb4R_fb;
    logic signed [DATA_W+1:0]   comb_sum_R;

    // ------ LEFT channel allpass signals ------
    logic signed [DATA_W-1:0]   allpass1L_in,  allpass1L_out,  allpass1L_delayed;
    logic signed [DATA_W-1:0]   allpass2L_in,  allpass2L_out,  allpass2L_delayed;
    logic signed [DATA_W-1:0]   allpass3L_in,  allpass3L_out,  allpass3L_delayed;
    logic signed [31:0]         ap1L_feed, ap1L_back;
    logic signed [31:0]         ap2L_feed, ap2L_back;
    logic signed [31:0]         ap3L_feed, ap3L_back;

    // ------ RIGHT channel allpass signals ------
    logic signed [DATA_W-1:0]   allpass1R_in,  allpass1R_out,  allpass1R_delayed;
    logic signed [DATA_W-1:0]   allpass2R_in,  allpass2R_out,  allpass2R_delayed;
    logic signed [DATA_W-1:0]   allpass3R_in,  allpass3R_out,  allpass3R_delayed;
    logic signed [31:0]         ap1R_feed, ap1R_back;
    logic signed [31:0]         ap2R_feed, ap2R_back;
    logic signed [31:0]         ap3R_feed, ap3R_back;

    // Final mix
    logic signed [DATA_W-1:0]   wet_L, wet_R;
    logic signed [31:0]         mixed_L,       mixed_R;
    logic signed [31:0]         dry_L,         dry_R;
    logic signed [31:0]         wet_scaled_L,  wet_scaled_R;
    logic signed [8:0]          dry_gain;

    // ---------------- DELAY LINE INSTANTIATION ----------------
    // 4 comb delay lines for LEFT channel

    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W)
    ) comb1L_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(comb1L_in), .data_out(comb1L_delayed), .delay_samples(comb1_delay)
    );
    
    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W)
    ) comb2L_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(comb2L_in), .data_out(comb2L_delayed), .delay_samples(comb2_delay)
    );
    
    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W)
    ) comb3L_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(comb3L_in), .data_out(comb3L_delayed), .delay_samples(comb3_delay)
    );
    
    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W)
    ) comb4L_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(comb4L_in), .data_out(comb4L_delayed), .delay_samples(comb4_delay)
    );

    // 4 comb delay lines for RIGHT channel

    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W)
    ) comb1R_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(comb1R_in), .data_out(comb1R_delayed), .delay_samples(comb1_delay)
    );
    
    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W)
    ) comb2R_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(comb2R_in), .data_out(comb2R_delayed), .delay_samples(comb2_delay)
    );
    
    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W)
    ) comb3R_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(comb3R_in), .data_out(comb3R_delayed), .delay_samples(comb3_delay)
    );
    
    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(MAX_COMB_DELAY), .ADDR_W(COMB_ADDR_W)
    ) comb4R_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(comb4R_in), .data_out(comb4R_delayed), .delay_samples(comb4_delay)
    );

    // 3 allpass delay lines for LEFT channel

    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS1_DELAY), .ADDR_W(ALLPASS_ADDR_W)
    ) allpass1L_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(allpass1L_in), .data_out(allpass1L_delayed),
        .delay_samples(ALLPASS1_DELAY[ALLPASS_ADDR_W-1:0])
    );
    
    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS2_DELAY), .ADDR_W(ALLPASS_ADDR_W)
    ) allpass2L_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(allpass2L_in), .data_out(allpass2L_delayed),
        .delay_samples(ALLPASS2_DELAY[ALLPASS_ADDR_W-1:0])
    );

    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS3_DELAY), .ADDR_W(ALLPASS_ADDR_W)
    ) allpass3L_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(allpass3L_in), .data_out(allpass3L_delayed),
        .delay_samples(ALLPASS3_DELAY[ALLPASS_ADDR_W-1:0])
    );

    // 3 allpass delay lines for RIGHT channel

    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS1_DELAY), .ADDR_W(ALLPASS_ADDR_W)
    ) allpass1R_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(allpass1R_in), .data_out(allpass1R_delayed),
        .delay_samples(ALLPASS1_DELAY[ALLPASS_ADDR_W-1:0])
    );
    
    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS2_DELAY), .ADDR_W(ALLPASS_ADDR_W)
    ) allpass2R_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(allpass2R_in), .data_out(allpass2R_delayed),
        .delay_samples(ALLPASS2_DELAY[ALLPASS_ADDR_W-1:0])
    );

    delay_line #(
        .DATA_W(DATA_W), .MAX_DELAY_SAMPLES(ALLPASS3_DELAY), .ADDR_W(ALLPASS_ADDR_W)
    ) allpass3R_delay_line (
        .clk(clk), .reset_n(reset_n), .sample_en(sample_en),
        .data_in(allpass3R_in), .data_out(allpass3R_delayed),
        .delay_samples(ALLPASS3_DELAY[ALLPASS_ADDR_W-1:0])
    );

    // ---------------------- COMB FILTERS ---------------------

    // Dynamic delay calculation based on fx_size (shared geometry for L+R)
    // Scale delays: base_delay * (1.0 + fx_size/256)
    always_comb begin
        comb1_delay = COMB1_BASE + ((COMB1_BASE * fx_size) >> 8);
        comb2_delay = COMB2_BASE + ((COMB2_BASE * fx_size) >> 8);
        comb3_delay = COMB3_BASE + ((COMB3_BASE * fx_size) >> 8);
        comb4_delay = COMB4_BASE + ((COMB4_BASE * fx_size) >> 8);
    end
    
    // Feedback gain with damping.
    // Max raised to 248 (was 216) so tail decays much more slowly at low fx_damping.
    // fx_damping=0   → damping_factor=248 → g≈0.97  (very long tail)
    // fx_damping=255 → damping_factor=120 → g≈0.47  (heavily damped)
    always_comb begin
        damping_factor = 8'd248 - (fx_damping >> 1);
        comb_feedback  = damping_factor;
    end

    // LEFT channel comb filter
    always_comb begin
        comb1L_fb = ($signed(comb1L_delayed) * $signed({1'b0, comb_feedback})) >>> 8;
        comb2L_fb = ($signed(comb2L_delayed) * $signed({1'b0, comb_feedback})) >>> 8;
        comb3L_fb = ($signed(comb3L_delayed) * $signed({1'b0, comb_feedback})) >>> 8;
        comb4L_fb = ($signed(comb4L_delayed) * $signed({1'b0, comb_feedback})) >>> 8;

        comb1L_in = sat16($signed(audio_in[0]) + comb1L_fb);
        comb2L_in = sat16($signed(audio_in[0]) + comb2L_fb);
        comb3L_in = sat16($signed(audio_in[0]) + comb3L_fb);
        comb4L_in = sat16($signed(audio_in[0]) + comb4L_fb);

        comb1L_out = comb1L_delayed;
        comb2L_out = comb2L_delayed;
        comb3L_out = comb3L_delayed;
        comb4L_out = comb4L_delayed;

        comb_sum_L = $signed(comb1L_out) + $signed(comb2L_out) +
                     $signed(comb3L_out) + $signed(comb4L_out);
    end

    // RIGHT channel comb filter
    always_comb begin
        comb1R_fb = ($signed(comb1R_delayed) * $signed({1'b0, comb_feedback})) >>> 8;
        comb2R_fb = ($signed(comb2R_delayed) * $signed({1'b0, comb_feedback})) >>> 8;
        comb3R_fb = ($signed(comb3R_delayed) * $signed({1'b0, comb_feedback})) >>> 8;
        comb4R_fb = ($signed(comb4R_delayed) * $signed({1'b0, comb_feedback})) >>> 8;

        comb1R_in = sat16($signed(audio_in[1]) + comb1R_fb);
        comb2R_in = sat16($signed(audio_in[1]) + comb2R_fb);
        comb3R_in = sat16($signed(audio_in[1]) + comb3R_fb);
        comb4R_in = sat16($signed(audio_in[1]) + comb4R_fb);

        comb1R_out = comb1R_delayed;
        comb2R_out = comb2R_delayed;
        comb3R_out = comb3R_delayed;
        comb4R_out = comb4R_delayed;

        comb_sum_R = $signed(comb1R_out) + $signed(comb2R_out) +
                     $signed(comb3R_out) + $signed(comb4R_out);
    end

    // ----------------------- ALLPASS FILTERS (Series, per channel) ----------------------

    // LEFT channel - scale down comb sum before allpass (divide by 4)
    always_comb begin
        allpass1L_in = sat16(comb_sum_L >>> 2);
    end

    // LEFT Allpass 1
    always_comb begin
        ap1L_feed    = ($signed(allpass1L_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap1L_back    = ($signed(allpass1L_delayed)  * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass1L_out = sat16(-ap1L_feed + $signed(allpass1L_delayed) + ap1L_back);
    end

    // LEFT Allpass 2
    always_comb begin
        allpass2L_in  = allpass1L_out;
        ap2L_feed     = ($signed(allpass2L_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap2L_back     = ($signed(allpass2L_delayed)  * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass2L_out = sat16(-ap2L_feed + $signed(allpass2L_delayed) + ap2L_back);
    end

    // LEFT Allpass 3 (new stage)
    always_comb begin
        allpass3L_in  = allpass2L_out;
        ap3L_feed     = ($signed(allpass3L_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap3L_back     = ($signed(allpass3L_delayed)  * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass3L_out = sat16(-ap3L_feed + $signed(allpass3L_delayed) + ap3L_back);
    end

    // RIGHT channel - scale down comb sum before allpass (divide by 4)
    always_comb begin
        allpass1R_in = sat16(comb_sum_R >>> 2);
    end

    // RIGHT Allpass 1
    always_comb begin
        ap1R_feed     = ($signed(allpass1R_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap1R_back     = ($signed(allpass1R_delayed)  * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass1R_out = sat16(-ap1R_feed + $signed(allpass1R_delayed) + ap1R_back);
    end

    // RIGHT Allpass 2
    always_comb begin
        allpass2R_in  = allpass1R_out;
        ap2R_feed     = ($signed(allpass2R_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap2R_back     = ($signed(allpass2R_delayed)  * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass2R_out = sat16(-ap2R_feed + $signed(allpass2R_delayed) + ap2R_back);
    end

    // RIGHT Allpass 3 (new stage)
    always_comb begin
        allpass3R_in  = allpass2R_out;
        ap3R_feed     = ($signed(allpass3R_in)      * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        ap3R_back     = ($signed(allpass3R_delayed)  * $signed({1'b0, ALLPASS_COEF})) >>> 8;
        allpass3R_out = sat16(-ap3R_feed + $signed(allpass3R_delayed) + ap3R_back);
    end

    // ----------------------- MIX -----------------------

    always_comb begin
        // Wet signal now comes from independent L/R allpass chains
        wet_L = allpass3L_out;
        wet_R = allpass3R_out;

        dry_gain = 9'sd256 - $signed({1'b0, fx_mix});

        wet_scaled_L = ($signed(wet_L) * $signed({1'b0, fx_mix}));
        wet_scaled_R = ($signed(wet_R) * $signed({1'b0, fx_mix}));
        dry_L        = ($signed(audio_in[0]) * dry_gain);
        dry_R        = ($signed(audio_in[1]) * dry_gain);
        mixed_L      = (wet_scaled_L + dry_L) >>> 8;
        mixed_R      = (wet_scaled_R + dry_R) >>> 8;
    end

    // ---------------- OUTPUT ----------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            audio_out <= '0;
        end else if (sample_en) begin
            audio_out[0] <= sat16(mixed_L);
            audio_out[1] <= sat16(mixed_R);
        end
    end

endmodule