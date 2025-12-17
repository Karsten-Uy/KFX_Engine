`timescale 1ns / 1ps

module tb_fx_compressor;

    // Parameters
    parameter DATA_W  = 16;
    parameter PARAM_W = 8;
    parameter CLK_PERIOD = 20;  // 50 MHz
    
    // Signals
    logic                          clk;
    logic                          reset_n;
    logic signed [1:0][DATA_W-1:0] audio_in;
    logic signed [1:0][DATA_W-1:0] audio_out;
    logic [PARAM_W-1:0]            fx_threshold;
    logic [PARAM_W-1:0]            fx_ratio;
    logic [PARAM_W-1:0]            fx_attack;
    logic [PARAM_W-1:0]            fx_release;
    logic                          sample_en;
    
    // Sample enable counter (simulate 48 kHz from 50 MHz)
    logic [9:0] sample_count;
    
    // DUT instantiation
    fx_compressor #(
        .DATA_W(DATA_W),
        .PARAM_W(PARAM_W)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .audio_in(audio_in),
        .audio_out(audio_out),
        .fx_threshold(fx_threshold),
        .fx_ratio(fx_ratio),
        .fx_attack(fx_attack),
        .fx_release(fx_release),
        .sample_en(sample_en)
    );
    
    // Clock generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    // Sample enable generation (~48 kHz from 50 MHz)
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            sample_count <= 0;
            sample_en <= 0;
        end else begin
            if (sample_count >= 9) begin  // 50M / 48k ≈ 1042
                sample_count <= 0;
                sample_en <= 1;
            end else begin
                sample_count <= sample_count + 1;
                sample_en <= 0;
            end
        end
    end
    
    // Test stimulus
    integer sample_num;
    real sine_val;
    
    initial begin
        // Initialize
        reset_n = 0;
        audio_in = '0;
        fx_threshold = 8'd64;   // Medium threshold
        fx_ratio = 8'd4;        // 4:1 ratio
        fx_attack = 8'd32;      // Medium attack
        fx_release = 8'd32;     // Medium release
        sample_num = 0;
        
        // Reset
        repeat(10) @(posedge clk);
        reset_n = 1;
        
        $display("Starting compressor test...");
        $display("Threshold: %d, Ratio: %d, Attack: %d, Release: %d", 
                 fx_threshold, fx_ratio, fx_attack, fx_release);
        
        // Test 1: Quiet signal (below threshold)
        $display("\n=== Test 1: Quiet Signal ===");
        for (int i = 0; i < 100; i++) begin
            @(posedge sample_en);
            sine_val = $sin(2.0 * 3.14159 * 1000.0 * sample_num / 48000.0);
            audio_in[0] = $rtoi(sine_val * 4096);  // Low amplitude
            audio_in[1] = audio_in[0];
            sample_num++;
            
            if (i % 20 == 0)
                $display("Sample %0d: In=%0d, Out=%0d", i, audio_in[0], audio_out[0]);
        end
        
        // Test 2: Loud signal (above threshold)
        $display("\n=== Test 2: Loud Signal ===");
        for (int i = 0; i < 100; i++) begin
            @(posedge sample_en);
            sine_val = $sin(2.0 * 3.14159 * 1000.0 * sample_num / 48000.0);
            audio_in[0] = $rtoi(sine_val * 20000);  // High amplitude
            audio_in[1] = audio_in[0];
            sample_num++;
            
            if (i % 20 == 0)
                $display("Sample %0d: In=%0d, Out=%0d", i, audio_in[0], audio_out[0]);
        end
        
        // Test 3: Dynamic range (quiet to loud)
        $display("\n=== Test 3: Dynamic Range ===");
        for (int i = 0; i < 200; i++) begin
            @(posedge sample_en);
            sine_val = $sin(2.0 * 3.14159 * 1000.0 * sample_num / 48000.0);
            // Gradually increase amplitude
            audio_in[0] = $rtoi(sine_val * (4096 + i * 80));
            audio_in[1] = audio_in[0];
            sample_num++;
            
            if (i % 40 == 0)
                $display("Sample %0d: In=%0d, Out=%0d", i, audio_in[0], audio_out[0]);
        end
        
        // Test 4: High threshold (no compression)
        $display("\n=== Test 4: High Threshold (No Compression) ===");
        fx_threshold = 8'd250;  // Very high threshold
        for (int i = 0; i < 100; i++) begin
            @(posedge sample_en);
            sine_val = $sin(2.0 * 3.14159 * 1000.0 * sample_num / 48000.0);
            audio_in[0] = $rtoi(sine_val * 16000);
            audio_in[1] = audio_in[0];
            sample_num++;
            
            if (i % 20 == 0)
                $display("Sample %0d: In=%0d, Out=%0d", i, audio_in[0], audio_out[0]);
        end
        
        // Test 5: Heavy compression
        $display("\n=== Test 5: Heavy Compression (20:1) ===");
        fx_threshold = 8'd32;   // Low threshold
        fx_ratio = 8'd20;       // 20:1 ratio
        for (int i = 0; i < 100; i++) begin
            @(posedge sample_en);
            sine_val = $sin(2.0 * 3.14159 * 1000.0 * sample_num / 48000.0);
            audio_in[0] = $rtoi(sine_val * 20000);
            audio_in[1] = audio_in[0];
            sample_num++;
            
            if (i % 20 == 0)
                $display("Sample %0d: In=%0d, Out=%0d, Ratio=%.1f", 
                         i, audio_in[0], audio_out[0], 
                         audio_in[0] == 0 ? 1.0 : real'(audio_in[0])/real'(audio_out[0]));
        end
        
        $display("\n=== Test Complete ===");
        $stop;
    end

endmodule

