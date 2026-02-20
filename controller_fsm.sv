module controller_fsm #(
    parameter FX_COUNT    = 16,
    parameter PARAM_COUNT = 8,
    parameter FLASH_BASE  = 23'h400000
) (
    input  logic clk,
    input  logic rst_n,
    input  logic save_en,
    input  logic load_en,
    input  logic [$clog2(FX_COUNT)-1:0]    curr_fx,
    input  logic [$clog2(PARAM_COUNT)-1:0] curr_p,
    input  logic [7:0] write_data_byte,

    // avl_mem — used for writes (XIP handles WREN+PP+poll) and reads
    input  logic        flash_waitrequest,
    input  logic        flash_readdatavalid,
    input  logic [31:0] flash_readdata,
    output logic [22:0] flash_addr,
    output logic        flash_read,
    output logic        flash_write,

    // avl_csr — used only for sector erase
    input  logic        flash_csr_waitrequest,
    input  logic        flash_csr_readdatavalid,
    input  logic [31:0] flash_csr_readdata,
    output logic [5:0]  flash_csr_addr,
    output logic        flash_csr_read,
    output logic        flash_csr_write,
    output logic [31:0] flash_csr_writedata,

    output logic [31:0] latched_readdata,
    output logic        ld_from_mem,
    output logic        inc_idx,
    output logic        rst_idx,
    output logic        fsm_busy,
    output logic [3:0]  fsm_state_debug,
    output logic        load_valid,
    output logic        sentinel_checked
);

    // ----------------------------------------------------------------
    // CSR register map — only what we need for erase
    // ----------------------------------------------------------------
    localparam CSR_CMD_SETTING = 6'd7;
    localparam CSR_CMD_CONTROL = 6'd8;
    localparam CSR_CMD_ADDR    = 6'd9;

    // Sector erase: D8h, 3 address bytes, no data
    localparam CMD_ERASE_SETTING = 32'h000003D8;
    localparam CMD_FIRE          = 32'h00000001;

    localparam SENTINEL = 8'hA5;

    // After ERASE_FIRE is accepted (waitrequest goes low = SPI erase
    // command fully transmitted), the flash erases internally.
    // EPCQ256 64KB sector: 150ms typ, 2000ms max @ 50MHz = 100M cycles.
    // We wait the full max to be safe — no WIP polling needed.
    localparam ERASE_WAIT_CYCLES = 27'd100_000_000; // 2s

    typedef enum logic [3:0] {
        IDLE           = 4'd0,
        ERASE_SET_CMD  = 4'd1,
        ERASE_SETTLE   = 4'd2,
        ERASE_SET_ADDR = 4'd3,
        ERASE_FIRE     = 4'd4,
        ERASE_WAIT     = 4'd5,  // blind wait for internal erase to complete
        SAVE_WRITE     = 4'd6,  // avl_mem write (XIP does WREN+PP+poll)
        SAVE_NEXT      = 4'd7,
        LOAD_READ      = 4'd8,
        LOAD_WAIT      = 4'd9,
        LOAD_STORE     = 4'd10,
        LOAD_NEXT      = 4'd11
    } state_t;

    state_t state, next;
    assign fsm_state_debug = state[3:0];

    logic [22:0] word_addr;
    // assign word_addr = FLASH_BASE[22:0] +
    //                    ((23'(curr_fx) * PARAM_COUNT + 23'(curr_p)) << 2);
    assign word_addr = {2'b0, FLASH_BASE[22:2]} +
                   (23'(curr_fx) * PARAM_COUNT + 23'(curr_p));

    // Erase wait counter
    logic [26:0] erase_cnt;
    always_ff @(posedge clk) begin
        if (!rst_n || state != ERASE_WAIT)
            erase_cnt <= '0;
        else if (erase_cnt != ERASE_WAIT_CYCLES)
            erase_cnt <= erase_cnt + 1'b1;
    end
    wire erase_done = (erase_cnt == ERASE_WAIT_CYCLES);

    always_ff @(posedge clk) begin
        if (!rst_n)
            latched_readdata <= 32'hFFFFFFFF;
        else if (flash_readdatavalid)
            latched_readdata <= flash_readdata;
    end

    logic sentinel_ok;

    always_ff @(posedge clk) begin
        if (!rst_n) state <= IDLE;
        else        state <= next;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sentinel_ok      <= 1'b0;
            sentinel_checked <= 1'b0;
            load_valid       <= 1'b0;
        end else begin
            if (state == IDLE) begin
                sentinel_ok      <= 1'b0;
                sentinel_checked <= 1'b0;
                load_valid       <= 1'b0;
            end
            // Check sentinel when first read data arrives.
            // data_adapter_8_32 packs: byte0→[7:0], byte1→[15:8],
            // byte2→[23:16], byte3→[31:24]. So first flash byte is [7:0].
            if (state == LOAD_WAIT && flash_readdatavalid && !sentinel_checked) begin
                sentinel_checked <= 1'b1;
                if (flash_readdata[7:0] == SENTINEL) begin
                    sentinel_ok <= 1'b1;
                    load_valid  <= 1'b1;
                end else begin
                    sentinel_ok <= 1'b0;
                    load_valid  <= 1'b0;
                end
            end
        end
    end

    // ----------------------------------------------------------------
    // Next-state logic
    // ----------------------------------------------------------------
    always_comb begin
        next = state;
        case (state)
            IDLE:
                if      (save_en) next = ERASE_SET_CMD;
                else if (load_en) next = LOAD_READ;

            // Erase via CSR — just the erase command, no WIP polling.
            // waitrequest handshake ensures the SPI command is transmitted.
            // Then blind-wait ERASE_WAIT_CYCLES for flash to erase internally.
            ERASE_SET_CMD:  if (!flash_csr_waitrequest) next = ERASE_SETTLE;
            ERASE_SETTLE:   next = ERASE_SET_ADDR;
            ERASE_SET_ADDR: if (!flash_csr_waitrequest) next = ERASE_FIRE;
            // Hold ERASE_FIRE until waitrequest drops = SPI erase cmd sent
            ERASE_FIRE:     if (!flash_csr_waitrequest) next = ERASE_WAIT;
            ERASE_WAIT:     if (erase_done) next = SAVE_WRITE;

            // avl_mem write — XIP controller internally does WREN+PP+poll.
            // waitrequest stays high until the entire per-byte sequence done.
            SAVE_WRITE: if (!flash_waitrequest) next = SAVE_NEXT;
            SAVE_NEXT: begin
                if (curr_fx == FX_COUNT-1 && curr_p == PARAM_COUNT-1)
                    next = IDLE;
                else
                    next = SAVE_WRITE;
            end

            // avl_mem read via XIP
            LOAD_READ:  if (!flash_waitrequest)    next = LOAD_WAIT;
            LOAD_WAIT:  if (flash_readdatavalid)   next = LOAD_STORE;
            LOAD_STORE: next = LOAD_NEXT;
            LOAD_NEXT: begin
                if (sentinel_checked && !sentinel_ok)
                    next = IDLE;
                else if (curr_fx == FX_COUNT-1 && curr_p == PARAM_COUNT-1)
                    next = IDLE;
                else
                    next = LOAD_READ;
            end

            default: next = IDLE;
        endcase
    end

    // ----------------------------------------------------------------
    // Output logic
    // ----------------------------------------------------------------
    always_comb begin
        flash_read          = 1'b0;
        flash_write         = 1'b0;
        flash_csr_read      = 1'b0;
        flash_csr_write     = 1'b0;
        flash_csr_addr      = 6'h0;
        flash_csr_writedata = 32'h0;
        ld_from_mem         = 1'b0;
        inc_idx             = 1'b0;
        rst_idx             = 1'b0;
        fsm_busy            = 1'b1;
        flash_addr          = word_addr;

        case (state)
            IDLE: begin
                fsm_busy = 1'b0;
                rst_idx  = 1'b1;
            end

            ERASE_SET_CMD: begin
                flash_csr_write     = 1'b1;
                flash_csr_addr      = CSR_CMD_SETTING;
                flash_csr_writedata = CMD_ERASE_SETTING;
            end
            ERASE_SET_ADDR: begin
                flash_csr_write     = 1'b1;
                flash_csr_addr      = CSR_CMD_ADDR;
                flash_csr_writedata = {9'b0, FLASH_BASE[22:0]};
            end
            ERASE_FIRE: begin
                flash_csr_write     = 1'b1;
                flash_csr_addr      = CSR_CMD_CONTROL;
                flash_csr_writedata = CMD_FIRE;
            end
            // ERASE_WAIT: no outputs, just counting

            SAVE_WRITE: flash_write = 1'b1;
            SAVE_NEXT:  inc_idx     = 1'b1;

            LOAD_READ:  flash_read  = 1'b1;
            LOAD_STORE: ld_from_mem = 1'b1;
            LOAD_NEXT:  inc_idx     = 1'b1;

            default: ;
        endcase
    end

endmodule