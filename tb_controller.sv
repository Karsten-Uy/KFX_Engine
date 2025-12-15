`timescale 1ns/1ps

module tb_controller;

	// ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;

    // ---------------- Parameters ----------------
    localparam FX_COUNT    = 16;
    localparam PARAM_COUNT = 8;
    localparam PARAM_W     = 7;

    // ---------------- DUT Signals ----------------
    logic clk;
    logic reset_n;

    logic [3:0] sw_fx_sel;
    logic [2:0] sw_param_sel;
    logic key_inc;
    logic key_dec;

    logic [PARAM_W-1:0] params [0:FX_COUNT-1][0:PARAM_COUNT-1];
    logic [3:0]         fx_sel;
    logic [2:0]         param_sel;
    logic [PARAM_W-1:0] current_value;

    // ---------------- Clock ----------------
    always #10 clk = ~clk;   // 50 MHz

    // ---------------- DUT ----------------
    controller #(
        .FX_COUNT(FX_COUNT),
        .PARAM_COUNT(PARAM_COUNT),
        .PARAM_W(PARAM_W),
        .DEBOUNCE_CNT_MAX(8)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .sw_fx_sel(sw_fx_sel),
        .sw_param_sel(sw_param_sel),
        .key_inc(key_inc),
        .key_dec(key_dec),
        .params(params),
        .fx_sel(fx_sel),
        .param_sel(param_sel),
        .current_value(current_value)
    );

    // ---------------- Tasks ----------------
    task press_inc;
        begin
            key_inc = 1'b1;
            repeat (12) @(posedge clk);
            key_inc = 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    task press_dec;
        begin
            key_dec = 1'b1;
            repeat (12) @(posedge clk);
            key_dec = 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    // ---------------- Test Sequence ----------------
    initial begin
        // Init
        clk = 0;
        reset_n = 0;
        sw_fx_sel = 0;
        sw_param_sel = 0;
        key_inc = 0;
        key_dec = 0;

        // Reset
        repeat (5) @(posedge clk);
        reset_n = 1;

        // Wait for reset init
        repeat (5) @(posedge clk);

        // ---------------- Test 1: Defaults ----------------
        $display("TEST 1: Default values");
        @(negedge clk);
        assert(current_value == param_default(0,0))
            else $error("Default mismatch");

        // ---------------- Test 2: Increment ----------------
        $display("TEST 2: Increment param");
        press_inc();
        @(negedge clk);
        assert(current_value == param_default(0,0) + INCDEC_AMOUNT)
            else $error("Increment failed");

        // ---------------- Test 3: Decrement ----------------
        $display("TEST 3: Decrement param");
        press_dec();
        @(negedge clk);
        assert(current_value == param_default(0,0))
            else $error("Decrement failed");

        // ---------------- Test 4: Change FX & Param ----------------
        $display("TEST 4: FX / param select");
        sw_fx_sel = 4'd2;
        sw_param_sel = 3'd1;
        repeat (2) @(posedge clk);

        assert(current_value == param_default(2,1))
            else $error("FX/param select failed");

        // ---------------- Test 5: Isolation ----------------
        $display("TEST 5: Param isolation");
        press_inc();
        @(negedge clk);
        assert(params[2][1] == param_default(2,1) + INCDEC_AMOUNT)
            else $error("Selected param wrong");
        assert(params[2][0] == param_default(2,0))
            else $error("Unselected param modified");
        
        $display("Done Tests");
        $error;
    end

endmodule
