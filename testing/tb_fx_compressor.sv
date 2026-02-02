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
            if (sample_count >= 9) begin
                sample_count <= 0;
                sample_en <= 1;
            end else begin
                sample_count <= sample_count + 1;
                sample_en <= 0;
            end
        end
    end
    
    // Monitoring internal signals
    always @(posedge clk) begin
        if (sample_en && reset_n) begin
            // Detailed debug output every sample
            $display("[T=%0t] peak=%5d env=%5d thresh=%5d over=%6d tgt_gain=%5h gain=%5h | In=%6d Out=%6d", 
                     $time, 
                     dut.peak_level, 
                     dut.envelope, 
                     dut.threshold_scaled,
                     dut.over_threshold,
                     dut.target_gain,
                     dut.gain,
                     audio_in[0], 
                     audio_out[0]);
        end
    end
    
    // Test stimulus
    integer sample_num;
    real sine_val;
    integer test_num;
    
    // Statistics tracking
    integer max_in, max_out, min_in, min_out;
    integer sum_in, sum_out, count;
    
    task reset_stats;
        begin
            max_in = -32768;
            max_out = -32768;
            min_in = 32767;
            min_out = 32767;
            sum_in = 0;
            sum_out = 0;
            count = 0;
        end
    endtask
    
    task update_stats;
        input signed [15:0] in_val;
        input signed [15:0] out_val;
        begin
            if (in_val > max_in) max_in = in_val;
            if (in_val < min_in) min_in = in_val;
            if (out_val > max_out) max_out = out_val;
            if (out_val < min_out) min_out = out_val;
            sum_in = sum_in + (in_val > 0 ? in_val : -in_val);
            sum_out = sum_out + (out_val > 0 ? out_val : -out_val);
            count = count + 1;
        end
    endtask
    
    task print_stats;
        input string test_name;
        real compression_ratio;
        begin
            $display("\n--- %s Statistics ---", test_name);
            $display("Input  - Max: %6d, Min: %6d, Avg: %6d", max_in, min_in, sum_in/count);
            $display("Output - Max: %6d, Min: %6d, Avg: %6d", max_out, min_out, sum_out/count);
            $display("Peak Ratio: %.2f (Out/In)", real'(max_out)/real'(max_in));
            compression_ratio = real'(sum_in) / real'(sum_out);
            $display("Avg Ratio: %.2f (In/Out)", compression_ratio);
            $display("Symmetry Check - In: %d, Out: %d", max_in + min_in, max_out + min_out);
            
            // Check for issues
            if ((max_out + min_out) > 500 || (max_out + min_out) < -500)
                $display("*** WARNING: Asymmetry detected! Possible sign error!");
            if (max_out > 32767 || min_out < -32768)
                $display("*** ERROR: Clipping/overflow detected!");
        end
    endtask

    logic signed [15:0] dc_levels[5];    



    initial begin
        // Initialize
        reset_n = 0;
        audio_in = '0;
        sample_num = 0;
        test_num = 0;
        
        // Reset
        repeat(10) @(posedge clk);
        reset_n = 1;
        repeat(10) @(posedge clk);
        
        $display("\n========================================");
        $display("ENHANCED COMPRESSOR DIAGNOSTIC TEST");
        $display("========================================\n");
        
        // ================================================
        // TEST 0: BYPASS/PASSTHROUGH TEST
        // ================================================
        test_num = 0;
        $display("\n=== TEST %0d: BYPASS (Unity Gain) ===", test_num);
        $display("Checking if compressor passes audio at all...");
        fx_threshold = 8'd255;  // Maximum threshold (no compression)
        fx_ratio = 8'd1;        // 1:1 ratio (no compression)
        fx_attack = 8'd128;
        fx_release = 8'd128;
        
        reset_stats();
        repeat(20) @(posedge sample_en);  // Let it settle
        
        for (int i = 0; i < 50; i++) begin
            @(posedge sample_en);
            sine_val = $sin(2.0 * 3.14159 * 1000.0 * sample_num / 48000.0);
            audio_in[0] = $rtoi(sine_val * 10000);
            audio_in[1] = audio_in[0];
            sample_num++;
            update_stats(audio_in[0], audio_out[0]);
        end
        print_stats("BYPASS");
        
        // ================================================
        // TEST 1: STATIC DC TEST
        // ================================================
        test_num++;
        $display("\n=== TEST %0d: STATIC DC LEVELS ===", test_num);
        $display("Testing various DC input levels...");
        
        dc_levels = '{16'sd0, 16'sd5000, -16'sd5000, 16'sd15000, -16'sd15000};
        
        for (int dc_idx = 0; dc_idx < 5; dc_idx++) begin
            audio_in[0] = dc_levels[dc_idx];
            audio_in[1] = dc_levels[dc_idx];
            repeat(30) @(posedge sample_en);
            $display("DC In: %6d -> Out: %6d (Gain=%5h, Env=%5d)", 
                     dc_levels[dc_idx], audio_out[0], dut.gain, dut.envelope);
        end
        
        // ================================================
        // TEST 2: THRESHOLD SWEEP
        // ================================================
        test_num++;
        $display("\n=== TEST %0d: THRESHOLD SWEEP ===", test_num);
        $display("Testing different thresholds with same input...");
        
        fx_ratio = 8'd4;
        
        for (int thresh = 32; thresh <= 128; thresh += 32) begin
            fx_threshold = thresh;
            $display("\n--- Threshold = %0d (scaled: %0d) ---", thresh, thresh * 128);
            
            reset_stats();
            repeat(20) @(posedge sample_en);  // Settle
            
            for (int i = 0; i < 50; i++) begin
                @(posedge sample_en);
                sine_val = $sin(2.0 * 3.14159 * 1000.0 * sample_num / 48000.0);
                audio_in[0] = $rtoi(sine_val * 15000);
                audio_in[1] = audio_in[0];
                sample_num++;
                update_stats(audio_in[0], audio_out[0]);
            end
            print_stats($sformatf("Threshold=%0d", thresh));
        end
        
        // ================================================
        // TEST 3: RATIO SWEEP
        // ================================================
        test_num++;
        $display("\n=== TEST %0d: RATIO SWEEP ===", test_num);
        $display("Testing different compression ratios...");
        
        fx_threshold = 8'd64;
        
        for (int ratio = 2; ratio <= 20; ratio *= 2) begin
            fx_ratio = ratio;
            $display("\n--- Ratio = %0d:1 ---", ratio);
            
            reset_stats();
            repeat(20) @(posedge sample_en);  // Settle
            
            for (int i = 0; i < 50; i++) begin
                @(posedge sample_en);
                sine_val = $sin(2.0 * 3.14159 * 1000.0 * sample_num / 48000.0);
                audio_in[0] = $rtoi(sine_val * 20000);
                audio_in[1] = audio_in[0];
                sample_num++;
                update_stats(audio_in[0], audio_out[0]);
            end
            print_stats($sformatf("Ratio=%0d:1", ratio));
        end
        
        // ================================================
        // TEST 4: ATTACK/RELEASE RESPONSE
        // ================================================
        test_num++;
        $display("\n=== TEST %0d: ATTACK/RELEASE TIMING ===", test_num);
        $display("Testing envelope follower response...");
        
        fx_threshold = 8'd64;
        fx_ratio = 8'd4;
        fx_attack = 8'd128;
        fx_release = 8'd128;
        
        // Start with silence
        audio_in = '0;
        repeat(50) @(posedge sample_en);
        $display("Baseline envelope: %d (should be near 0)", dut.envelope);
        
        // Sudden loud signal
        $display("\nApplying sudden loud signal...");
        for (int i = 0; i < 100; i++) begin
            @(posedge sample_en);
            audio_in[0] = 16'sd15000;
            audio_in[1] = 16'sd15000;
            if (i % 10 == 0)
                $display("Sample %3d: Env=%5d, Gain=%5h", i, dut.envelope, dut.gain);
        end
        
        // Back to silence
        $display("\nRemoving signal (release phase)...");
        audio_in = '0;
        for (int i = 0; i < 100; i++) begin
            @(posedge sample_en);
            if (i % 10 == 0)
                $display("Sample %3d: Env=%5d, Gain=%5h", i, dut.envelope, dut.gain);
        end
        
        // ================================================
        // TEST 5: EXTREME VALUES
        // ================================================
        test_num++;
        $display("\n=== TEST %0d: EXTREME VALUE HANDLING ===", test_num);
        
        fx_threshold = 8'd64;
        fx_ratio = 8'd4;
        
        // Max positive
        audio_in[0] = 16'sd32767;
        audio_in[1] = 16'sd32767;
        repeat(30) @(posedge sample_en);
        $display("Max Positive In: %6d -> Out: %6d", audio_in[0], audio_out[0]);
        
        // Max negative
        audio_in[0] = -16'sd32768;
        audio_in[1] = -16'sd32768;
        repeat(30) @(posedge sample_en);
        $display("Max Negative In: %6d -> Out: %6d", audio_in[0], audio_out[0]);
        
        // Alternating extremes
        $display("\nAlternating extremes...");
        for (int i = 0; i < 20; i++) begin
            @(posedge sample_en);
            audio_in[0] = (i % 2) ? 16'sd20000 : -16'sd20000;
            audio_in[1] = audio_in[0];
            if (i < 10)
                $display("In: %6d, Out: %6d, Gain: %5h", audio_in[0], audio_out[0], dut.gain);
        end
        
        // ================================================
        // TEST 6: PARAMETER VALIDATION
        // ================================================
        test_num++;
        $display("\n=== TEST %0d: PARAMETER EDGE CASES ===", test_num);
        
        // Zero threshold
        fx_threshold = 8'd0;
        fx_ratio = 8'd4;
        audio_in[0] = 16'sd10000;
        audio_in[1] = 16'sd10000;
        repeat(30) @(posedge sample_en);
        $display("Zero threshold: Gain=%5h (should compress everything)", dut.gain);
        
        // Ratio = 1 (no compression)
        fx_threshold = 8'd64;
        fx_ratio = 8'd1;
        repeat(30) @(posedge sample_en);
        $display("Ratio=1: Gain=%5h (should be 7FFF)", dut.gain);
        
        // Ratio = 255 (extreme compression)
        fx_ratio = 8'd255;
        repeat(30) @(posedge sample_en);
        $display("Ratio=255: Gain=%5h (should be very low)", dut.gain);
        
        $display("\n========================================");
        $display("DIAGNOSTIC TEST COMPLETE");
        $display("========================================\n");
        
        $display("Check above output for:");
        $display("1. Is audio passing through at all? (TEST 0)");
        $display("2. Are DC levels handled correctly? (TEST 1)");
        $display("3. Does threshold affect compression? (TEST 2)");
        $display("4. Does ratio affect compression amount? (TEST 3)");
        $display("5. Does envelope follow signal? (TEST 4)");
        $display("6. Are extreme values handled? (TEST 5)");
        
        $stop;
    end
   

endmodule