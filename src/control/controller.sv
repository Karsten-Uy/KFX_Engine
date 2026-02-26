module controller #(
    parameter FX_COUNT         = 16,
    parameter PARAM_COUNT      = 8,
    parameter PARAM_W          = 8,
    parameter DEBOUNCE_CNT_MAX = 1_000_000,
    parameter REPEAT_START_CNT = 15_000_000,
    parameter REPEAT_RATE_CNT  = 2_000_000,
    parameter MUTE_START_CNT   = 50_000_000,   // added for tap_mute_unit
    parameter FLASH_BASE       = 24'h6B0000
)(
    input  logic clk, reset_n,
    input  logic [$clog2(FX_COUNT)-1:0]    sw_fx_sel,
    input  logic [$clog2(PARAM_COUNT)-1:0] sw_param_sel,
    input  logic key_inc, key_dec, save_button, load_button,
    input  logic mute_button,                  // added: physical mute/tap button

    output logic [PARAM_W-1:0]             params [0:FX_COUNT-1][0:PARAM_COUNT-1],
    output logic [$clog2(FX_COUNT)-1:0]    fx_sel,
    output logic [$clog2(PARAM_COUNT)-1:0] param_sel,
    output logic [PARAM_W-1:0]             current_value,
    output logic                           is_mute,
    output logic                           delay_pulse,

    // Debug signals
    output logic [9:0] LEDR,
    output logic fsm_busy,

    // Flash avl_mem
    output logic [21:0] flash_mem_address,
    output logic        flash_mem_read,
    output logic        flash_mem_write,
    output logic [31:0] flash_mem_writedata,
    input  logic [31:0] flash_mem_readdata,
    input  logic        flash_mem_waitrequest,
    input  logic        flash_mem_readdatavalid,
    output logic [3:0]  flash_mem_byteenable,

    // Flash avl_csr
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

    logic inc_p, dec_p, sav_p, ld_p;
    logic inc_s, dec_s, sav_s, ld_s;
    logic mute_stable;                         // debounced mute button

    logic inc_r, dec_r;
    logic ld_mem, inc_idx, rst_idx;
    logic [$clog2(FX_COUNT)-1:0]    f_fx;
    logic [$clog2(PARAM_COUNT)-1:0] f_p;
    logic [3:0]  fsm_state_debug;
    logic [31:0] latched_readdata;
    logic        load_valid;
    logic        write_sentinel;

    assign fx_sel        = sw_fx_sel;
    assign param_sel     = sw_param_sel;
    assign current_value = params[fx_sel][param_sel];

    // ----------------------------------------------------------------
    // Write data to flash
    // ----------------------------------------------------------------
    assign flash_mem_writedata  = write_sentinel
                                    ? {24'b0, SENTINEL}
                                    : {24'b0, params[f_fx][f_p]};
    assign flash_mem_byteenable = 4'b0001;

    // ----------------------------------------------------------------
    // Diagnostic LEDs
    // ----------------------------------------------------------------
    logic [7:0] save_latch;
    logic [7:0] load_latch;
    logic        save_op_done;
    logic        load_op_done;
    logic        fsm_busy_prev;

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

            if (sav_p || ld_p) begin
                save_op_done <= 1'b0;
                load_op_done <= 1'b0;
            end

            if (inc_p || inc_r || dec_p || dec_r) begin
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
    // Flash index counters
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
    // Parameter storage
    // ----------------------------------------------------------------
    integer i, j;
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
    // Button debounce + repeat
    // ----------------------------------------------------------------
    debounce_unit #(.CNT_MAX(DEBOUNCE_CNT_MAX))
        db_i (.clk(clk), .rst_n(reset_n), .in(key_inc),     .stable(inc_s),    .pulse(inc_p));
    debounce_unit #(.CNT_MAX(DEBOUNCE_CNT_MAX))
        db_d (.clk(clk), .rst_n(reset_n), .in(key_dec),     .stable(dec_s),    .pulse(dec_p));
    debounce_unit #(.CNT_MAX(DEBOUNCE_CNT_MAX))
        db_s (.clk(clk), .rst_n(reset_n), .in(save_button), .stable(sav_s),    .pulse(sav_p));
    debounce_unit #(.CNT_MAX(DEBOUNCE_CNT_MAX))
        db_l (.clk(clk), .rst_n(reset_n), .in(load_button), .stable(ld_s),     .pulse(ld_p));
    debounce_unit #(.CNT_MAX(DEBOUNCE_CNT_MAX))
        db_m (.clk(clk), .rst_n(reset_n), .in(mute_button), .stable(mute_stable), .pulse());

    repeat_unit #(.START_CNT(REPEAT_START_CNT), .RATE_CNT(REPEAT_RATE_CNT))
        rp_i (.clk(clk), .rst_n(reset_n), .stable(inc_s), .pulse(inc_r));
    repeat_unit #(.START_CNT(REPEAT_START_CNT), .RATE_CNT(REPEAT_RATE_CNT))
        rp_d (.clk(clk), .rst_n(reset_n), .stable(dec_s), .pulse(dec_r));

    // ----------------------------------------------------------------
    // Tap / mute unit
    //   - short press  -> delay_pulse pulse (tap tempo)
    //   - long press   -> assert is_mute
    //   - press while muted -> clear is_mute immediately
    // ----------------------------------------------------------------
    tap_mute_unit #(.LONG_PRESS_CNT(MUTE_START_CNT))
        tm_u (
            .clk        (clk),
            .rst_n      (reset_n),
            .stable     (mute_stable),
            .is_mute    (is_mute),
            .delay_pulse(delay_pulse)
        );

    // ----------------------------------------------------------------
    // FSM
    // ----------------------------------------------------------------
    controller_fsm #(
        .FX_COUNT   (FX_COUNT),
        .PARAM_COUNT(PARAM_COUNT),
        .FLASH_BASE (FLASH_BASE)
    ) fsm_inst (
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