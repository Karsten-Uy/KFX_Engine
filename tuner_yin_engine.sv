module tuner_yin_engine #(
    parameter int DATA_W      = 16,
    parameter int MAX_LAG     = 1600,
    parameter int MIN_LAG     = 120,
    parameter int WINDOW_SIZE = 8192 
)(
    input  logic clk, reset_n,
    input  logic signed [DATA_W-1:0] audio_in,
    input  logic sample_en,
    output logic [11:0] best_lag_out,
    output logic         data_valid
);

    localparam int COMP_WINDOW = 2048;
    localparam int BUF_BITS    = $clog2(WINDOW_SIZE);
    localparam int ACCUM_W     = 48;
    
    // YIN Threshold for Guitar: ~0.22 (28/128) 
    // Increased from 19/128 to handle harmonic complexity
    localparam logic [7:0] THRESH_NUM  = 8'd28; 
    localparam logic [3:0] THRESH_DEN_SHFT = 4'd7; 

    // ---- 1. Input Pre-Processing (Low Pass Filter) ----
    // A simple 4-sample moving average to kill high-frequency overtones.
    logic signed [DATA_W-1:0] audio_filtered;
    logic signed [DATA_W-1:0] lpf_pipe [3:0];

    always_ff @(posedge clk) begin
        if (sample_en) begin
            lpf_pipe[0] <= audio_in;
            lpf_pipe[1] <= lpf_pipe[0];
            lpf_pipe[2] <= lpf_pipe[1];
            lpf_pipe[3] <= lpf_pipe[2];
        end
    end
    // Average: (s1+s2+s3+s4)/4
    assign audio_filtered = (lpf_pipe[0] >>> 2) + (lpf_pipe[1] >>> 2) + 
                            (lpf_pipe[2] >>> 2) + (lpf_pipe[3] >>> 2);

    // ---- 2. Shadow Buffers ----
    (* ramstyle = "M10K" *) logic signed [DATA_W-1:0] buffer_a [0:WINDOW_SIZE-1];
    (* ramstyle = "M10K" *) logic signed [DATA_W-1:0] buffer_b [0:WINDOW_SIZE-1];

    logic [BUF_BITS-1:0] wptr;
    logic [13:0] sample_cnt;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            wptr <= '0;
            sample_cnt <= '0;
        end else if (sample_en) begin
            buffer_a[wptr] <= audio_filtered;
            buffer_b[wptr] <= audio_filtered;
            wptr <= wptr + 1'b1;
            if (sample_cnt < 14'(WINDOW_SIZE)) sample_cnt <= sample_cnt + 1'b1;
        end
    end

    // ---- 3. FSM and CMNDF Calculation ----
    typedef enum logic [2:0] {S_IDLE, S_SETUP, S_FETCH, S_ACCUM, S_YIN_EVAL} state_t;
    state_t state;

    logic [BUF_BITS-1:0] addr_a, addr_b, base_ptr;
    logic signed [DATA_W-1:0] sa, sb;
    logic [11:0] tau, j, abs_min_lag;
    logic [ACCUM_W-1:0] d_tau, running_sum_d, d_best_global;

    always_ff @(posedge clk) begin
        sa <= buffer_a[addr_a];
        sb <= buffer_b[addr_b];
    end

    logic signed [DATA_W:0] diff;
    logic [31:0] diff_sq;
    assign diff = $signed(sa) - $signed(sb);
    assign diff_sq = 32'(unsigned'(diff * diff));

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= S_IDLE;
            data_valid <= 1'b0;
            best_lag_out <= '0;
        end else begin
            data_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (sample_cnt >= 14'(COMP_WINDOW + MAX_LAG)) begin
                        tau <= 12'(MIN_LAG);
                        running_sum_d <= 48'd1; 
                        d_best_global <= '1;
                        // Freeze a base pointer for the whole scan
                        base_ptr <= wptr - BUF_BITS'(COMP_WINDOW + MAX_LAG);
                        state <= S_SETUP;
                    end
                end

                S_SETUP: begin
                    j <= '0;
                    d_tau <= '0;
                    addr_a <= base_ptr;
                    addr_b <= base_ptr + BUF_BITS'(tau);
                    state <= S_FETCH;
                end

                S_FETCH: state <= S_ACCUM; 

                S_ACCUM: begin
                    d_tau <= d_tau + ACCUM_W'(diff_sq);
                    if (j == 12'(COMP_WINDOW - 1)) begin
                        state <= S_YIN_EVAL;
                    end else begin
                        j <= j + 1'b1;
                        addr_a <= addr_a + 1'b1;
                        addr_b <= addr_b + 1'b1;
                    end
                end

                S_YIN_EVAL: begin
                    running_sum_d <= running_sum_d + d_tau;

                    // YIN Decision: Check if current d(tau) is significantly lower than average
                    // Math: d_tau * tau < running_sum * Threshold
                    if ((d_tau * ACCUM_W'(tau)) < ((running_sum_d * THRESH_NUM) >> THRESH_DEN_SHFT)) begin
                        best_lag_out <= tau;
                        data_valid <= 1'b1;
                        state <= S_IDLE;
                    end 
                    else if (tau == 12'(MAX_LAG)) begin
                        // If no dip hit the threshold, return the best absolute dip found
                        best_lag_out <= abs_min_lag;
                        data_valid <= 1'b1;
                        state <= S_IDLE;
                    end 
                    else begin
                        // Keep track of the absolute best dip as a fallback
                        if (d_tau < d_best_global) begin
                            d_best_global <= d_tau;
                            abs_min_lag <= tau;
                        end
                        tau <= tau + 1'b1;
                        state <= S_SETUP;
                    end
                end
            endcase
        end
    end
endmodule