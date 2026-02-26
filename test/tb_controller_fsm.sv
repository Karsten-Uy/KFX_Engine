`timescale 1ns/1ps

module tb_controller_fsm;

    localparam FX_COUNT     = 16;
    localparam PARAM_COUNT  = 8;
    localparam FLASH_BASE   = 24'h400000;
    localparam TOTAL_PARAMS = FX_COUNT * PARAM_COUNT;

    // ----------------------------------------------------------------
    // DUT signals
    // ----------------------------------------------------------------
    logic clk, rst_n;
    logic save_en, load_en;
    logic [$clog2(FX_COUNT)-1:0]    curr_fx;
    logic [$clog2(PARAM_COUNT)-1:0] curr_p;

    logic flash_mem_waitrequest;
    logic flash_csr_waitrequest;
    logic flash_readdatavalid;

    logic ld_from_mem, inc_idx, rst_idx, fsm_busy;
    logic [23:0] flash_addr;
    logic        flash_read, flash_write;
    logic [5:0]  flash_csr_addr;
    logic        flash_csr_write;
    logic [3:0]  fsm_state_debug;

    event tb_done;
    int   t;

    // ----------------------------------------------------------------
    // DUT
    // ----------------------------------------------------------------
    controller_fsm #(
        .FX_COUNT   (FX_COUNT),
        .PARAM_COUNT(PARAM_COUNT),
        .FLASH_BASE (FLASH_BASE)
    ) dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .save_en              (save_en),
        .load_en              (load_en),
        .curr_fx              (curr_fx),
        .curr_p               (curr_p),
        .flash_waitrequest    (flash_mem_waitrequest),
        .flash_readdatavalid  (flash_readdatavalid),
        .flash_csr_waitrequest(flash_csr_waitrequest),
        .ld_from_mem          (ld_from_mem),
        .inc_idx              (inc_idx),
        .rst_idx              (rst_idx),
        .fsm_busy             (fsm_busy),
        .flash_addr           (flash_addr),
        .flash_read           (flash_read),
        .flash_write          (flash_write),
        .flash_csr_addr       (flash_csr_addr),
        .flash_csr_write      (flash_csr_write),
        .fsm_state_debug      (fsm_state_debug)
    );

    // ----------------------------------------------------------------
    // Clock — 50 MHz
    // ----------------------------------------------------------------
    initial clk = 0;
    always #10 clk = ~clk;

    // ----------------------------------------------------------------
    // Traversal counters
    // ----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n || rst_idx) begin
            curr_fx <= '0;
            curr_p  <= '0;
        end else if (inc_idx) begin
            if (curr_p == PARAM_COUNT - 1) begin
                curr_p  <= '0;
                curr_fx <= curr_fx + 1'b1;
            end else begin
                curr_p <= curr_p + 1'b1;
            end
        end
    end

    // ----------------------------------------------------------------
    // Mock flash memory model
    // ----------------------------------------------------------------
    logic [7:0] flash_mem_model [0:TOTAL_PARAMS-1];

    // ----------------------------------------------------------------
    // Monitor — #1 after posedge avoids races with comb outputs
    // ----------------------------------------------------------------
    int save_count, load_count, ld_mem_count, errors;
    logic [23:0] write_addresses [0:TOTAL_PARAMS-1];
    logic [23:0] read_addresses  [0:TOTAL_PARAMS-1];
    logic [$clog2(FX_COUNT)-1:0]    store_fx [0:TOTAL_PARAMS-1];
    logic [$clog2(PARAM_COUNT)-1:0] store_p  [0:TOTAL_PARAMS-1];

    initial begin : monitor
        save_count = 0; load_count = 0; ld_mem_count = 0; errors = 0;
        forever begin
            @(posedge clk); #1;
            if (flash_write && !flash_mem_waitrequest) begin
                if (save_count < TOTAL_PARAMS) write_addresses[save_count] = flash_addr;
                save_count++;
            end
            if (flash_read && !flash_mem_waitrequest) begin
                if (load_count < TOTAL_PARAMS) read_addresses[load_count] = flash_addr;
                load_count++;
            end
            if (ld_from_mem) begin
                if (ld_mem_count < TOTAL_PARAMS) begin
                    store_fx[ld_mem_count] = curr_fx;
                    store_p [ld_mem_count] = curr_p;
                end
                ld_mem_count++;
            end
        end
    end

    // ----------------------------------------------------------------
    // CSR responder
    // ----------------------------------------------------------------
    task automatic csr_accept_and_erase_done();
        // Wait until csr_write seen, accepting after 2 cycles backpressure
        @(posedge clk); #1;
        while (!flash_csr_write) begin @(posedge clk); #1; end

        repeat(2) @(posedge clk);
        flash_csr_waitrequest = 1'b0;   // accept
        @(posedge clk);
        flash_csr_waitrequest = 1'b1;

        // Simulate erase complete — pulse readdatavalid after short delay
        repeat(3) @(posedge clk);
        flash_readdatavalid = 1'b1;
        @(posedge clk);
        flash_readdatavalid = 1'b0;
    endtask

    // ----------------------------------------------------------------
    // MEM responder  
    // Called once per expected MEM transaction.
    // Returns when the transaction has been accepted and (for reads)
    // readdatavalid has been pulsed.
    // ----------------------------------------------------------------
    task automatic mem_accept(input logic is_read);
        // Wait until read or write is asserted
        @(posedge clk); #1;
        while (!(flash_read || flash_write)) begin @(posedge clk); #1; end

        // 3-cycle backpressure then accept
        repeat(3) @(posedge clk);
        flash_mem_waitrequest = 1'b0;
        @(posedge clk);
        flash_mem_waitrequest = 1'b1;

        if (is_read) begin
            // Return data after 4 more cycles
            repeat(4) @(posedge clk);
            flash_readdatavalid = 1'b1;
            @(posedge clk);
            flash_readdatavalid = 1'b0;
        end
    endtask

    // ----------------------------------------------------------------
    // Stimulus + checks
    // All flash responses are driven inline from the stimulus block so
    // there are zero concurrent process races — one sequential flow.
    // ----------------------------------------------------------------
    initial begin : stimulus
        // KEY: initialise ALL inputs to known safe values BEFORE reset
        // This prevents X propagation causing false transitions in the FSM
        rst_n                 = 1'b0;
        save_en               = 1'b0;
        load_en               = 1'b0;
        flash_mem_waitrequest = 1'b1;   // flash busy by default
        flash_csr_waitrequest = 1'b1;   // CSR busy by default
        flash_readdatavalid   = 1'b0;

        $display("=== controller_fsm testbench ===");

        for (int n = 0; n < TOTAL_PARAMS; n++)
            flash_mem_model[n] = n[7:0];

        // Hold reset for 5 cycles then release
        repeat(5) @(posedge clk);
        rst_n = 1'b1;
        repeat(5) @(posedge clk);

        // Verify FSM starts in IDLE
        if (fsm_state_debug !== 4'd0)
            $error("SETUP FAIL: FSM not in IDLE after reset, state=%0d", fsm_state_debug);
        else
            $display("SETUP: FSM in IDLE after reset");

        // ==============================================================
        // TEST 1 — SAVE
        // Drive flash responses inline — no background processes competing
        // ==============================================================
        $display("\n--- TEST 1: Save sequence ---");
        save_count = 0;

        // Fire save_en for exactly 1 cycle
        @(posedge clk); save_en = 1'b1;
        @(posedge clk); save_en = 1'b0;

        // Confirm we entered ERASE_START
        #1;
        if (fsm_state_debug !== 4'd1)
            $error("TEST 1: Expected ERASE_START(1), got state %0d", fsm_state_debug);
        else
            $display("TEST 1: Entered ERASE_START correctly");

        // Handle the erase: accept CSR write, then signal erase done
        csr_accept_and_erase_done();

        // Now handle 128 word writes
        for (int n = 0; n < TOTAL_PARAMS; n++) begin
            mem_accept(1'b0); // write — no readdatavalid needed
            // SAVE_SETTLE: wait for settle counter (500 cycles)
            repeat(502) @(posedge clk);
        end

        // Wait for FSM to reach IDLE
        t = 0;
        while (fsm_busy && t < 1000) begin @(posedge clk); t++; end
        if (fsm_busy) begin
            $error("TEST 1: FSM stuck in state %0d after writes", fsm_state_debug);
            errors++; -> tb_done;
        end
        repeat(2) @(posedge clk);

        if (save_count !== TOTAL_PARAMS) begin
            $error("TEST 1 FAIL: expected %0d writes, got %0d", TOTAL_PARAMS, save_count);
            errors++;
        end else
            $display("PASS: got %0d writes", save_count);

        begin
            int addr_errors = 0;
            for (int n = 0; n < TOTAL_PARAMS; n++) begin
                logic [23:0] exp;
                exp = FLASH_BASE + n[23:0];
                if (write_addresses[n] !== exp) begin
                    $error("TEST 1 FAIL: write[%0d]=0x%06X expected=0x%06X",
                            n, write_addresses[n], exp);
                    addr_errors++; errors++;
                end
            end
            if (addr_errors == 0)
                $display("PASS: all write addresses correct and sequential");
        end

        // ==============================================================
        // TEST 2 — LOAD
        // ==============================================================
        $display("\n--- TEST 2: Load sequence ---");
        load_count = 0; ld_mem_count = 0;

        @(posedge clk); load_en = 1'b1;
        @(posedge clk); load_en = 1'b0;

        #1;
        if (fsm_state_debug !== 4'd6)
            $error("TEST 2: Expected LOAD_READ(6), got state %0d", fsm_state_debug);
        else
            $display("TEST 2: Entered LOAD_READ correctly");

        // Handle 128 reads — each needs a mem accept + readdatavalid
        for (int n = 0; n < TOTAL_PARAMS; n++) begin
            mem_accept(1'b1); // read — will pulse readdatavalid internally
        end

        // Wait for IDLE
        t = 0;
        while (fsm_busy && t < 1000) begin @(posedge clk); t++; end
        if (fsm_busy) begin
            $error("TEST 2: FSM stuck in state %0d after reads", fsm_state_debug);
            errors++; -> tb_done;
        end
        repeat(2) @(posedge clk);

        if (load_count !== TOTAL_PARAMS) begin
            $error("TEST 2 FAIL: expected %0d reads, got %0d", TOTAL_PARAMS, load_count);
            errors++;
        end else
            $display("PASS: got %0d reads", load_count);

        if (ld_mem_count !== TOTAL_PARAMS) begin
            $error("TEST 2 FAIL: expected %0d ld_from_mem pulses, got %0d",
                    TOTAL_PARAMS, ld_mem_count);
            errors++;
        end else
            $display("PASS: got %0d ld_from_mem pulses", ld_mem_count);

        // KEY CHECK: ld_from_mem must fire at correct (fx, p) — before inc_idx
        begin
            int idx_errors = 0;
            for (int n = 0; n < TOTAL_PARAMS && n < ld_mem_count; n++) begin
                int exp_fx, exp_p;
                exp_fx = n / PARAM_COUNT;
                exp_p  = n % PARAM_COUNT;
                if (int'(store_fx[n]) !== exp_fx || int'(store_p[n]) !== exp_p) begin
                    $error("TEST 2 FAIL: ld_from_mem[%0d] fired at fx=%0d p=%0d, expected fx=%0d p=%0d",
                            n, store_fx[n], store_p[n], exp_fx, exp_p);
                    idx_errors++; errors++;
                end
            end
            if (idx_errors == 0 && ld_mem_count == TOTAL_PARAMS)
                $display("PASS: all ld_from_mem fired at correct (fx,p)");
        end

        // ==============================================================
        // TEST 3 — fsm_busy held throughout load, no early drop
        // ==============================================================
        $display("\n--- TEST 3: fsm_busy held during load ---");
        load_count = 0; ld_mem_count = 0;

        @(posedge clk); load_en = 1'b1;
        @(posedge clk); load_en = 1'b0;

        for (int n = 0; n < TOTAL_PARAMS; n++)
            mem_accept(1'b1);

        t = 0;
        while (fsm_busy && t < 1000) begin @(posedge clk); t++; end

        if (load_count !== TOTAL_PARAMS)
            $error("TEST 3 FAIL: load_count=%0d, fsm_busy may have dropped early", load_count);
        else
            $display("PASS: fsm_busy held for full load (%0d reads)", load_count);

        // ==============================================================
        // Summary
        // ==============================================================
        $display("\n=== %0d error(s) ===", errors);
        if (errors == 0) $display("ALL TESTS PASSED");
        -> tb_done;
    end

    // ----------------------------------------------------------------
    // Termination + watchdog
    // ----------------------------------------------------------------
    initial begin
        $dumpfile("tb_controller_fsm.vcd");
        $dumpvars(0, tb_controller_fsm);
        @(tb_done); $stop;
    end

    initial begin
        #200_000_000;
        $error("WATCHDOG: timed out — FSM stuck in state %0d", fsm_state_debug);
        $stop;
    end

endmodule