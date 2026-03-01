/*
 * controller.sv
 *
 * FX parameter controller for the AudioFX pedalboard.
 *
 * Four independent parameter banks are stored internally as
 *   all_params[BANK_COUNT][FX_COUNT][PARAM_COUNT].
 * The active bank is selected by toggling sw_bank_toggle (SW[5]): each
 * rising edge advances the bank selector 0 → 1 → 2 → 3 → 0.
 *
 * The existing 2-D `params` output always reflects the currently active
 * bank, so the FX chain and display module require no changes.
 *
 * Save / load (flash)
 * -------------------
 *   Save writes ALL four banks to flash followed by the 0xA5 sentinel.
 *   Load reads ALL four banks back; load_valid is asserted only if the
 *   sentinel was found.  The DAC is muted for the full duration via
 *   fsm_busy.
 *
 * New ports vs original
 * ---------------------
 *   sw_bank_toggle  — raw SW input: rising edge advances the bank selector
 *   bank_sel        — 2-bit registered bank index (0–3), exposed for display
 *
 * Unchanged ports
 * ---------------
 *   All original ports keep their names, widths, and semantics.
 */

module controller (
    input  logic clk, reset_n,
    input  logic [$clog2(FX_COUNT)-1:0]    sw_fx_sel,
    input  logic [$clog2(PARAM_COUNT)-1:0] sw_param_sel,
    input  logic key_inc, key_dec, save_button, load_button,
    input  logic mute_button,
    input  logic sw_bank_toggle,

    output logic [PARAM_W-1:0]             params [0:FX_COUNT-1][0:PARAM_COUNT-1],
    output logic [$clog2(FX_COUNT)-1:0]    fx_sel,
    output logic [$clog2(PARAM_COUNT)-1:0] param_sel,
    output logic [PARAM_W-1:0]             current_value,
    output logic                           is_mute,
    output logic                           delay_pulse,
    output logic [$clog2(BANK_COUNT)-1:0]  bank_sel,

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

    localparam logic [7:0] SENTINEL = 8'hA5;

    // ----------------------------------------------------------------
    // Internal Signals
    // ----------------------------------------------------------------

    logic inc_p, dec_p, sav_p, ld_p;
    logic inc_s, dec_s, sav_s, ld_s;
    logic mute_stable;
    logic inc_r, dec_r;

    // FSM control signals
    logic ld_mem, inc_idx, rst_idx;
    logic [$clog2(BANK_COUNT)-1:0]  f_bank; // flash loop index — bank axis  NEW
    logic [$clog2(FX_COUNT)-1:0]    f_fx;
    logic [$clog2(PARAM_COUNT)-1:0] f_p;
    logic [3:0]  fsm_state_debug;
    logic [31:0] latched_readdata;
    logic        load_valid;
    logic        write_sentinel;

    // ----------------------------------------------------------------
    // Three-Dimensional Parameter Storage
    // ----------------------------------------------------------------
    // all_params holds every bank.  `params` (the 2-D output) is wired
    // combinationally to the currently active bank via always_comb below.

    logic [PARAM_W-1:0] all_params [0:BANK_COUNT-1][0:FX_COUNT-1][0:PARAM_COUNT-1];

    // Expose active bank as the output array expected by the FX chain
    always_comb begin
        for (int fi = 0; fi < FX_COUNT; fi++)
            for (int pi = 0; pi < PARAM_COUNT; pi++)
                params[fi][pi] = all_params[bank_sel][fi][pi];
    end

    // ----------------------------------------------------------------
    // Selection Pass-Through
    // ----------------------------------------------------------------

    assign fx_sel        = sw_fx_sel;
    assign param_sel     = sw_param_sel;
    assign current_value = all_params[bank_sel][fx_sel][param_sel];

    // ----------------------------------------------------------------
    // Bank Toggle  (rising-edge detect on sw_bank_toggle)
    //
    // Each rising edge of SW[5] advances bank_sel:  0 → 1 → 2 → 3 → 0.
    // The toggle is ignored while the FSM is busy to prevent a bank
    // switch mid-save/load from corrupting the index arithmetic.
    // ----------------------------------------------------------------

    logic sw_bank_prev;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            bank_sel     <= '0;
            sw_bank_prev <= 1'b0;
        end else begin
            sw_bank_prev <= sw_bank_toggle;
            if (sw_bank_toggle && !sw_bank_prev && !fsm_busy) begin
                // Wrapping increment: 0→1→2→3→0
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
    // Flash Index Counters
    //
    // (f_bank, f_fx, f_p) step through all_params in row-major order.
    // Innermost axis: p.  Middle: fx.  Outermost: bank.
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
                    f_bank <= f_bank + 1'b1;  // saturates naturally at BANK_COUNT-1
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
    // On reset:  load defaults for every bank (all banks share the same
    //            param_default table; bank 0 is the "factory" preset).
    // On load:   write one byte per ld_mem pulse, addressed by (f_bank, f_fx, f_p).
    // On idle:   apply inc/dec to the active bank only.
    // ----------------------------------------------------------------

    int i, j, k;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            for (k = 0; k < BANK_COUNT; k++)
                for (i = 0; i < FX_COUNT; i++)
                    for (j = 0; j < PARAM_COUNT; j++)
                        all_params[k][i][j] <= param_default(i, j);

        end else if (ld_mem && load_valid) begin
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

    // ----------------------------------------------------------------
    // Flash Save / Load FSM
    // ----------------------------------------------------------------

    controller_fsm CONTROLLER_FSM (
        .clk      (clk),
        .rst_n    (reset_n),
        .save_en  (sav_p),
        .load_en  (ld_p),
        .curr_bank(f_bank),          // NEW: bank axis
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