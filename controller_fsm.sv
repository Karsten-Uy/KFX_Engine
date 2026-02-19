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

    // avl_mem — reads AND writes
    input  logic        flash_waitrequest,
    input  logic        flash_readdatavalid,
    input  logic [31:0] flash_readdata,
    output logic [22:0] flash_addr,
    output logic        flash_read,
    output logic        flash_write,

    // avl_csr — sector erase only
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
    output logic        load_valid
);

    localparam CSR_CMD_SETTING = 6'd7;
    localparam CSR_CMD_CONTROL = 6'd8;
    localparam CSR_CMD_ADDR    = 6'd9;
    localparam CSR_CMD_RDDATA  = 6'd12;

    localparam CMD_ERASE_SETTING = 32'h000003D8;
    localparam CMD_RDSR_SETTING  = 32'h00001805;
    localparam CMD_FIRE          = 32'h00000001;

    // 27-bit counter max = 134M. Use 100_000_000 = 2 seconds @ 50MHz.
    // Real EPCQ256 64KB sector erase: 150ms typ, 2000ms max.
    localparam ERASE_TIMEOUT = 27'd100_000_000;

    // 23-bit counter max = 8.4M. Use 5_000_000 = 100ms per poll.
    localparam POLL_TIMEOUT  = 23'd5_000_000;

    localparam SENTINEL = 8'hA5;

    typedef enum logic [4:0] {
        IDLE            = 5'd0,
        ERASE_SET_CMD   = 5'd1,
        ERASE_SETTLE    = 5'd2,
        ERASE_SET_ADDR  = 5'd3,
        ERASE_FIRE      = 5'd4,
        ERASE_FIRED     = 5'd5,   // count ERASE_TIMEOUT cycles
        EPOLL_SET_CMD   = 5'd6,
        EPOLL_SETTLE    = 5'd7,
        EPOLL_FIRE      = 5'd8,
        EPOLL_FIRED     = 5'd9,   // wait !waitrequest or poll timeout
        EPOLL_READ      = 5'd10,
        EPOLL_READ_WAIT = 5'd11,
        EPOLL_CHECK     = 5'd12,
        SAVE_WRITE      = 5'd13,
        SAVE_NEXT       = 5'd14,
        LOAD_READ       = 5'd15,
        LOAD_WAIT       = 5'd16,
        LOAD_STORE      = 5'd17,
        LOAD_NEXT       = 5'd18
    } state_t;

    state_t state, next;
    assign fsm_state_debug = state[3:0];

    logic [22:0] word_addr;
    assign word_addr = FLASH_BASE[22:0] +
                       ((23'(curr_fx) * PARAM_COUNT + 23'(curr_p)) << 2);

    // ----------------------------------------------------------------
    // Erase timeout: 27-bit counter, target 100M cycles (2s @ 50MHz)
    // ----------------------------------------------------------------
    logic [26:0] erase_cnt;
    always_ff @(posedge clk) begin
        if (!rst_n || state != ERASE_FIRED)
            erase_cnt <= '0;
        else if (erase_cnt != ERASE_TIMEOUT)
            erase_cnt <= erase_cnt + 1'b1;
    end
    wire erase_done = (erase_cnt == ERASE_TIMEOUT);

    // ----------------------------------------------------------------
    // Poll timeout: 23-bit counter, target 5M cycles (100ms @ 50MHz)
    // Resets on every entry to EPOLL_FIRED
    // ----------------------------------------------------------------
    logic [22:0] poll_cnt;
    always_ff @(posedge clk) begin
        if (!rst_n || state != EPOLL_FIRED)
            poll_cnt <= '0;
        else if (poll_cnt != POLL_TIMEOUT)
            poll_cnt <= poll_cnt + 1'b1;
    end
    wire poll_timeout = (poll_cnt == POLL_TIMEOUT);

    // Latch avl_mem read data
    always_ff @(posedge clk) begin
        if (!rst_n)
            latched_readdata <= 32'hFFFFFFFF;
        else if (flash_readdatavalid)
            latched_readdata <= flash_readdata;
    end

    // Latch CSR read data
    logic [31:0] latched_csr_rddata;
    always_ff @(posedge clk) begin
        if (!rst_n)
            latched_csr_rddata <= 32'hFFFFFFFF;
        else if (flash_csr_readdatavalid)
            latched_csr_rddata <= flash_csr_readdata;
    end

    // ----------------------------------------------------------------
    // Sentinel: checked on the FIRST word read (slot [0][0])
    // load_valid only asserts after sentinel confirmed
    // ----------------------------------------------------------------
    logic sentinel_ok, sentinel_checked;

    always_ff @(posedge clk) begin
        if (!rst_n) state <= IDLE;
        else        state <= next;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sentinel_ok      <= 1'b0;
            sentinel_checked <= 1'b0;
            load_valid       <= 1'b0;
        end else if (state == IDLE) begin
            // Reset sentinel tracking at start of each operation
            sentinel_ok      <= 1'b0;
            sentinel_checked <= 1'b0;
            load_valid       <= 1'b0;  // clear load_valid each IDLE entry
        end else if (state == LOAD_WAIT && flash_readdatavalid && !sentinel_checked) begin
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

    // ----------------------------------------------------------------
    // Next-state logic
    // ----------------------------------------------------------------
    always_comb begin
        next = state;
        case (state)
            IDLE:
                if      (save_en) next = ERASE_SET_CMD;
                else if (load_en) next = LOAD_READ;

            ERASE_SET_CMD:   if (!flash_csr_waitrequest) next = ERASE_SETTLE;
            ERASE_SETTLE:    next = ERASE_SET_ADDR;
            ERASE_SET_ADDR:  if (!flash_csr_waitrequest) next = ERASE_FIRE;
            ERASE_FIRE:      if (!flash_csr_waitrequest) next = ERASE_FIRED;
            // Hold for exactly ERASE_TIMEOUT cycles regardless of waitrequest
            ERASE_FIRED:     if (erase_done) next = EPOLL_SET_CMD;

            EPOLL_SET_CMD:   if (!flash_csr_waitrequest) next = EPOLL_SETTLE;
            EPOLL_SETTLE:    next = EPOLL_FIRE;
            EPOLL_FIRE:      if (!flash_csr_waitrequest) next = EPOLL_FIRED;
            // Advance when waitrequest drops OR poll times out
            EPOLL_FIRED:     if (!flash_csr_waitrequest || poll_timeout) next = EPOLL_READ;
            EPOLL_READ:      if (!flash_csr_waitrequest) next = EPOLL_READ_WAIT;
            EPOLL_READ_WAIT: if (flash_csr_readdatavalid || poll_timeout) next = EPOLL_CHECK;
            // WIP bit0=1 means still busy. On poll timeout assume done (erase time already elapsed).
            EPOLL_CHECK:
                if (!poll_timeout && latched_csr_rddata[0])
                    next = EPOLL_SET_CMD;
                else
                    next = SAVE_WRITE;

            // avl_mem write: xip_controller internally runs STATUS→WREN→PP→POLL
            // mem_waitrequest stays high until the entire sequence completes
            SAVE_WRITE: if (!flash_waitrequest) next = SAVE_NEXT;
            SAVE_NEXT: begin
                if (curr_fx == FX_COUNT-1 && curr_p == PARAM_COUNT-1)
                    next = IDLE;
                else
                    next = SAVE_WRITE;
            end

            // avl_mem read
            LOAD_READ:  if (!flash_waitrequest)  next = LOAD_WAIT;
            LOAD_WAIT:  if (flash_readdatavalid) next = LOAD_STORE;
            // LOAD_STORE: apply data to params in controller, then advance
            LOAD_STORE: next = LOAD_NEXT;
            LOAD_NEXT: begin
                // Abort if first word wasn't sentinel (flash not programmed)
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

            EPOLL_SET_CMD: begin
                flash_csr_write     = 1'b1;
                flash_csr_addr      = CSR_CMD_SETTING;
                flash_csr_writedata = CMD_RDSR_SETTING;
            end

            EPOLL_FIRE: begin
                flash_csr_write     = 1'b1;
                flash_csr_addr      = CSR_CMD_CONTROL;
                flash_csr_writedata = CMD_FIRE;
            end

            EPOLL_READ: begin
                flash_csr_read = 1'b1;
                flash_csr_addr = CSR_CMD_RDDATA;
            end

            SAVE_WRITE: flash_write = 1'b1;
            SAVE_NEXT:  inc_idx     = 1'b1;

            LOAD_READ:  flash_read  = 1'b1;
            LOAD_STORE: ld_from_mem = 1'b1;
            LOAD_NEXT:  inc_idx     = 1'b1;

            default: ;
        endcase
    end

endmodule