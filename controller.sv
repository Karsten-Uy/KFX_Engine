
// module controller #(
//     parameter FX_COUNT         = 16,
//     parameter PARAM_COUNT      = 8,
//     parameter PARAM_W          = 8,
//     parameter DEBOUNCE_CNT_MAX = 1_000_000,
//     parameter REPEAT_START_CNT = 15_000_000,
//     parameter REPEAT_RATE_CNT  = 2_000_000,
//     parameter FLASH_BASE       = 23'h400000
// )(
//     input  logic clk, reset_n,
//     input  logic [$clog2(FX_COUNT)-1:0]    sw_fx_sel,
//     input  logic [$clog2(PARAM_COUNT)-1:0] sw_param_sel,
//     input  logic key_inc, key_dec, save_button,

//     output logic [PARAM_W-1:0]             params [0:FX_COUNT-1][0:PARAM_COUNT-1],
//     output logic [$clog2(FX_COUNT)-1:0]    fx_sel,
//     output logic [$clog2(PARAM_COUNT)-1:0] param_sel,
//     output logic [PARAM_W-1:0]             current_value,

//     output logic [9:0] LEDR,

//     // Flash MEM port (Avalon-MM)
//     output logic [22:0] flash_mem_address,
//     output logic        flash_mem_read,
//     output logic        flash_mem_write,
//     output logic [31:0] flash_mem_writedata,
//     input  logic [31:0] flash_mem_readdata,
//     input  logic        flash_mem_waitrequest,
//     input  logic        flash_mem_readdatavalid,
//     output logic [3:0]  flash_mem_byteenable,

//     // Flash CSR port (Avalon-MM)
//     output logic [5:0]  flash_csr_address,
//     output logic        flash_csr_write,
//     output logic        flash_csr_read,
//     output logic [31:0] flash_csr_writedata,
//     input  logic [31:0] flash_csr_readdata,
//     input  logic        flash_csr_waitrequest,
//     input  logic        flash_csr_readdatavalid
// );
//     import lab_pkg::*;

//     // Sentinel magic byte written to FLASH_BASE+0 to indicate valid save data.
//     // On load, if the first byte != SENTINEL, the load is aborted and defaults are kept.
//     localparam logic [7:0] SENTINEL = 8'hA5;

//     // Internal Signals
//     logic inc_p, dec_p, sav_p;
//     logic inc_s, dec_s, sav_s;
//     logic inc_r, dec_r;
//     logic ld_mem, inc_idx, rst_idx, fsm_busy;
//     logic [$clog2(FX_COUNT)-1:0]    f_fx;
//     logic [$clog2(PARAM_COUNT)-1:0] f_p;
//     logic [3:0] fsm_state_debug;
//     logic load_valid; // High after a successful load (sentinel confirmed)

//     // --- CSR Status Buffer ---
//     // The Flash IP returns read data on the CSR port via a valid pulse.
//     // We capture it so the FSM doesn't miss the status bit.
//     logic [31:0] csr_data_reg;
//     always_ff @(posedge clk) begin
//         if (!reset_n) csr_data_reg <= 32'hFFFFFFFF;
//         else if (flash_csr_readdatavalid) csr_data_reg <= flash_csr_readdata;
//     end

//     // --- UI Assignments ---
//     assign fx_sel        = sw_fx_sel;
//     assign param_sel     = sw_param_sel;
//     assign current_value = params[fx_sel][param_sel];

//     // Debug LED Mapping
//     assign LEDR[3:0] = fsm_state_debug;
//     assign LEDR[4]   = fsm_busy;
//     assign LEDR[5]   = flash_mem_waitrequest;
//     assign LEDR[6]   = flash_mem_readdatavalid;
//     assign LEDR[7]   = flash_csr_waitrequest;
//     assign LEDR[8]   = sav_s;
//     assign LEDR[9]   = sav_p;

//     // --- Flash Traversal Counters ---
//     always_ff @(posedge clk) begin
//         if (!reset_n || rst_idx) begin
//             f_fx <= '0;
//             f_p  <= '0;
//         end else if (inc_idx) begin
//             if (f_p == PARAM_COUNT - 1) begin
//                 f_p  <= '0;
//                 f_fx <= f_fx + 1'b1;
//             end else begin
//                 f_p <= f_p + 1'b1;
//             end
//         end
//     end

//     // --- Parameter Storage Logic ---
//     // Write data mux:
//     //   - On SAVE: write sentinel at index [0][0], params elsewhere
//     //   - On LOAD: write flash read data into params
//     //   - Otherwise: allow manual inc/dec
//     //
//     // The sentinel occupies the first flash word (FLASH_BASE+0).
//     // Param [0][0] is stored at FLASH_BASE+4 (one word offset).
//     // This is handled transparently by using a 1-word header in flash.
//     //
//     // Flash layout:
//     //   FLASH_BASE + 0x00  : SENTINEL (0xA5)
//     //   FLASH_BASE + 0x04  : params[0][0]
//     //   FLASH_BASE + 0x08  : params[0][1]
//     //   ...
//     //   FLASH_BASE + 0x04*(FX_COUNT*PARAM_COUNT) : last param
//     //
//     // The FSM address calculation offsets by +1 word for param data.
//     // See flash_mem_address assignment below.

//     integer i, j;
//     always_ff @(posedge clk) begin
//         if (!reset_n) begin
//             for (i = 0; i < FX_COUNT; i++)
//                 for (j = 0; j < PARAM_COUNT; j++)
//                     params[i][j] <= param_default(i, j);
//         end else if (ld_mem && load_valid) begin
//             // Load: only write params after sentinel is confirmed valid
//             // f_fx==0, f_p==0 is the sentinel slot — skip it for params
//             // (FSM won't pulse ld_mem for sentinel slot, it's consumed by sentinel_check)
//             params[f_fx][f_p] <= flash_mem_readdata[7:0];
//         end else if (!fsm_busy) begin
//             // Manual adjustment: Only allowed when Flash FSM is IDLE
//             if (inc_p || inc_r)
//                 params[fx_sel][param_sel] <= (params[fx_sel][param_sel] < 8'd255) ?
//                                               params[fx_sel][param_sel] + 1'b1 : 8'd255;
//             if (dec_p || dec_r)
//                 params[fx_sel][param_sel] <= (params[fx_sel][param_sel] > 8'd0) ?
//                                               params[fx_sel][param_sel] - 1'b1 : 8'd0;
//         end
//     end

//     // --- Power-On Auto-Load Logic ---
//     logic [23:0] power_on_timer;
//     logic        initial_load_done;
//     logic        auto_load_pulse;

//     always_ff @(posedge clk) begin
//         if (!reset_n) begin
//             power_on_timer    <= '0;
//             initial_load_done <= 1'b0;
//             auto_load_pulse   <= 1'b0;
//         end else if (!initial_load_done) begin
//             if (power_on_timer < 24'd5_000_000) // ~100ms at 50MHz
//                 power_on_timer <= power_on_timer + 1'b1;
//             else if (!fsm_busy) begin
//                 auto_load_pulse   <= 1'b1;
//                 initial_load_done <= 1'b1;
//             end
//         end else begin
//             auto_load_pulse <= 1'b0;
//         end
//     end

//     // --- Flash Write Data Mux ---
//     // During save: the FSM's f_fx/f_p counters start at [0][0].
//     // We store SENTINEL at that first position, and actual param data
//     // at all subsequent positions. The FSM address is offset by +1 word
//     // (see flash_mem_address below).
//     //
//     // Concretely:
//     //   FSM index [0][0] → flash address FLASH_BASE+0x00 → write SENTINEL
//     //   FSM index [0][1] → flash address FLASH_BASE+0x04 → write params[0][0]
//     //   FSM index [0][2] → flash address FLASH_BASE+0x08 → write params[0][1]
//     //   ...etc (index is shifted by 1 param relative to flash position)

//     logic is_sentinel_slot;
//     assign is_sentinel_slot = (f_fx == '0) && (f_p == '0);

//     // Write data: sentinel at first slot, params at remaining slots
//     // Note: params[f_fx][f_p] when shifted — the "previous" index feeds current write
//     // Simpler: use a local offset function here
//     logic [$clog2(FX_COUNT)-1:0]    param_read_fx;
//     logic [$clog2(PARAM_COUNT)-1:0] param_read_p;

//     // The param to write during SAVE_WRITE at FSM index (f_fx, f_p):
//     //   slot 0 → sentinel
//     //   slot N → params[(N-1) / PARAM_COUNT][(N-1) % PARAM_COUNT]
//     // Achieved by reading one index behind in the counter:
//     always_comb begin
//         if (is_sentinel_slot) begin
//             param_read_fx = '0;
//             param_read_p  = '0;
//         end else if (f_p == '0) begin
//             param_read_fx = f_fx - 1'b1;
//             param_read_p  = PARAM_COUNT - 1;
//         end else begin
//             param_read_fx = f_fx;
//             param_read_p  = f_p - 1'b1;
//         end
//     end

//     assign flash_mem_writedata  = is_sentinel_slot ?
//                                   {24'b0, SENTINEL} :
//                                   {24'b0, params[param_read_fx][param_read_p]};
//     assign flash_mem_byteenable = 4'hF;

//     // --- Debounce/Repeat Units ---
//     debounce_unit #(.CNT_MAX(DEBOUNCE_CNT_MAX))
//         db_i (.clk(clk), .rst_n(reset_n), .in(key_inc), .stable(inc_s), .pulse(inc_p));
//     debounce_unit #(.CNT_MAX(DEBOUNCE_CNT_MAX))
//         db_d (.clk(clk), .rst_n(reset_n), .in(key_dec), .stable(dec_s), .pulse(dec_p));
//     debounce_unit #(.CNT_MAX(DEBOUNCE_CNT_MAX))
//         db_s (.clk(clk), .rst_n(reset_n), .in(save_button), .stable(sav_s), .pulse(sav_p));

//     repeat_unit #(.START_CNT(REPEAT_START_CNT), .RATE_CNT(REPEAT_RATE_CNT))
//         rp_i (.clk(clk), .rst_n(reset_n), .stable(inc_s), .pulse(inc_r));
//     repeat_unit #(.START_CNT(REPEAT_START_CNT), .RATE_CNT(REPEAT_RATE_CNT))
//         rp_d (.clk(clk), .rst_n(reset_n), .stable(dec_s), .pulse(dec_r));

//     // --- Flash FSM ---
//     controller_fsm #(
//         .FX_COUNT(FX_COUNT),
//         .PARAM_COUNT(PARAM_COUNT),
//         .FLASH_BASE(FLASH_BASE)
//     ) fsm_inst (
//         .clk(clk),
//         .rst_n(reset_n),
//         .save_en(sav_p),
//         .load_en(auto_load_pulse),
//         .curr_fx(f_fx),
//         .curr_p(f_p),
//         .flash_waitrequest(flash_mem_waitrequest),
//         .flash_readdatavalid(flash_mem_readdatavalid),
//         .flash_addr(flash_mem_address),
//         .flash_read(flash_mem_read),
//         .flash_write(flash_mem_write),
//         .flash_csr_waitrequest(flash_csr_waitrequest),
//         .flash_csr_readdata(csr_data_reg),      // buffered CSR read data
//         .flash_csr_addr(flash_csr_address),
//         .flash_csr_read(flash_csr_read),
//         .flash_csr_write(flash_csr_write),
//         .flash_csr_writedata(flash_csr_writedata),
//         .ld_from_mem(ld_mem),
//         .inc_idx(inc_idx),
//         .rst_idx(rst_idx),
//         .fsm_busy(fsm_busy),
//         .fsm_state_debug(fsm_state_debug),
//         .load_valid(load_valid)
//     );

// endmodule


module controller #(
    parameter FX_COUNT         = 16,
    parameter PARAM_COUNT      = 8,
    parameter PARAM_W          = 8,
    parameter DEBOUNCE_CNT_MAX = 1_000_000,
    parameter REPEAT_START_CNT = 15_000_000,
    parameter REPEAT_RATE_CNT  = 2_000_000,
    parameter FLASH_BASE       = 23'h400000
)(
    input  logic clk, reset_n,
    input  logic [$clog2(FX_COUNT)-1:0]    sw_fx_sel,
    input  logic [$clog2(PARAM_COUNT)-1:0] sw_param_sel,
    input  logic key_inc, key_dec, save_button,

    output logic [PARAM_W-1:0]             params [0:FX_COUNT-1][0:PARAM_COUNT-1],
    output logic [$clog2(FX_COUNT)-1:0]    fx_sel,
    output logic [$clog2(PARAM_COUNT)-1:0] param_sel,
    output logic [PARAM_W-1:0]             current_value,

    output logic [9:0] LEDR,

    // Flash avl_mem port
    output logic [22:0] flash_mem_address,
    output logic        flash_mem_read,
    output logic        flash_mem_write,
    output logic [31:0] flash_mem_writedata,
    input  logic [31:0] flash_mem_readdata,
    input  logic        flash_mem_waitrequest,
    input  logic        flash_mem_readdatavalid,
    output logic [3:0]  flash_mem_byteenable,

    // Flash avl_csr port — passed through to FSM but never written during operation
    output logic [5:0]  flash_csr_address,
    output logic        flash_csr_write,
    output logic        flash_csr_read,
    output logic [31:0] flash_csr_writedata,
    input  logic [31:0] flash_csr_readdata,
    input  logic        flash_csr_waitrequest,
    input  logic        flash_csr_readdatavalid
);
    import lab_pkg::*;

    // Sentinel written as the first word of the save block.
    // On load, if byte 0 != SENTINEL, data is treated as invalid
    // and hardcoded defaults are kept.
    localparam logic [7:0] SENTINEL = 8'hA5;

    // Internal signals
    logic inc_p, dec_p, sav_p;
    logic inc_s, dec_s, sav_s;
    logic inc_r, dec_r;
    logic ld_mem, inc_idx, rst_idx, fsm_busy;
    logic [$clog2(FX_COUNT)-1:0]    f_fx;
    logic [$clog2(PARAM_COUNT)-1:0] f_p;
    logic [3:0] fsm_state_debug;
    logic load_valid;

    // flash_mem_readdata is used directly — the avl_mem port returns
    // read data via flash_mem_readdata + flash_mem_readdatavalid.
    // The CSR port read data is only used for sentinel check in FSM.
    // We pass flash_mem_readdata as the "csr_readdata" to the FSM for
    // the sentinel check since that's where load data actually comes from.

    // --- UI ---
    assign fx_sel        = sw_fx_sel;
    assign param_sel     = sw_param_sel;
    assign current_value = params[fx_sel][param_sel];

    // Debug LEDs
    assign LEDR[3:0] = fsm_state_debug;
    assign LEDR[4]   = fsm_busy;
    assign LEDR[5]   = flash_mem_waitrequest;
    assign LEDR[6]   = flash_mem_readdatavalid;
    assign LEDR[7]   = flash_csr_waitrequest;
    assign LEDR[8]   = sav_s;
    assign LEDR[9]   = sav_p;

    // --- Flash index counters ---
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

    // --- Parameter storage ---
    // Flash layout:
    //   FLASH_BASE + 0x00             : SENTINEL (0xA5)
    //   FLASH_BASE + 0x04             : params[0][0]
    //   FLASH_BASE + 0x08             : params[0][1]
    //   ...
    //
    // During save: FSM counter [0][0] → writes SENTINEL
    //              FSM counter [0][1] → writes params[0][0]
    //              FSM counter [0][2] → writes params[0][1]  etc.
    //
    // During load: FSM counter [0][0] → reads SENTINEL (sentinel check, NOT stored in params)
    //              FSM counter [0][1] → reads → params[0][0]
    //              FSM counter [0][2] → reads → params[0][1]  etc.
    //
    // The index-to-param mapping is offset by 1: param index = flash index - 1.
    // We compute the previous index for write data, and skip index [0][0] for load.

    // Is the current FSM slot the sentinel slot?
    logic is_sentinel_slot;
    assign is_sentinel_slot = (f_fx == '0) && (f_p == '0);

    // For SAVE: write data = SENTINEL at slot 0, otherwise params[(index-1)]
    // "index - 1" in the counter:
    logic [$clog2(FX_COUNT)-1:0]    prev_fx;
    logic [$clog2(PARAM_COUNT)-1:0] prev_p;
    always_comb begin
        if (f_p == '0) begin
            prev_fx = f_fx - 1'b1;
            prev_p  = PARAM_COUNT - 1;
        end else begin
            prev_fx = f_fx;
            prev_p  = f_p - 1'b1;
        end
    end

    assign flash_mem_writedata  = is_sentinel_slot ? {24'b0, SENTINEL}
                                                   : {24'b0, params[prev_fx][prev_p]};
    assign flash_mem_byteenable = 4'hF;

    // Parameter load logic
    // ld_mem pulses for one cycle per word read back.
    // Skip index [0][0] (sentinel) — don't store it in params.
    // Store into params at (index - 1).
    integer i, j;
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            for (i = 0; i < FX_COUNT; i++)
                for (j = 0; j < PARAM_COUNT; j++)
                    params[i][j] <= param_default(i, j);
        end else if (ld_mem && load_valid && !is_sentinel_slot) begin
            // Store flash data into the param slot one behind the counter
            params[prev_fx][prev_p] <= flash_mem_readdata[7:0];
        end else if (!fsm_busy) begin
            if (inc_p || inc_r)
                params[fx_sel][param_sel] <= (params[fx_sel][param_sel] < 8'd255) ?
                                              params[fx_sel][param_sel] + 1'b1 : 8'd255;
            if (dec_p || dec_r)
                params[fx_sel][param_sel] <= (params[fx_sel][param_sel] > 8'd0) ?
                                              params[fx_sel][param_sel] - 1'b1 : 8'd0;
        end
    end

    // --- Power-on auto-load ---
    logic [23:0] power_on_timer;
    logic        initial_load_done;
    logic        auto_load_pulse;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            power_on_timer    <= '0;
            initial_load_done <= 1'b0;
            auto_load_pulse   <= 1'b0;
        end else if (!initial_load_done) begin
            if (power_on_timer < 24'd5_000_000)
                power_on_timer <= power_on_timer + 1'b1;
            else if (!fsm_busy) begin
                auto_load_pulse   <= 1'b1;
                initial_load_done <= 1'b1;
            end
        end else begin
            auto_load_pulse <= 1'b0;
        end
    end

    // --- Debounce / repeat ---
    debounce_unit #(.CNT_MAX(DEBOUNCE_CNT_MAX))
        db_i (.clk(clk), .rst_n(reset_n), .in(key_inc),     .stable(inc_s), .pulse(inc_p));
    debounce_unit #(.CNT_MAX(DEBOUNCE_CNT_MAX))
        db_d (.clk(clk), .rst_n(reset_n), .in(key_dec),     .stable(dec_s), .pulse(dec_p));
    debounce_unit #(.CNT_MAX(DEBOUNCE_CNT_MAX))
        db_s (.clk(clk), .rst_n(reset_n), .in(save_button), .stable(sav_s), .pulse(sav_p));

    repeat_unit #(.START_CNT(REPEAT_START_CNT), .RATE_CNT(REPEAT_RATE_CNT))
        rp_i (.clk(clk), .rst_n(reset_n), .stable(inc_s), .pulse(inc_r));
    repeat_unit #(.START_CNT(REPEAT_START_CNT), .RATE_CNT(REPEAT_RATE_CNT))
        rp_d (.clk(clk), .rst_n(reset_n), .stable(dec_s), .pulse(dec_r));

    // --- FSM ---
    controller_fsm #(
        .FX_COUNT(FX_COUNT),
        .PARAM_COUNT(PARAM_COUNT),
        .FLASH_BASE(FLASH_BASE)
    ) fsm_inst (
        .clk(clk),
        .rst_n(reset_n),
        .save_en(sav_p),
        .load_en(auto_load_pulse),
        .curr_fx(f_fx),
        .curr_p(f_p),

        // avl_mem
        .flash_waitrequest   (flash_mem_waitrequest),
        .flash_readdatavalid (flash_mem_readdatavalid),
        .flash_addr          (flash_mem_address),
        .flash_read          (flash_mem_read),
        .flash_write         (flash_mem_write),

        // avl_csr — pass flash_mem_readdata in as "csr_readdata" so
        // the FSM sentinel check reads from the correct data source
        .flash_csr_waitrequest (flash_csr_waitrequest),
        .flash_csr_readdata    (flash_mem_readdata),  // <-- avl_mem data, not CSR
        .flash_csr_addr        (flash_csr_address),
        .flash_csr_read        (flash_csr_read),
        .flash_csr_write       (flash_csr_write),
        .flash_csr_writedata   (flash_csr_writedata),

        .ld_from_mem     (ld_mem),
        .inc_idx         (inc_idx),
        .rst_idx         (rst_idx),
        .fsm_busy        (fsm_busy),
        .fsm_state_debug (fsm_state_debug),
        .load_valid      (load_valid)
    );

endmodule
