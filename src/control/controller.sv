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
 * Bank selection
 * --------------
 *   bank_toggle is debounced with a dedicated debounce_unit, and
 *   its `pulse` output (a single clean rising-edge pulse) is used directly
 *   to advance bank_sel.  No manual flip-flop edge detection is needed.
 *
 *   Each clean press cycles:  bank 0 → 1 → 2 → 3 → 0.
 *   Bank switching is ignored while fsm_busy is high.
 *
 * Power-on defaults
 * -----------------
 *   param_default(bank, fx, param) now takes a bank argument so each
 *   bank gets its own factory preset.  The reset block calls this for
 *   every (bank, fx, param) triple.
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
 *   bank_sel      — output continaing the currently selected bank number
 *   LEDR          — diagnostic LED output
 *   fsm_busy      — high while save or load is in progress
 */

/*
 * controller.sv
 *
 * FX parameter controller for the AudioFX pedalboard.
 *
 * Owns the all_params[][][] array and handles all user interactions that
 * modify it: button-driven increment/decrement with auto-repeat, save to
 * flash, load from flash, and mute/tap-tempo via the footswitch.
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
 * Bank selection
 * --------------
 *   bank_toggle is debounced by DEBOUNCE_BANK; its pulse output is a
 *   guaranteed single-cycle rising-edge pulse used directly to advance
 *   bank_sel.  No manual edge-detect flip-flop is needed.
 *
 *   Bank switching is ignored while fsm_busy is high.
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
    input  logic        flash_csr_readdatavalid
);

    import lab_pkg::*;

    localparam logic [7:0] SENTINEL = 8'hA5;

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
    // paths as clean register-to-register paths, avoiding the buzzing
    // that results from a 128-wide combinational mux on an output port.
    //
    // One-cycle latency after all_params updates is 20 ns — inaudible.
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            // On reset, pre-load bank 0 defaults so the FX chain gets
            // valid params on the very first audio sample.
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

    // ----------------------------------------------------------------
    // Bank Select
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            bank_sel <= '0;
        end else if (!fsm_busy) begin
            // GPIO buttons — direct bank select (higher priority)
            if      (bank_btn_pulse[0]) bank_sel <= 2'd0;
            else if (bank_btn_pulse[1]) bank_sel <= 2'd1;
            else if (bank_btn_pulse[2]) bank_sel <= 2'd2;
            else if (bank_btn_pulse[3]) bank_sel <= 2'd3;
            // SW2 toggle — cycles through banks (lower priority)
            else if (bank_pulse) begin
                if (bank_sel == BANK_COUNT - 1)
                    bank_sel <= '0;
                else
                    bank_sel <= bank_sel + 1'b1;
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

            if (ld_mem && load_valid) begin
                all_params[f_bank][f_fx][f_p] <= latched_readdata[7:0];

            end else if (!fsm_busy) begin
                if (inc_p || inc_r)
                    all_params[bank_sel][fx_sel][param_sel] <=
                        (all_params[bank_sel][fx_sel][param_sel] < 8'd255)
                            ? all_params[bank_sel][fx_sel][param_sel] + 1'b1
                            : 8'd255;
                if (dec_p || dec_r)
                    all_params[bank_sel][fx_sel][param_sel] <=
                        (all_params[bank_sel][fx_sel][param_sel] > 8'd0)
                            ? all_params[bank_sel][fx_sel][param_sel] - 1'b1
                            : 8'd0;

                // Pot: only write when change exceeds 1 LSB hysteresis.
                // pot_prev tracks the LAST WRITTEN value, not the last seen value.
                // If it tracked every cycle, pot_prev always == pot_scaled and
                // the condition never fires.
                if (pot_diff > 9'd1) begin
                    all_params[bank_sel][7][0] <= pot_scaled;
                    pot_prev <= pot_scaled;
                end
            end
        end
    end

    // Bank Switching Param
    logic [15:0] bank_switch_ctr;     // ~1.3 ms at 50 MHz = 65536 cycles
    localparam BANK_MUTE_CYCLES = 16'd65535;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            bank_switching  <= 1'b0;
            bank_switch_ctr <= '0;
        end else begin
            // Detect any bank change (pulse from toggle or direct button)
            if ((bank_pulse || bank_btn_pulse[0] || bank_btn_pulse[1] ||
                bank_btn_pulse[2] || bank_btn_pulse[3]) && !fsm_busy) begin
                bank_switching  <= 1'b1;
                bank_switch_ctr <= '0;
            end else if (bank_switching) begin
                if (bank_switch_ctr == BANK_MUTE_CYCLES)
                    bank_switching <= 1'b0;
                else
                    bank_switch_ctr <= bank_switch_ctr + 1'b1;
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
        .save_en  (sav_p),
        .load_en  (ld_p),
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