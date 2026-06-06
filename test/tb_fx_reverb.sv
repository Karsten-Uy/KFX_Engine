`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// tb_fx_reverb.sv  —  sanity testbench for the FDN reverb.
//
// This is NOT an exhaustive bench (the system-level UVM bench comes later).
// It checks the things that are easy to get wrong in a feedback structure and
// that you can't hear until it's too late on hardware:
//   1. No X/unknown propagation on the output after reset.
//   2. Stability: an impulse-excited tail DECAYS (energy late < energy early)
//      across decay settings AND with modulation enabled (the metallic fix).
//   3. flush drives the output to zero.
//   4. fx_mix = 0 is an exact dry passthrough.
//
// Audio quality (the "not metallic" goal) is judged by ear on hardware.
// ---------------------------------------------------------------------------

module tb_fx_reverb;

    localparam DATA_W     = 16;
    localparam PARAM_W    = 8;
    localparam CLK_PERIOD = 20;   // 50 MHz

    logic                          clk;
    logic                          reset_n;
    logic signed [1:0][DATA_W-1:0] audio_in;
    logic signed [1:0][DATA_W-1:0] audio_out;
    logic                          flush;
    logic [PARAM_W-1:0]            fx_size, fx_damping, fx_decay, fx_moddepth;
    logic [PARAM_W-1:0]            fx_diffusion, fx_predelay, fx_width, fx_mix;
    logic                          sample_en;

    int   fail_count = 0;
    logic signed [15:0] last_l, last_r;

    fx_reverb #(.DATA_W(DATA_W), .PARAM_W(PARAM_W)) dut (
        .clk(clk), .reset_n(reset_n),
        .audio_in(audio_in), .audio_out(audio_out), .flush(flush),
        .fx_size(fx_size), .fx_damping(fx_damping), .fx_decay(fx_decay),
        .fx_moddepth(fx_moddepth), .fx_diffusion(fx_diffusion),
        .fx_predelay(fx_predelay), .fx_width(fx_width), .fx_mix(fx_mix),
        .sample_en(sample_en)
    );

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // One audio sample: single-cycle sample_en pulse, then capture the output.
    task automatic tick(input logic signed [15:0] l, input logic signed [15:0] r);
        begin
            audio_in[0] = l;
            audio_in[1] = r;
            sample_en   = 1;
            @(posedge clk);
            sample_en   = 0;
            @(posedge clk);
            last_l = audio_out[0];
            last_r = audio_out[1];
            // Output must never be unknown once we're out of reset.
            if (reset_n && $isunknown(audio_out)) begin
                $display("  X FAIL: unknown value on audio_out (0x%h 0x%h)",
                         audio_out[0], audio_out[1]);
                fail_count++;
            end
        end
    endtask

    task automatic do_reset();
        int i;
        begin
            reset_n = 0;  flush = 0;  sample_en = 0;
            audio_in = '{default:'0};
            fx_size = 8'd128; fx_damping = 8'd64; fx_decay = 8'd0;
            fx_moddepth = 8'd0; fx_diffusion = 8'd128; fx_predelay = 8'd0;
            fx_width = 8'd200; fx_mix = 8'd255;
            // Hold reset long enough for the delay-line clear walk to complete
            // (> MAX delay-line length, a few thousand clocks).
            repeat (5000) @(posedge clk);
            reset_n = 1;
            @(posedge clk);
            // Flush-warmup: the RAM-read registers (ram_out*) are unreset and
            // read X until their first read; under flush every line input is
            // gated to 0, so these pulses resolve every read register to 0
            // WITHOUT writing any X back into the (already-cleared) buffers.
            // Hardware has no X here — this only quiets 4-state simulation.
            flush = 1;
            for (i = 0; i < 100; i++) begin
                audio_in = '{default:'0};
                sample_en = 1; @(posedge clk);
                sample_en = 0; @(posedge clk);
            end
            flush = 0;
        end
    endtask

    // Sum of the 8 FDN line energies — the true internal state of the network.
    // Measured directly (not through the output DC blocker, whose 5.5 Hz pole
    // rings for ~170 ms and would mask the FDN's own decay).
    function automatic longint fdn_energy();
        longint e;
        int j;
        begin
            e = 0;
            for (j = 0; j < 8; j++)
                e += longint'($signed(dut.s[j])) * longint'($signed(dut.s[j]));
            fdn_energy = e;
        end
    endfunction

    // Excite with an impulse, run a long zero-input tail, compare FDN-state
    // energy in an early-tail window vs a late window (both well past build-up).
    // Asserts the network DECAYS (stable), using short delays so many round
    // trips fit in the run.
    task automatic impulse_decay_test(input logic [7:0] decay,
                                      input logic [7:0] moddepth,
                                      input string label);
        longint e_early, e_late;
        int     i;
        begin
            // Short delays (fast build-up, many rounds fit) and no damping
            // (LP = exact unity) — the worst case for stability: longest tail,
            // least loss. If it decays here, it decays everywhere.
            fx_size     = 8'd0;
            fx_damping  = 8'd0;
            fx_decay    = decay;
            fx_moddepth = moddepth;
            fx_mix      = 8'd255;
            e_early = 0;  e_late = 0;

            // flush any prior tail
            flush = 1;
            repeat (400) tick(16'sd0, 16'sd0);
            flush = 0;

            // impulse
            tick(16'sd32767, 16'sd32767);

            // zero-input tail; accumulate FDN energy in two post-build windows
            for (i = 0; i < 30000; i++) begin
                tick(16'sd0, 16'sd0);
                if (i >= 4000  && i < 6000)   e_early += fdn_energy();
                if (i >= 26000 && i < 28000)  e_late  += fdn_energy();
            end

            $display("%s: E_early=%0d  E_late=%0d", label, e_early, e_late);
            if (e_early == 0) begin
                $display("  X FAIL: no reverb tail produced (E_early==0)");
                fail_count++;
            end else if (e_late >= e_early) begin
                $display("  X FAIL: FDN is NOT decaying (unstable)");
                fail_count++;
            end else begin
                $display("  PASS: FDN decays (late = %.2f%% of early energy)",
                         100.0 * real'(e_late) / real'(e_early));
            end
        end
    endtask

    task automatic flush_test();
        int i;
        begin
            fx_mix = 8'd255; fx_decay = 8'd3; fx_moddepth = 8'd128;
            // build a tail
            tick(16'sd20000, 16'sd20000);
            repeat (300) tick(16'sd0, 16'sd0);
            // assert flush; output must reach exactly zero
            flush = 1;
            for (i = 0; i < 50; i++) tick(16'sd0, 16'sd0);
            if (last_l != 0 || last_r != 0) begin
                $display("  X FAIL: output not zero under flush (0x%h 0x%h)",
                         last_l, last_r);
                fail_count++;
            end else begin
                $display("  PASS: flush zeros the output");
            end
            flush = 0;
        end
    endtask

    task automatic mix_zero_test();
        begin
            fx_mix = 8'd0;
            tick(16'sd1234, -16'sd5678);
            if (last_l == 16'sd1234 && last_r == -16'sd5678) begin
                $display("  PASS: fx_mix=0 is exact dry passthrough");
            end else begin
                $display("  X FAIL: mix=0 not dry passthrough (got 0x%h 0x%h)",
                         last_l, last_r);
                fail_count++;
            end
        end
    endtask

    initial begin
        $display("\n========================================");
        $display(" FDN Reverb — sanity testbench");
        $display("========================================\n");

        do_reset();

        $display("[TEST 1] fx_mix = 0 dry passthrough");
        mix_zero_test();
        $display("");

        $display("[TEST 2] impulse decay across decay settings");
        impulse_decay_test(8'd0,   8'd0,   "  decay=short  mod=0  ");
        impulse_decay_test(8'd128, 8'd0,   "  decay=medium mod=0  ");
        impulse_decay_test(8'd255, 8'd0,   "  decay=huge   mod=0  ");
        $display("");

        $display("[TEST 3] impulse decay WITH modulation (anti-metallic)");
        impulse_decay_test(8'd128, 8'd255, "  decay=medium mod=255");
        impulse_decay_test(8'd255, 8'd255, "  decay=huge   mod=255");
        $display("");

        $display("[TEST 4] flush clears the tail");
        flush_test();
        $display("");

        $display("========================================");
        if (fail_count == 0)
            $display(" ALL CHECKS PASSED");
        else
            $display(" %0d CHECK(S) FAILED", fail_count);
        $display("========================================\n");

        #100;
        $stop;
    end

    // Global watchdog
    initial begin
        #50ms;
        $display("X TIMEOUT — testbench did not finish");
        $stop;
    end

endmodule
