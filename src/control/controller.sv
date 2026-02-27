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
 * Ports
 * -----
 *   sw_fx_sel    — slide-switch FX index (combinational select, not registered)
 *   sw_param_sel — slide-switch parameter index
 *   key_inc      — increment button (active-high, raw)
 *   key_dec      — decrement button (active-high, raw)
 *   save_button  — save-to-flash button (active-high, raw)
 *   load_button  — load-from-flash button (active-high, raw)
 *   mute_button  — footswitch: short = tap tempo, long = mute (active-high, raw)
 *   params       — full parameter array exposed to the FX chain
 *   fx_sel       — registered copy of sw_fx_sel for display / value readback
 *   param_sel    — registered copy of sw_param_sel
 *   current_value — params[fx_sel][param_sel], for the display module
 *   is_mute      — high while audio is muted
 *   delay_pulse  — single-cycle tap-tempo pulse to tap_tempo_unit
 *   LEDR         — diagnostic LED output
 *   fsm_busy     — high while save or load is in progress
 */

module controller (
    input  logic clk, reset_n,
    input  logic [$clog2(FX_COUNT)-1:0]    sw_fx_sel,
    input  logic [$clog2(PARAM_COUNT)-1:0] sw_param_sel,
    input  logic key_inc, key_dec, save_button, load_button,
    input  logic mute_button,

    output logic [PARAM_W-1:0]             params [0:FX_COUNT-1][0:PARAM_COUNT-1],
    output logic [$clog2(FX_COUNT)-1:0]    fx_sel,
    output logic [$clog2(PARAM_COUNT)-1:0] param_sel,
    output logic [PARAM_W-1:0]             current_value,
    output logic                           is_mute,
    output logic                           delay_pulse,

    // Diagnostic
    output logic [9:0] LEDR,
    output logic       fsm_busy,

    // Flash avl_mem interface
    output logic [21:0] flash_mem_address,
    output logic        flash_mem_read,
    output logic        flash_mem_write,
    output logic [31:0] flash_mem_writedata,
    input  logic [31:0] flash_mem_readdata,
    input  logic        flash_mem_waitrequest,
    input  logic        flash_mem_readdatavalid,
    output logic [3:0]  flash_mem_byteenable,

    // Flash avl_csr interface
    output logic [5:0]  flash_csr_address,
    output logic        flash_csr_write,
    output logic        flash_csr_read,
    output logic [31:0] flash_csr_writedata,
    input  logic [31:0] flash_csr_readdata,
    input  logic        flash_csr_waitrequest,
    input  logic        flash_csr_readdatavalid
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // Local Constants
    // ----------------------------------------------------------------

    localparam logic [7:0] SENTINEL = 8'hA5;  // must match controller_fsm

    // ----------------------------------------------------------------
    // Internal Signals
    // ----------------------------------------------------------------

    // Debounced stable levels and rising-edge pulses
    logic inc_p, dec_p, sav_p, ld_p;   // single-cycle press pulses
    logic inc_s, dec_s, sav_s, ld_s;   // stable (held) levels
    logic mute_stable;                  // debounced footswitch level

    // Auto-repeat pulses (fires at REPEAT_RATE_CNT while button is held)
    logic inc_r, dec_r;

    // FSM control signals
    logic ld_mem, inc_idx, rst_idx;
    logic [$clog2(FX_COUNT)-1:0]    f_fx;  // flash loop index — FX axis
    logic [$clog2(PARAM_COUNT)-1:0] f_p;   // flash loop index — param axis
    logic [3:0]  fsm_state_debug;
    logic [31:0] latched_readdata;
    logic        load_valid;
    logic        write_sentinel;

    // ----------------------------------------------------------------
    // Selection Pass-Through
    // ----------------------------------------------------------------

    assign fx_sel        = sw_fx_sel;
    assign param_sel     = sw_param_sel;
    assign current_value = params[fx_sel][param_sel];

    // ----------------------------------------------------------------
    // Flash Write Data
    //
    // During normal saves, write the current param byte.
    // During the sentinel write, write 0xA5 to slot 0.
    // Only byte 0 of the 32-bit word is used; byteenable is fixed to 0001.
    // ----------------------------------------------------------------

    assign flash_mem_writedata  = write_sentinel
                                    ? {24'b0, SENTINEL}
                                    : {24'b0, params[f_fx][f_p]};
    assign flash_mem_byteenable = 4'b0001;

    // ----------------------------------------------------------------
    // Diagnostic LEDs
    //
    // LEDR[7:0] shows:
    //   - the last byte written (during/after save)
    //   - the last byte read    (during/after load)
    //   - current_value         (idle)
    // LEDR[8] = load_valid (1 = flash contained a valid save)
    // LEDR[9] = fsm_busy
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

            // Track bytes as they move through the bus
            if (flash_mem_write && !flash_mem_waitrequest)
                save_latch <= flash_mem_writedata[7:0];
            if (flash_mem_readdatavalid)
                load_latch <= flash_mem_readdata[7:0];

            // Clear done flags on any new user action
            if (sav_p || ld_p || inc_p || inc_r || dec_p || dec_r) begin
                save_op_done <= 1'b0;
                load_op_done <= 1'b0;
            end

            // Set done flags on FSM completion
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
    // Flash Index Counters
    //
    // (f_fx, f_p) step through the params[][] address space in row-major
    // order.  The FSM drives inc_idx to advance and rst_idx to reset.
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n || rst_idx) begin
            f_fx <= '0;
            f_p  <= '0;
        end else if (inc_idx) begin
            if (f_p == PARAM_COUNT - 1) begin
                f_p  <= '0;
                f_fx <= f_fx + 1'b1;
            end else begin
                f_p <= f_p + 1'b1;
            end
        end
    end

    // ----------------------------------------------------------------
    // Parameter Storage
    //
    // On reset: load all defaults from param_default().
    // During load: write one byte per ld_mem pulse (from FSM).
    // During idle: apply inc/dec from buttons (clamped to [0, 255]).
    // ----------------------------------------------------------------

    int i, j;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            for (i = 0; i < FX_COUNT; i++)
                for (j = 0; j < PARAM_COUNT; j++)
                    params[i][j] <= param_default(i, j);

        end else if (ld_mem && load_valid) begin
            params[f_fx][f_p] <= latched_readdata[7:0];

        end else if (!fsm_busy) begin
            if (inc_p || inc_r)
                params[fx_sel][param_sel] <= (params[fx_sel][param_sel] < 8'd255)
                                              ? params[fx_sel][param_sel] + 1'b1
                                              : 8'd255;
            if (dec_p || dec_r)
                params[fx_sel][param_sel] <= (params[fx_sel][param_sel] > 8'd0)
                                              ? params[fx_sel][param_sel] - 1'b1
                                              : 8'd0;
        end
    end

    // ----------------------------------------------------------------
    // Button Debounce
    // ----------------------------------------------------------------

    debounce_unit db_i (.clk(clk), .rst_n(reset_n), .in(key_inc),     .stable(inc_s),    .pulse(inc_p));
    debounce_unit db_d (.clk(clk), .rst_n(reset_n), .in(key_dec),     .stable(dec_s),    .pulse(dec_p));
    debounce_unit db_s (.clk(clk), .rst_n(reset_n), .in(save_button), .stable(sav_s),    .pulse(sav_p));
    debounce_unit db_l (.clk(clk), .rst_n(reset_n), .in(load_button), .stable(ld_s),     .pulse(ld_p));
    debounce_unit db_m (.clk(clk), .rst_n(reset_n), .in(mute_button), .stable(mute_stable), .pulse());

    // ----------------------------------------------------------------
    // Auto-Repeat  (increment and decrement only)
    // ----------------------------------------------------------------

    repeat_unit rp_i (.clk(clk), .rst_n(reset_n), .stable(inc_s), .pulse(inc_r));
    repeat_unit rp_d (.clk(clk), .rst_n(reset_n), .stable(dec_s), .pulse(dec_r));

    // ----------------------------------------------------------------
    // Tap / Mute  (footswitch: short = tap, long = mute)
    // ----------------------------------------------------------------

    tap_mute_unit tm_u (
        .clk        (clk),
        .rst_n      (reset_n),
        .stable     (mute_stable),
        .is_mute    (is_mute),
        .delay_pulse(delay_pulse)
    );

    // ----------------------------------------------------------------
    // Flash Save / Load FSM
    // ----------------------------------------------------------------

    controller_fsm fsm_inst (
        .clk    (clk),
        .rst_n  (reset_n),
        .save_en(sav_p),
        .load_en(ld_p),
        .curr_fx(f_fx),
        .curr_p (f_p),

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