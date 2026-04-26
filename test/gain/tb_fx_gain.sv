// -----------------------------------------------------------------------------
// Top-Level Testbench (Updated)
// -----------------------------------------------------------------------------
module tb_fx_gain;

    import fx_gain_tb_pkg::*;

    // Clock and Reset logic
    logic clk;
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz clock
    end

    // Instantiate interface
    fx_gain_if vif(clk);

    // Instantiate DUT
    fx_gain #(
        .DATA_W(16),
        .PARAM_W(8)
    ) dut (
        .clk(vif.clk),
        .reset_n(vif.reset_n),
        .audio_in(vif.audio_in),
        .audio_out(vif.audio_out),
        .fx_gain(vif.fx_gain),
        .sample_en(vif.sample_en)
    );

    // -------------------------------------------------------------------------
    // Instantiate the Reusable Monitor
    // -------------------------------------------------------------------------
    fx_monitor #(
        .DATA_W(16),
        .LATENCY(1),         // fx_gain has a 1-cycle latency
        .NAME("GAIN_DUT")
    ) monitor_inst (
        .clk(vif.clk),
        .reset_n(vif.reset_n),
        .sample_en(vif.sample_en),
        .audio_out(vif.audio_out)
    );

    // Test Execution Block
    initial begin

        // Declare components
        mailbox #(fx_gain_item) mbx;
        fx_gain_driver          driver;
        fx_gain_sequence        seq;

        // Construct components
        mbx    = new();
        driver = new(vif, mbx);
        seq    = new(mbx);

        // Start Driver thread in the background
        fork
            driver.run();
        join_none

        // Reset sequence
        vif.reset_n = 1'b0;
        repeat(5) @(posedge vif.clk);
        vif.reset_n = 1'b1;
        repeat(2) @(posedge vif.clk);

        // Run the sequence
        seq.body();

        // Wait a few cycles to allow the last transaction to clear the DUT
        repeat(10) @(posedge vif.clk);
        
        $display("[%0t] Testbench Finished.", $time);
        $stop(0);
    end

endmodule