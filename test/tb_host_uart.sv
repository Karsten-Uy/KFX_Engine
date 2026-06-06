/*
 * tb_host_uart.sv
 *
 * Functional testbench for the PC host interface (host_if + controller).
 * Drives host_if's generic byte stream directly (the JTAG-UART transport is
 * not modeled) and checks the controller's all_params store and the response
 * byte stream.  Self-checking; prints PASS/FAIL summary.
 */
`timescale 1ns/1ps

module tb_host_uart;
    import lab_pkg::*;

    localparam int CLK_PERIOD = 20;          // 50 MHz

    logic clk = 1'b0;
    logic reset_n;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- host_if <-> controller host bus ----
    logic                           host_wr_en, host_rst_en, host_save_pulse, host_load_pulse;
    logic [$clog2(BANK_COUNT)-1:0]  host_bank;
    logic [$clog2(FX_COUNT)-1:0]    host_fx;
    logic [$clog2(PARAM_COUNT)-1:0] host_param;
    logic [PARAM_W-1:0]             host_data, host_rd_value, host_default_value;
    logic [1:0]                     host_rst_scope;

    // ---- byte stream to/from host_if ----
    logic [7:0] rx_data, tx_data;
    logic       rx_valid, rx_ready, tx_valid, tx_ready;

    // ---- controller misc outputs (unused detail) ----
    logic [PARAM_W-1:0]             params [0:FX_COUNT-1][0:PARAM_COUNT-1];
    logic [$clog2(FX_COUNT)-1:0]    fx_sel;
    logic [$clog2(PARAM_COUNT)-1:0] param_sel;
    logic [PARAM_W-1:0]             current_value;
    logic                           is_mute, delay_pulse, tap_active, beat_pulse;
    logic [$clog2(BANK_COUNT)-1:0]  bank_sel;
    logic [$clog2(MAX_SAMPLES)-1:0] tap_delay_samples;
    logic [9:0]                     LEDR;
    logic                           fsm_busy, bank_switching;
    logic [21:0]                    flash_mem_address;
    logic                           flash_mem_read, flash_mem_write;
    logic [31:0]                    flash_mem_writedata;
    logic [3:0]                     flash_mem_byteenable;
    logic [5:0]                     flash_csr_address;
    logic                           flash_csr_write, flash_csr_read;
    logic [31:0]                    flash_csr_writedata;

    int fails = 0;

    controller DUT_CTRL (
        .clk(clk), .reset_n(reset_n),
        .sw_fx_sel('0), .sw_param_sel('0),
        .key_inc(1'b0), .key_dec(1'b0),
        .save_button(1'b0), .load_button(1'b0), .mute_button(1'b0),
        .bank_btn(4'hF), .bank_toggle(1'b0),
        .pot_value(12'd0), .pot_valid(1'b0),
        .params(params), .fx_sel(fx_sel), .param_sel(param_sel),
        .current_value(current_value), .is_mute(is_mute), .delay_pulse(delay_pulse),
        .bank_sel(bank_sel), .tap_delay_samples(tap_delay_samples),
        .tap_active(tap_active), .beat_pulse(beat_pulse),
        .LEDR(LEDR), .fsm_busy(fsm_busy), .bank_switching(bank_switching),
        .flash_mem_address(flash_mem_address), .flash_mem_read(flash_mem_read),
        .flash_mem_write(flash_mem_write), .flash_mem_writedata(flash_mem_writedata),
        .flash_mem_readdata(32'd0), .flash_mem_waitrequest(1'b0),
        .flash_mem_readdatavalid(1'b0), .flash_mem_byteenable(flash_mem_byteenable),
        .flash_csr_address(flash_csr_address), .flash_csr_write(flash_csr_write),
        .flash_csr_read(flash_csr_read), .flash_csr_writedata(flash_csr_writedata),
        .flash_csr_readdata(32'd0), .flash_csr_waitrequest(1'b0),
        .flash_csr_readdatavalid(1'b0),
        .host_wr_en(host_wr_en), .host_bank(host_bank), .host_fx(host_fx),
        .host_param(host_param), .host_data(host_data),
        .host_rst_en(host_rst_en), .host_rst_scope(host_rst_scope),
        .host_save_pulse(host_save_pulse), .host_load_pulse(host_load_pulse),
        .host_rd_value(host_rd_value), .host_default_value(host_default_value)
    );

    host_if DUT_HOST (
        .clk(clk), .reset_n(reset_n),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .host_wr_en(host_wr_en), .host_bank(host_bank), .host_fx(host_fx),
        .host_param(host_param), .host_data(host_data),
        .host_rst_en(host_rst_en), .host_rst_scope(host_rst_scope),
        .host_save_pulse(host_save_pulse), .host_load_pulse(host_load_pulse),
        .host_rd_value(host_rd_value), .host_default_value(host_default_value),
        .fsm_busy(fsm_busy)
    );

    // ---- stimulus / checking tasks ----
    task automatic send_byte(input logic [7:0] b);
        @(posedge clk);
        while (!rx_ready) @(posedge clk);
        rx_data = b; rx_valid = 1'b1;
        @(posedge clk);
        rx_valid = 1'b0;
    endtask

    task automatic send_frame(input logic [7:0] op, a0, a1, a2, a3);
        send_byte(8'h5A);
        send_byte(op);
        send_byte(a0); send_byte(a1); send_byte(a2); send_byte(a3);
        send_byte(op ^ a0 ^ a1 ^ a2 ^ a3);
    endtask

    task automatic get_byte(output logic [7:0] b);
        @(posedge clk);
        tx_ready = 1'b0;
        while (!tx_valid) @(posedge clk);
        b = tx_data;
        tx_ready = 1'b1;
        @(posedge clk);
        tx_ready = 1'b0;
    endtask

    task automatic check8(input string nm, input logic [7:0] got, exp);
        if (got !== exp) begin
            $display("  FAIL %-16s got 0x%02x exp 0x%02x", nm, got, exp);
            fails++;
        end
    endtask

    // ---- test sequence ----
    initial begin
        logic [7:0] r [0:16];
        logic [7:0] acc, val, before_val;
        int bk, fi, p, i;

        rx_valid = 1'b0; rx_data = 8'h00; tx_ready = 1'b0;
        reset_n = 1'b0; repeat (8) @(posedge clk);
        reset_n = 1'b1; repeat (8) @(posedge clk);

        // 1) PING -> PONG
        $display("[1] PING");
        send_frame(8'hF0, 0, 0, 0, 0);
        for (i = 0; i < 5; i++) get_byte(r[i]);
        check8("ping.sync", r[0], 8'hA5);
        check8("ping.op",   r[1], 8'hF0);
        check8("ping.vmaj", r[2], 8'h01);
        check8("ping.vmin", r[3], 8'h00);
        check8("ping.chk",  r[4], 8'hF0 ^ 8'h01 ^ 8'h00);

        // 2) WRITE bank2 fx4 param0 = 0x77
        $display("[2] WRITE");
        send_frame(8'h01, 8'd2, 8'd4, 8'd0, 8'h77);
        get_byte(r[0]); get_byte(r[1]);
        check8("wr.sync", r[0], 8'hA5);
        check8("wr.ack",  r[1], 8'h00);
        @(posedge clk);
        check8("wr.stored", DUT_CTRL.all_params[2][4][0], 8'h77);

        // 3) WRITE fx15 (global) -> mirrored across all banks
        $display("[3] WRITE FX15 mirror");
        send_frame(8'h01, 8'd0, 8'd15, 8'd0, 8'h2A);
        get_byte(r[0]); get_byte(r[1]);
        check8("wr15.ack", r[1], 8'h00);
        @(posedge clk);
        check8("fx15.b0", DUT_CTRL.all_params[0][15][0], 8'h2A);
        check8("fx15.b1", DUT_CTRL.all_params[1][15][0], 8'h2A);
        check8("fx15.b2", DUT_CTRL.all_params[2][15][0], 8'h2A);
        check8("fx15.b3", DUT_CTRL.all_params[3][15][0], 8'h2A);

        // 4) WRITE FX7[0] (expression) -> NACK 0x04, value unchanged
        $display("[4] WRITE FX7[0] read-only");
        before_val = DUT_CTRL.all_params[0][7][0];
        send_frame(8'h01, 8'd0, 8'd7, 8'd0, 8'h99);
        get_byte(r[0]); get_byte(r[1]);
        check8("ro.nack", r[1], 8'h04);
        @(posedge clk);
        check8("ro.unchanged", DUT_CTRL.all_params[0][7][0], before_val);

        // 5) READ bank2 fx4 param0 -> 0x77
        $display("[5] READ");
        send_frame(8'h10, 8'd2, 8'd4, 8'd0, 8'd0);
        for (i = 0; i < 7; i++) get_byte(r[i]);
        check8("rd.sync",  r[0], 8'hA5);
        check8("rd.op",    r[1], 8'h10);
        check8("rd.bank",  r[2], 8'd2);
        check8("rd.fx",    r[3], 8'd4);
        check8("rd.param", r[4], 8'd0);
        check8("rd.val",   r[5], 8'h77);
        check8("rd.chk",   r[6], 8'h10 ^ 8'd2 ^ 8'd4 ^ 8'd0 ^ 8'h77);

        // 6) RDEF bank2 fx4 param0 -> factory default (no write)
        $display("[6] READ-DEFAULT");
        send_frame(8'h40, 8'd2, 8'd4, 8'd0, 8'd0);
        for (i = 0; i < 7; i++) get_byte(r[i]);
        check8("rdef.val", r[5], param_default(2, 4, 0));
        @(posedge clk);
        check8("rdef.nowrite", DUT_CTRL.all_params[2][4][0], 8'h77);  // still 0x77

        // 7) RESET bank scope on bank2 -> all of bank2 = defaults
        $display("[7] RESET (bank scope)");
        send_frame(8'h30, 8'd2 /*scope=bank*/, 8'd2 /*bank*/, 8'd0, 8'd0);
        get_byte(r[0]); get_byte(r[1]);
        check8("rst.ack", r[1], 8'h00);
        repeat (3) @(posedge clk);
        check8("rst.b2f4p0", DUT_CTRL.all_params[2][4][0], param_default(2, 4, 0));
        check8("rst.b2f9p7", DUT_CTRL.all_params[2][9][7], param_default(2, 9, 7));

        // 8) DUMP -> 4-byte header + 512 values + checksum
        $display("[8] DUMP");
        send_frame(8'h20, 0, 0, 0, 0);
        get_byte(r[0]); get_byte(r[1]); get_byte(r[2]); get_byte(r[3]);
        check8("dump.sync",  r[0], 8'hA5);
        check8("dump.op",    r[1], 8'h20);
        check8("dump.lenhi", r[2], 8'h02);
        check8("dump.lenlo", r[3], 8'h00);
        acc = 8'h00;
        for (bk = 0; bk < BANK_COUNT; bk++)
            for (fi = 0; fi < FX_COUNT; fi++)
                for (p = 0; p < PARAM_COUNT; p++) begin
                    get_byte(val);
                    acc = acc ^ val;
                    if (val !== DUT_CTRL.all_params[bk][fi][p]) begin
                        $display("  FAIL dump[%0d][%0d][%0d] got 0x%02x exp 0x%02x",
                                 bk, fi, p, val, DUT_CTRL.all_params[bk][fi][p]);
                        fails++;
                    end
                end
        get_byte(val);
        check8("dump.chk", val, acc);

        // 9) Bad checksum -> NACK 0x01
        $display("[9] bad checksum");
        send_byte(8'h5A); send_byte(8'h01);
        send_byte(8'd0); send_byte(8'd0); send_byte(8'd0); send_byte(8'd0);
        send_byte(8'hFF);   // deliberately wrong checksum
        get_byte(r[0]); get_byte(r[1]);
        check8("badchk.nack", r[1], 8'h01);

        if (fails == 0) $display("\n=== ALL HOST-IF TESTS PASSED ===");
        else            $display("\n=== %0d FAILURE(S) ===", fails);
        $stop;
    end

    // watchdog
    initial begin
        repeat (400000) @(posedge clk);
        $display("TIMEOUT");
        $stop;
    end

endmodule
