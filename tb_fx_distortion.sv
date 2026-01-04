`timescale 1ns/1ps

module tb_fx_distortion;

    // Parameters
    localparam DATA_W = 16;
    localparam PARAM_W = 8;
    localparam CLK_PERIOD = 20; // 50MHz
    
    // DUT signals
    logic clk;
    logic reset_n;
    logic signed [1:0][DATA_W-1:0] audio_in;
    logic signed [1:0][DATA_W-1:0] audio_out;
    logic [PARAM_W-1:0] fx_drive;
    logic [PARAM_W-1:0] fx_mix;
    logic sample_en;
    
    // Instantiate DUT
    fx_distortion #(
        .DATA_W(DATA_W),
        .PARAM_W(PARAM_W)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .audio_in(audio_in),
        .audio_out(audio_out),
        .fx_drive(fx_drive),
        .fx_mix(fx_mix),
        .sample_en(sample_en)
    );
    
    // Clock generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    // Test stimulus
    initial begin
        // Initialize
        reset_n = 0;
        audio_in = '{default: '0};
        fx_drive = 0;
        fx_mix = 0;
        sample_en = 0;
        
        // Reset
        repeat(5) @(posedge clk);
        reset_n = 1;
        @(posedge clk);
        
        $display("\n========================================");
        $display("Distortion Effect Testbench");
        $display("========================================\n");
        
        // Test 1: Zero signal with different mix values
        $display("[%0t ps] TEST 1: Zero Signal", $realtime);
        $display("--------------------");
        fx_drive = 8'd0; // Mid drive
        test_signal(16'sd0, 8'd0, "Mix=0 (Dry)");
        test_signal(16'sd0, 8'd127, "Mix=127 (50%%)");
        test_signal(16'sd0, 8'd255, "Mix=255 (Wet)");
        $display("");
        
        // Test 2: Small signal (should be clean at mix=0)
        $display("[%0t ps] TEST 2: Small Signal (100)", $realtime);
        $display("---------------------------");
        fx_drive = 8'd0;
        test_signal(16'sd100, 8'd0, "Mix=0 (Dry)");
        test_signal(16'sd100, 8'd127, "Mix=127 (50%%)");
        test_signal(16'sd100, 8'd255, "Mix=255 (Wet)");
        $display("");
        
        // Test 3: Medium signal
        $display("[%0t ps] TEST 3: Medium Signal (8000)", $realtime);
        $display("-----------------------------");
        fx_drive = 8'd0;
        test_signal(16'sd8000, 8'd0, "Mix=0 (Dry)");
        test_signal(16'sd8000, 8'd127, "Mix=127 (50%%)");
        test_signal(16'sd8000, 8'd255, "Mix=255 (Wet)");
        $display("");
        
        // Test 4: Large signal (near clipping)
        $display("[%0t ps] TEST 4: Large Signal (20000)", $realtime);
        $display("-----------------------------");
        fx_drive = 8'd0;
        test_signal(16'sd20000, 8'd0, "Mix=0 (Dry)");
        test_signal(16'sd20000, 8'd127, "Mix=127 (50%%)");
        test_signal(16'sd20000, 8'd255, "Mix=255 (Wet)");
        $display("");
        
        // Test 5: Negative signal
        $display("[%0t ps] TEST 5: Negative Signal (-8000)", $realtime);
        $display("--------------------------------");
        fx_drive = 8'd0;
        test_signal(-16'sd8000, 8'd0, "Mix=0 (Dry)");
        test_signal(-16'sd8000, 8'd127, "Mix=127 (50%%)");
        test_signal(-16'sd8000, 8'd255, "Mix=255 (Wet)");
        $display("");
        
        // Test 6: Different drive levels with fixed signal
        $display("[%0t ps] TEST 6: Drive Sweep (Signal=5000, Mix=255)", $realtime);
        $display("-------------------------------------------");
        test_signal_with_drive(16'sd5000, 8'd0, 8'd255, "Drive=0 (Min)");
        test_signal_with_drive(16'sd5000, 8'd64, 8'd255, "Drive=64");
        test_signal_with_drive(16'sd5000, 8'd128, 8'd255, "Drive=128 (Mid)");
        test_signal_with_drive(16'sd5000, 8'd192, 8'd255, "Drive=192");
        test_signal_with_drive(16'sd5000, 8'd255, 8'd255, "Drive=255 (Max)");
        $display("");
        
        // Test 7: Check for buzz with zero input
        $display("[%0t ps] TEST 7: Buzz Test (Zero Input, Various Settings)", $realtime);
        $display("-------------------------------------------------");
        test_signal_with_drive(16'sd0, 8'd255, 8'd0, "Zero In, Max Drive, Dry");
        test_signal_with_drive(16'sd0, 8'd255, 8'd255, "Zero In, Max Drive, Wet");
        test_signal_with_drive(16'sd1, 8'd255, 8'd255, "Tiny In (+1), Max Drive, Wet");
        test_signal_with_drive(-16'sd1, 8'd255, 8'd255, "Tiny In (-1), Max Drive, Wet");
        $display("");
        
        $display("========================================");
        $display("Test Complete!");
        $display("========================================\n");
        
        #1000;
        $stop;
    end
    
    // Task to test a signal
    task test_signal(input logic signed [15:0] signal, input logic [7:0] mix, input string label);
        begin
            audio_in[0] = signal;
            audio_in[1] = signal;
            fx_mix = mix;
            sample_en = 1;
            @(posedge clk);
            sample_en = 0;
            @(posedge clk);
            @(posedge clk); // Wait for output
            
            $display("%s:", label);
            $display("  Input:  L=0x%h, R=0x%h", audio_in[0], audio_in[1]);
            $display("  Output: L=0x%h, R=0x%h", audio_out[0], audio_out[1]);
            
            // Check if output matches input when it should
            if (mix == 0 && signal == audio_out[0]) begin
                $display("  ✓ PASS: Output matches input (as expected for mix=0)");
            end else if (mix == 0 && signal != audio_out[0]) begin
                $display("  ✗ FAIL: Output should match input at mix=0!");
                $display("         Difference: 0x%h", audio_out[0] - signal);
            end
            $display("");
        end
    endtask
    
    // Task to test with specific drive value
    task test_signal_with_drive(input logic signed [15:0] signal, input logic [7:0] drive, input logic [7:0] mix, input string label);
        begin
            audio_in[0] = signal;
            audio_in[1] = signal;
            fx_drive = drive;
            fx_mix = mix;
            sample_en = 1;
            @(posedge clk);
            sample_en = 0;
            @(posedge clk);
            @(posedge clk);
            
            $display("%s:", label);
            $display("  Input:  L=0x%h, R=0x%h (Drive=0x%h, Mix=0x%h)", audio_in[0], audio_in[1], drive, mix);
            $display("  Output: L=0x%h, R=0x%h", audio_out[0], audio_out[1]);
            $display("");
        end
    endtask

endmodule