/*
 * controller.sv
 *
 * FX parameter controller for the AudioFX pedalboard.
 *
 * Owns the params[][] array and handles all user interactions that modify it:
 * button-driven increment/decrement with auto-repeat, save to flash, load from
 * flash, and mute/tap-tempo via the footswitch.  The current FX and parameter
 * selection comes directly from the slide switches (sw_fx_sel, sw_param_sel);
 * no state is held for selection here.
 *
 * Submodule relationships
 * -----------------------
 *   debounce_unit  — cleans every raw button input before use
 *   repeat_unit    — generates auto-repeat pulses for inc / dec
 *   tap_mute_unit  — classifies footswitch as tap tempo or mute
 *   tap_tempo_unit — (instantiated in AudioFX) receives delay_pulse
 *   controller_fsm — runs the flash save / load state machine
 *
 * Save / load (flash)
 * -------------------
 *   Pressing save_button erases one 64 KB sector and writes every parameter
 *   byte followed by a 0xA5 sentinel.  Pressing load_button reads the sentinel
 *   first; if valid it overwrites params[][] from flash.  fsm_busy is asserted
 *   for the full duration so AudioFX can mute the DAC during the operation.
 *
 * Bank switching — two-phase design
 * -----------------------------------
 *   The bank switch is deliberately split into two timed phases to eliminate
 *   the IIR filter buzz that occurs when FX parameters change while audio is
 *   still audible:
 *
 *   Phase 1  (0 → BANK_FADE_CYCLES):
 *     bank_switching = 1, bank_sel = OLD bank.
 *     The soft-mute ramp in AudioFX.sv fades the DAC output to zero.
 *     The FX chain keeps running with old params so IIR states are
 *     consistent — no coefficient/state mismatch, no ring.
 *
 *   Phase 2  (BANK_FADE_CYCLES → BANK_MUTE_CYCLES):
 *     bank_switching = 1, bank_sel = NEW bank (params[] switches here).
 *     Audio is silent (ramp_vol = 0) so any IIR transient from the
 *     parameter change is completely inaudible.  The hold window
 *     (~14 ms) lets filter states decay toward the new operating point
 *     before the fade-in begins.
 *
 *   Phase 3  (BANK_MUTE_CYCLES):
 *     bank_switching releases.  The AudioFX ramp FSM transitions from
 *     ST_MUTED to ST_FADE_IN and smoothly restores volume.
 *
 *   Counter sizing (at 50 MHz):
 *     BANK_FADE_CYCLES = 300_000  ≈ 6 ms  (covers 256-sample ramp + margin)
 *     BANK_MUTE_CYCLES = 1_000_000 ≈ 20 ms (fade + 14 ms IIR hold)
 *     Both require a 20-bit counter.
 *
 * params[] output — MUST be registered
 * --------------------------------------
 *   The 2-D params[] output (active bank slice) is driven by always_ff,
 *   NOT always_comb.  This is critical:
 *
 *   - Combinational: timing path = all_params regs → 128-wide 4:1 mux tree
 *                    → setup inputs of FX block regs inside fx_eq etc.
 *                    Quartus may not meet this path, causing metastability
 *                    on some audio samples → continuous buzzing.
 *
 *   - Registered:   timing path = all_params regs → register → FX block regs.
 *                   Register-to-register, clean hold/setup margin.
 *
 *   The one-cycle latency between all_params update and params[] update is
 *   20 ns — completely imperceptible in audio.
 *
 * Ports
 * -----
 *   sw_fx_sel     — slide-switch FX index (combinational select, not registered)
 *   sw_param_sel  — slide-switch parameter index
 *   key_inc       — increment button (active-high, raw)
 *   key_dec       — decrement button (active-high, raw)
 *   save_button   — save-to-flash button (active-high, raw)
 *   load_button   — load-from-flash button (active-high, raw)
 *   mute_button   — footswitch: short = tap tempo, long = mute (active-high, raw)
 *   bank_toggle   — toggle to rotate through the FX banks
 *   params        — full parameter array exposed to the FX chain
 *   fx_sel        — registered copy of sw_fx_sel for display / value readback
 *   param_sel     — registered copy of sw_param_sel
 *   current_value — params[fx_sel][param_sel], for the display module
 *   is_mute       — high while audio is muted
 *   delay_pulse   — single-cycle tap-tempo pulse to tap_tempo_unit
 *   bank_sel      — currently active bank driving the FX chain (lags button by Phase 1)
 *   bank_switching — high for the full two-phase window; gates the DAC soft-mute
 *   LEDR          — diagnostic LED output
 *   fsm_busy      — high while save or load is in progress
 */

module controller (
    input  logic clk, reset_n,
    input  logic [$clog2(FX_COUNT)-1:0]    sw_fx_sel,
    input  logic [$clog2(PARAM_COUNT)-1:0] sw_param_sel,
    input  logic key_inc, key_dec, save_button, load_button,
    input  logic mute_button,
    input  logic [3:0] bank_btn,
    input  logic bank_toggle,
    input  logic [11:0] pot_value,
    input  logic        pot_valid,

    output logic [PARAM_W-1:0]             params [0:FX_COUNT-1][0:PARAM_COUNT-1],
    output logic [$clog2(FX_COUNT)-1:0]    fx_sel,
    output logic [$clog2(PARAM_COUNT)-1:0] param_sel,
    output logic [PARAM_W-1:0]             current_value,
    output logic                           is_mute,
    output logic                           delay_pulse,
    output logic [$clog2(BANK_COUNT)-1:0]  bank_sel,

    output logic [$clog2(MAX_SAMPLES)-1:0] tap_delay_samples,
    output logic tap_active,
    output logic beat_pulse,

    output logic [9:0] LEDR,
    output logic       fsm_busy,
    output logic       bank_switching,

    output logic [21:0] flash_mem_address,
    output logic        flash_mem_read,
    output logic        flash_mem_write,
    output logic [31:0] flash_mem_writedata,
    input  logic [31:0] flash_mem_readdata,
    input  logic        flash_mem_waitrequest,
    input  logic        flash_mem_readdatavalid,
    output logic [3:0]  flash_mem_byteenable,

    output logic [5:0]  flash_csr_address,
    output logic        flash_csr_write,
    output logic        flash_csr_read,
    output logic [31:0] flash_csr_writedata,
    input  logic [31:0] flash_csr_readdata,
    input  logic        flash_csr_waitrequest,
    input  logic        flash_csr_readdatavalid,

    // ---- Host (PC) parameter interface (UART/JTAG, transport-agnostic) ----
    input  logic                           host_wr_en,
    input  logic [$clog2(BANK_COUNT)-1:0]  host_bank,
    input  logic [$clog2(FX_COUNT)-1:0]    host_fx,
    input  logic [$clog2(PARAM_COUNT)-1:0] host_param,
    input  logic [PARAM_W-1:0]             host_data,
    input  logic                           host_rst_en,
    input  logic [1:0]                     host_rst_scope,   // 0=param 1=fx 2=bank 3=all
    input  logic                           host_save_pulse,
    input  logic                           host_load_pulse,
    output logic [PARAM_W-1:0]             host_rd_value,    // all_params[host_bank][host_fx][host_param]
    output logic [PARAM_W-1:0]             host_default_value // param_default(host_bank,host_fx,host_param)
);

    import lab_pkg::*;

    localparam logic [7:0] SENTINEL = 8'hA5;

    // ----------------------------------------------------------------
    // Bank-Switching Timing
    //
    //   BANK_FADE_CYCLES — end of Phase 1 / start of Phase 2.
    //     Must be > (256 ramp steps × 50 MHz / 48 kHz) ≈ 266 752 cycles
    //     so that ramp_vol has reached 0 (and fade_state == ST_MUTED) by
    //     the time bank_sel flips.  300 000 gives ~12 % headroom = ~6 ms.
    //
    //   BANK_MUTE_CYCLES — end of Phase 2 / release of bank_switching.
    //     Hold ST_MUTED long enough that:
    //       (a) delay/reverb BRAM regions a write_ptr touches under reset
    //           are filled with the silenced chain input, and
    //       (b) any IIR state in the rest of the chain (now also reset)
    //           settles before fade-in.
    //     ~120 ms hold is overkill for biquads but covers the longest
    //     comb-delay loops in the reverb.
    //
    // Counter is 27 bits (2^27 = 134M > 6_300_000).
    // ----------------------------------------------------------------

    localparam int BANK_FADE_CYCLES = 1_000_000;  // ~20 ms — comfortably past the 5.3 ms ramp
    localparam int BANK_MUTE_CYCLES = 6_300_000;  // ~126 ms total — full mute window

    // ----------------------------------------------------------------
    // Internal Signals
    // ----------------------------------------------------------------

    logic inc_p, dec_p, sav_p, ld_p;
    logic inc_s, dec_s, sav_s, ld_s;
    logic mute_stable;
    logic inc_r, dec_r;
    logic bank_stable, bank_pulse;
    logic [3:0] bank_btn_stable;
    logic [3:0] bank_btn_pulse;

    logic ld_mem, inc_idx, rst_idx;
    logic [$clog2(BANK_COUNT)-1:0]  f_bank;
    logic [$clog2(FX_COUNT)-1:0]    f_fx;
    logic [$clog2(PARAM_COUNT)-1:0] f_p;
    logic [3:0]  fsm_state_debug;
    logic [31:0] latched_readdata;
    logic        load_valid;
    logic        write_sentinel;

    // ----------------------------------------------------------------
    // Three-Dimensional Parameter Storage
    // ----------------------------------------------------------------

    logic [PARAM_W-1:0] all_params [0:BANK_COUNT-1][0:FX_COUNT-1][0:PARAM_COUNT-1];

    // ----------------------------------------------------------------
    // params[] Output — REGISTERED
    //
    // Clocked copy of the active bank slice.  Keeps the FX block timing
    // paths as clean register-to-register paths.
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            for (int fi = 0; fi < FX_COUNT; fi++)
                for (int pi = 0; pi < PARAM_COUNT; pi++)
                    params[fi][pi] <= param_default(0, fi, pi);
        end else begin
            for (int fi = 0; fi < FX_COUNT; fi++)
                for (int pi = 0; pi < PARAM_COUNT; pi++)
                    params[fi][pi] <= all_params[bank_sel][fi][pi];
        end
    end

    // ----------------------------------------------------------------
    // Selection Pass-Through
    // ----------------------------------------------------------------

    assign fx_sel        = sw_fx_sel;
    assign param_sel     = sw_param_sel;
    assign current_value = all_params[bank_sel][fx_sel][param_sel];

    // Host readback: current value and factory default at the host's address.
    assign host_rd_value      = all_params[host_bank][host_fx][host_param];
    assign host_default_value = param_default(host_bank, host_fx, host_param);

    // ----------------------------------------------------------------
    // Two-Phase Bank Select
    //
    // pending_bank_sel captures the DESIRED new bank the moment the
    // button fires.  bank_sel (which drives all_params → params[]) is
    // only updated at the Phase 1/2 boundary, when the DAC is already
    // at zero volume.  This guarantees the FX chain never processes a
    // coefficient/state mismatch while the audio is audible.
    //
    // Timeline (bank button fires at t=0):
    //   t = 0                  : pending_bank_sel latched, bank_switching = 1
    //                            bank_sel = OLD  →  FX runs with old params
    //                            AudioFX ramp FSM begins fade-out
    //   t = BANK_FADE_CYCLES   : bank_sel ← pending_bank_sel
    //                            params[] switches  →  IIR transient, but
    //                            ramp_vol = 0 so DAC output is silent
    //   t = BANK_MUTE_CYCLES   : bank_switching = 0
    //                            AudioFX ramp FSM transitions to ST_FADE_IN
    //
    // Guard: a new button press during an in-progress switch is accepted —
    // pending_bank_sel updates immediately (the ongoing fade-out is already
    // running, so the audio won't glitch further) and the counter restarts.
    // ----------------------------------------------------------------

    logic [$clog2(BANK_COUNT)-1:0] pending_bank_sel;
    logic [26:0]                   bank_switch_ctr;   // 20-bit: max 1 048 575

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            bank_sel         <= '0;
            pending_bank_sel <= '0;
            bank_switching   <= 1'b0;
            bank_switch_ctr  <= '0;

        end else begin

            // --- Detect a bank-change request ---
            // Priority: direct GPIO buttons > SW2 toggle.
            // A request is accepted even during an in-progress switch;
            // the counter restarts so the full fade/hold window is observed.
            if (!fsm_busy) begin
                if (bank_btn_pulse[0]) begin
                    pending_bank_sel <= 2'd0;
                    bank_switching   <= 1'b1;
                    bank_switch_ctr  <= '0;
                end else if (bank_btn_pulse[1]) begin
                    pending_bank_sel <= 2'd1;
                    bank_switching   <= 1'b1;
                    bank_switch_ctr  <= '0;
                end else if (bank_btn_pulse[2]) begin
                    pending_bank_sel <= 2'd2;
                    bank_switching   <= 1'b1;
                    bank_switch_ctr  <= '0;
                end else if (bank_btn_pulse[3]) begin
                    pending_bank_sel <= 2'd3;
                    bank_switching   <= 1'b1;
                    bank_switch_ctr  <= '0;
                end else if (bank_pulse) begin
                    pending_bank_sel <= (bank_sel == BANK_COUNT - 1)
                                        ? '0
                                        : bank_sel + 1'b1;
                    bank_switching   <= 1'b1;
                    bank_switch_ctr  <= '0;
                end
            end

            // --- Two-phase counter ---
            if (bank_switching) begin
                if (bank_switch_ctr == 27'(BANK_MUTE_CYCLES)) begin
                    // End of Phase 2: release the mute, let AudioFX fade in
                    bank_switching  <= 1'b0;
                    bank_switch_ctr <= '0;
                end else begin
                    bank_switch_ctr <= bank_switch_ctr + 1'b1;

                    // Phase 1 → Phase 2 boundary: audio is silent, safe to
                    // switch params.  bank_sel update propagates to params[]
                    // on the very next clock via the registered always_ff above.
                    if (bank_switch_ctr == 27'(BANK_FADE_CYCLES))
                        bank_sel <= pending_bank_sel;
                end
            end
        end
    end

    // ----------------------------------------------------------------
    // Flash Write Data
    // ----------------------------------------------------------------

    assign flash_mem_writedata  = write_sentinel
                                    ? {24'b0, SENTINEL}
                                    : {24'b0, all_params[f_bank][f_fx][f_p]};
    assign flash_mem_byteenable = 4'b0001;

    // ----------------------------------------------------------------
    // Diagnostic LEDs
    // ----------------------------------------------------------------

    logic [7:0] save_latch, load_latch;
    logic       save_op_done, load_op_done;
    logic       fsm_busy_prev;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            save_latch    <= 8'hFF;
            load_latch    <= 8'hFF;
            save_op_done  <= 1'b0;
            load_op_done  <= 1'b0;
            fsm_busy_prev <= 1'b0;
        end else begin
            fsm_busy_prev <= fsm_busy;

            if (flash_mem_write && !flash_mem_waitrequest)
                save_latch <= flash_mem_writedata[7:0];
            if (flash_mem_readdatavalid)
                load_latch <= flash_mem_readdata[7:0];

            if (sav_p || ld_p || inc_p || inc_r || dec_p || dec_r) begin
                save_op_done <= 1'b0;
                load_op_done <= 1'b0;
            end

            if (fsm_busy_prev && !fsm_busy) begin
                save_op_done <= !load_valid;
                load_op_done <=  load_valid;
            end
        end
    end

    logic [7:0] ledr_data;
    always_comb begin
        if      (save_op_done)                                ledr_data = save_latch;
        else if (load_op_done)                                ledr_data = load_latch;
        else if (!fsm_busy && !save_op_done && !load_op_done) ledr_data = current_value;
        else                                                  ledr_data = save_latch | load_latch;
    end

    assign LEDR[7:0] = ledr_data;
    assign LEDR[8]   = load_valid;
    assign LEDR[9]   = fsm_busy;

    // ----------------------------------------------------------------
    // Flash Index Counters  (f_bank, f_fx, f_p) — row-major
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n || rst_idx) begin
            f_bank <= '0;
            f_fx   <= '0;
            f_p    <= '0;
        end else if (inc_idx) begin
            if (f_p == PARAM_COUNT - 1) begin
                f_p <= '0;
                if (f_fx == FX_COUNT - 1) begin
                    f_fx   <= '0;
                    f_bank <= f_bank + 1'b1;
                end else begin
                    f_fx <= f_fx + 1'b1;
                end
            end else begin
                f_p <= f_p + 1'b1;
            end
        end
    end

    // ----------------------------------------------------------------
    // Parameter Storage
    //
    // Reset  — each bank gets its own factory preset via param_default(k,i,j).
    // Load   — write one byte per ld_mem pulse from flash.
    // Idle   — inc/dec edits the active bank only.
    // ----------------------------------------------------------------

    int i, j, k;

    logic [PARAM_W-1:0] pot_prev;
    logic [PARAM_W-1:0] pot_scaled;
    logic [8:0]         pot_diff;

    assign pot_scaled = pot_value[11:12-PARAM_W];

    always_comb begin
        if (pot_scaled >= pot_prev)
            pot_diff = 9'(pot_scaled) - 9'(pot_prev);
        else
            pot_diff = 9'(pot_prev)   - 9'(pot_scaled);
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            for (k = 0; k < BANK_COUNT; k++)
                for (i = 0; i < FX_COUNT; i++)
                    for (j = 0; j < PARAM_COUNT; j++)
                        all_params[k][i][j] <= param_default(k, i, j);
            pot_prev <= '0;

        end else begin

            // FX 15 is a "global" slot — its value is mirrored across all
            // banks so it acts like a single chain-wide control regardless
            // of which bank is active.  Edits and load-from-flash both
            // write to every bank's FX 15 row to maintain the invariant.
            // Save works for free: all four banks already store the same
            // value, so the existing save FSM persists it correctly.
            if (ld_mem && load_valid) begin
                if (f_fx == $clog2(FX_COUNT)'(GLOBAL_GAIN_FX)) begin
                    for (int b = 0; b < BANK_COUNT; b++)
                        all_params[b][f_fx][f_p] <= latched_readdata[7:0];
                end else begin
                    all_params[f_bank][f_fx][f_p] <= latched_readdata[7:0];
                end

            // ---- Host reset-to-default (scope-aware); reuses param_default ----
            // Priority: flash-load > host_rst > host_wr > buttons/pot.  Host
            // pulses are gated on !fsm_busy inside host_if, so they never race
            // the flash-load branch.  FX15 stays mirrored across all banks.
            end else if (host_rst_en) begin
                case (host_rst_scope)
                    2'd0: begin  // single parameter
                        if (host_fx == $clog2(FX_COUNT)'(GLOBAL_GAIN_FX))
                            for (int b = 0; b < BANK_COUNT; b++)
                                all_params[b][host_fx][host_param] <= param_default(b, host_fx, host_param);
                        else
                            all_params[host_bank][host_fx][host_param] <= param_default(host_bank, host_fx, host_param);
                    end
                    2'd1: begin  // whole FX row
                        for (int p = 0; p < PARAM_COUNT; p++)
                            if (host_fx == $clog2(FX_COUNT)'(GLOBAL_GAIN_FX))
                                for (int b = 0; b < BANK_COUNT; b++)
                                    all_params[b][host_fx][p] <= param_default(b, host_fx, p);
                            else
                                all_params[host_bank][host_fx][p] <= param_default(host_bank, host_fx, p);
                    end
                    2'd2: begin  // whole bank
                        for (int fi = 0; fi < FX_COUNT; fi++)
                            for (int p = 0; p < PARAM_COUNT; p++)
                                all_params[host_bank][fi][p] <= param_default(host_bank, fi, p);
                    end
                    default: begin  // everything
                        for (int bk = 0; bk < BANK_COUNT; bk++)
                            for (int fi = 0; fi < FX_COUNT; fi++)
                                for (int p = 0; p < PARAM_COUNT; p++)
                                    all_params[bk][fi][p] <= param_default(bk, fi, p);
                    end
                endcase

            // ---- Host write one parameter (FX15 mirrored across banks) ----
            end else if (host_wr_en) begin
                if (host_fx == $clog2(FX_COUNT)'(GLOBAL_GAIN_FX))
                    for (int b = 0; b < BANK_COUNT; b++)
                        all_params[b][host_fx][host_param] <= host_data;
                else
                    all_params[host_bank][host_fx][host_param] <= host_data;

            end else if (!fsm_busy) begin
                if (inc_p || inc_r) begin
                    automatic logic [PARAM_W-1:0] inc_val =
                        (all_params[bank_sel][fx_sel][param_sel] < 8'd255)
                            ? all_params[bank_sel][fx_sel][param_sel] + 1'b1
                            : 8'd255;
                    if (fx_sel == $clog2(FX_COUNT)'(GLOBAL_GAIN_FX)) begin
                        for (int b = 0; b < BANK_COUNT; b++)
                            all_params[b][fx_sel][param_sel] <= inc_val;
                    end else begin
                        all_params[bank_sel][fx_sel][param_sel] <= inc_val;
                    end
                end
                if (dec_p || dec_r) begin
                    automatic logic [PARAM_W-1:0] dec_val =
                        (all_params[bank_sel][fx_sel][param_sel] > 8'd0)
                            ? all_params[bank_sel][fx_sel][param_sel] - 1'b1
                            : 8'd0;
                    if (fx_sel == $clog2(FX_COUNT)'(GLOBAL_GAIN_FX)) begin
                        for (int b = 0; b < BANK_COUNT; b++)
                            all_params[b][fx_sel][param_sel] <= dec_val;
                    end else begin
                        all_params[bank_sel][fx_sel][param_sel] <= dec_val;
                    end
                end

                // Pot: only write when change exceeds 1 LSB hysteresis.
                if (pot_diff > 9'd1) begin
                    all_params[bank_sel][7][0] <= pot_scaled;
                    pot_prev <= pot_scaled;
                end                

                // Ensure expression value is kept across bank switches
                if (bank_switching && (bank_switch_ctr == 27'(BANK_FADE_CYCLES))) begin
                    all_params[pending_bank_sel][7][0] <= pot_scaled;
                end
            end
        end
    end

    // ----------------------------------------------------------------
    // Button Debounce
    // ----------------------------------------------------------------

    debounce_unit DEBOUNCE_INC  (.clk(clk), .rst_n(reset_n), .in(key_inc),     .stable(inc_s),      .pulse(inc_p));
    debounce_unit DEBOUNCE_DEC  (.clk(clk), .rst_n(reset_n), .in(key_dec),     .stable(dec_s),      .pulse(dec_p));
    debounce_unit DEBOUNCE_SAVE (.clk(clk), .rst_n(reset_n), .in(save_button), .stable(sav_s),      .pulse(sav_p));
    debounce_unit DEBOUNCE_LOAD (.clk(clk), .rst_n(reset_n), .in(load_button), .stable(ld_s),       .pulse(ld_p));
    debounce_unit DEBOUNCE_MUTE (.clk(clk), .rst_n(reset_n), .in(mute_button), .stable(mute_stable),.pulse());
    debounce_unit DEBOUNCE_BANK (.clk(clk), .rst_n(reset_n), .in(bank_toggle), .stable(bank_stable),.pulse(bank_pulse));

    genvar b;
    generate
        for (b = 0; b < 4; b++) begin : DEBOUNCE_BANK_BTN
            debounce_unit DBNC_BANK_BTN (
                .clk    (clk),
                .rst_n  (reset_n),
                .in     (~bank_btn[b]),
                .stable (bank_btn_stable[b]),
                .pulse  (bank_btn_pulse[b])
            );
        end
    endgenerate

    // ----------------------------------------------------------------
    // Auto-Repeat
    // ----------------------------------------------------------------

    repeat_unit REPEAT_INC (.clk(clk), .rst_n(reset_n), .stable(inc_s), .pulse(inc_r));
    repeat_unit REPEAT_DEC (.clk(clk), .rst_n(reset_n), .stable(dec_s), .pulse(dec_r));

    // ----------------------------------------------------------------
    // Tap / Mute
    // ----------------------------------------------------------------

    tap_mute_unit TAP_MUTE_UNIT (
        .clk        (clk),
        .rst_n      (reset_n),
        .stable     (mute_stable),
        .is_mute    (is_mute),
        .delay_pulse(delay_pulse)
    );

    tap_tempo_unit TAP_TEMPO (
        .clk          (clk),
        .rst_n        (reset_n),
        .tap_pulse    (delay_pulse),
        .delay_samples(tap_delay_samples),
        .tap_active   (tap_active),
        .beat_pulse   (beat_pulse)
    );

    // ----------------------------------------------------------------
    // Flash Save / Load FSM
    // ----------------------------------------------------------------

    controller_fsm CONTROLLER_FSM (
        .clk      (clk),
        .rst_n    (reset_n),
        .save_en  (sav_p | host_save_pulse),
        .load_en  (ld_p  | host_load_pulse),
        .curr_bank(f_bank),
        .curr_fx  (f_fx),
        .curr_p   (f_p),

        .flash_waitrequest   (flash_mem_waitrequest),
        .flash_readdatavalid (flash_mem_readdatavalid),
        .flash_readdata      (flash_mem_readdata),
        .flash_addr          (flash_mem_address),
        .flash_read          (flash_mem_read),
        .flash_write         (flash_mem_write),

        .flash_csr_waitrequest   (flash_csr_waitrequest),
        .flash_csr_readdatavalid (flash_csr_readdatavalid),
        .flash_csr_readdata      (flash_csr_readdata),
        .flash_csr_addr          (flash_csr_address),
        .flash_csr_read          (flash_csr_read),
        .flash_csr_write         (flash_csr_write),
        .flash_csr_writedata     (flash_csr_writedata),

        .latched_readdata(latched_readdata),
        .ld_from_mem     (ld_mem),
        .inc_idx         (inc_idx),
        .rst_idx         (rst_idx),
        .fsm_busy        (fsm_busy),
        .fsm_state_debug (fsm_state_debug),
        .load_valid      (load_valid),
        .write_sentinel  (write_sentinel)
    );

endmodule