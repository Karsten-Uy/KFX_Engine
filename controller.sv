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
    input  logic key_inc, key_dec, save_button, load_button,

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

    // Flash avl_csr port
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
    logic inc_r, dec_r;
    logic ld_mem, inc_idx, rst_idx, fsm_busy;
    logic [$clog2(FX_COUNT)-1:0]    f_fx;
    logic [$clog2(PARAM_COUNT)-1:0] f_p;
    logic [3:0]  fsm_state_debug;
    logic [31:0] latched_readdata;
    logic        load_valid;

    assign fx_sel        = sw_fx_sel;
    assign param_sel     = sw_param_sel;
    assign current_value = params[fx_sel][param_sel];

    // LED debug:
    // [3:0] = FSM state (lower 4 bits)
    // [4]   = fsm_busy
    // [5]   = flash_mem_waitrequest
    // [6]   = flash_mem_readdatavalid
    // [7]   = flash_csr_waitrequest
    // [8]   = save button stable
    // [9]   = flash_csr_readdatavalid
    assign LEDR[3:0] = fsm_state_debug;
    assign LEDR[4]   = fsm_busy;
    assign LEDR[5]   = flash_mem_waitrequest;
    assign LEDR[6]   = flash_mem_readdatavalid;
    assign LEDR[7]   = flash_csr_waitrequest;
    assign LEDR[8]   = sav_s;
    assign LEDR[9]   = flash_csr_readdatavalid;

    // Flash word index counters
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

    // Flash layout:
    //   slot [fx=0][p=0] = SENTINEL word (0xA5)
    //   slot [fx=0][p=1] = params[0][0]
    //   slot [fx=0][p=2] = params[0][1]
    //   ...
    // Write at current index, data = previous slot's param
    logic is_sentinel_slot;
    assign is_sentinel_slot = (f_fx == '0) && (f_p == '0);

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

    // avl_mem write data: sentinel at slot 0, else the param for previous slot
    // The xip_controller uses byteenable to determine actual write byte count
    assign flash_mem_writedata  = is_sentinel_slot ? {24'b0, SENTINEL}
                                                   : {24'b0, params[prev_fx][prev_p]};
    // byteenable=0001: write only byte 0 (1 byte per word address)
    assign flash_mem_byteenable = 4'b0001;

    // Parameter storage
    integer i, j;
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            for (i = 0; i < FX_COUNT; i++)
                for (j = 0; j < PARAM_COUNT; j++)
                    params[i][j] <= param_default(i, j);
        end else if (ld_mem && load_valid && !is_sentinel_slot) begin
            params[prev_fx][prev_p] <= latched_readdata[7:0];
        end else if (!fsm_busy) begin
            if (inc_p || inc_r)
                params[fx_sel][param_sel] <= (params[fx_sel][param_sel] < 8'd255) ?
                                              params[fx_sel][param_sel] + 1'b1 : 8'd255;
            if (dec_p || dec_r)
                params[fx_sel][param_sel] <= (params[fx_sel][param_sel] > 8'd0) ?
                                              params[fx_sel][param_sel] - 1'b1 : 8'd0;
        end
    end

    // Debounce
    debounce_unit #(.CNT_MAX(DEBOUNCE_CNT_MAX))
        db_i (.clk(clk), .rst_n(reset_n), .in(key_inc),     .stable(inc_s), .pulse(inc_p));
    debounce_unit #(.CNT_MAX(DEBOUNCE_CNT_MAX))
        db_d (.clk(clk), .rst_n(reset_n), .in(key_dec),     .stable(dec_s), .pulse(dec_p));
    debounce_unit #(.CNT_MAX(DEBOUNCE_CNT_MAX))
        db_s (.clk(clk), .rst_n(reset_n), .in(save_button), .stable(sav_s), .pulse(sav_p));
    debounce_unit #(.CNT_MAX(DEBOUNCE_CNT_MAX))
        db_l (.clk(clk), .rst_n(reset_n), .in(load_button), .stable(ld_s),  .pulse(ld_p));

    repeat_unit #(.START_CNT(REPEAT_START_CNT), .RATE_CNT(REPEAT_RATE_CNT))
        rp_i (.clk(clk), .rst_n(reset_n), .stable(inc_s), .pulse(inc_r));
    repeat_unit #(.START_CNT(REPEAT_START_CNT), .RATE_CNT(REPEAT_RATE_CNT))
        rp_d (.clk(clk), .rst_n(reset_n), .stable(dec_s), .pulse(dec_r));

    // FSM
    controller_fsm #(
        .FX_COUNT(FX_COUNT),
        .PARAM_COUNT(PARAM_COUNT),
        .FLASH_BASE(FLASH_BASE)
    ) fsm_inst (
        .clk(clk),
        .rst_n(reset_n),
        .save_en(sav_p),
        .load_en(ld_p),
        .curr_fx(f_fx),
        .curr_p(f_p),
        .write_data_byte(is_sentinel_slot ? SENTINEL : params[prev_fx][prev_p]),

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

        .latched_readdata (latched_readdata),
        .ld_from_mem      (ld_mem),
        .inc_idx          (inc_idx),
        .rst_idx          (rst_idx),
        .fsm_busy         (fsm_busy),
        .fsm_state_debug  (fsm_state_debug),
        .load_valid       (load_valid)
    );

endmodule