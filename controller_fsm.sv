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

    // ----------------------------------------------------------------
    // CSR register addresses
    // ----------------------------------------------------------------
    localparam CSR_CMD_SETTING = 6'd7;
    localparam CSR_CMD_CONTROL = 6'd8;
    localparam CSR_CMD_ADDR    = 6'd9;
    localparam CSR_CMD_RDDATA  = 6'd12;

    // CSR[7] Flash Command Setting format:
    //   [7:0]   opcode
    //   [10:8]  num address bytes (0=none, 3=three-byte)
    //   [11]    data dir: 0=write to flash, 1=read from flash
    //   [15:12] num data bytes
    //   [19:16] num dummy cycles
    localparam CMD_ERASE_SETTING = 32'h000003D8; // SE  D8h: 3 addr bytes, no data
    localparam CMD_RDSR_SETTING  = 32'h00001805; // RDSR 05h: no addr, 1 byte out
    localparam CMD_FIRE          = 32'h00000001;

    // Erase timeout: 300M cycles = 6 seconds at 50MHz
    // Real 64KB sector erase on EPCQ256 = max ~2s, so 6s is safe
    localparam ERASE_TIMEOUT = 28'd300_000_000;

    // RDSR poll timeout: 10M cycles = 200ms per poll attempt
    // Gives up and advances if CSR is not responding
    localparam POLL_TIMEOUT  = 24'd10_000_000;

    localparam SENTINEL = 8'hA5;

    typedef enum logic [4:0] {
        IDLE            = 5'd0,

        // Erase: write CSR command then wait fixed timeout
        ERASE_SET_CMD   = 5'd1,
        ERASE_SETTLE    = 5'd2,
        ERASE_SET_ADDR  = 5'd3,
        ERASE_FIRE      = 5'd4,
        ERASE_FIRED     = 5'd5,   // wait ERASE_TIMEOUT cycles unconditionally

        // WIP poll after erase
        EPOLL_SET_CMD   = 5'd6,
        EPOLL_SETTLE    = 5'd7,
        EPOLL_FIRE      = 5'd8,
        EPOLL_FIRED     = 5'd9,   // wait POLL_TIMEOUT or until !waitrequest
        EPOLL_READ      = 5'd10,
        EPOLL_READ_WAIT = 5'd11,
        EPOLL_CHECK     = 5'd12,

        // avl_mem writes (xip_controller handles WREN+PP+poll internally)
        SAVE_WRITE      = 5'd13,
        SAVE_NEXT       = 5'd14,

        // avl_mem reads
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
    // Erase timeout counter — counts up while in ERASE_FIRED
    // ----------------------------------------------------------------
    logic [27:0] erase_cnt;
    always_ff @(posedge clk) begin
        if (!rst_n || state != ERASE_FIRED)
            erase_cnt <= '0;
        else
            erase_cnt <= erase_cnt + 1'b1;
    end
    wire erase_done = (erase_cnt == ERASE_TIMEOUT);

    // ----------------------------------------------------------------
    // Poll timeout counter — counts up while in EPOLL_FIRED
    // Exits to EPOLL_READ even if CSR never asserts readdatavalid,
    // so we don't get permanently stuck if IP is unresponsive.
    // ----------------------------------------------------------------
    logic [23:0] poll_cnt;
    always_ff @(posedge clk) begin
        if (!rst_n || state != EPOLL_FIRED)
            poll_cnt <= '0;
        else
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
            sentinel_ok      <= 1'b0;
            sentinel_checked <= 1'b0;
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

            // Write CSR[7]: hold until accepted
            ERASE_SET_CMD:   if (!flash_csr_waitrequest) next = ERASE_SETTLE;
            // 1 idle cycle so CSR opcode regs settle
            ERASE_SETTLE:    next = ERASE_SET_ADDR;
            // Write CSR[9]: sector address
            ERASE_SET_ADDR:  if (!flash_csr_waitrequest) next = ERASE_FIRE;
            // Write CSR[8]=1: fire erase
            ERASE_FIRE:      if (!flash_csr_waitrequest) next = ERASE_FIRED;
            // Wait unconditionally for ERASE_TIMEOUT cycles (~6s)
            // This bypasses any waitrequest signalling uncertainty.
            // The EPCQ256 64KB sector erase takes 150ms typ, 2s max.
            ERASE_FIRED:     if (erase_done) next = EPOLL_SET_CMD;

            // Poll WIP to confirm erase complete before writing
            EPOLL_SET_CMD:   if (!flash_csr_waitrequest) next = EPOLL_SETTLE;
            EPOLL_SETTLE:    next = EPOLL_FIRE;
            EPOLL_FIRE:      if (!flash_csr_waitrequest) next = EPOLL_FIRED;
            // Wait for poll command to complete (timeout fallback if IP unresponsive)
            EPOLL_FIRED:     if (!flash_csr_waitrequest || poll_timeout) next = EPOLL_READ;
            // Read CSR[12] for status byte
            EPOLL_READ:      if (!flash_csr_waitrequest) next = EPOLL_READ_WAIT;
            EPOLL_READ_WAIT: if (flash_csr_readdatavalid || poll_timeout) next = EPOLL_CHECK;
            // bit0=WIP: 1=still erasing, 0=done
            // If poll timed out, latched_csr_rddata[0] may be stale —
            // after ERASE_TIMEOUT seconds the erase is definitely done,
            // so we treat timeout as done too.
            EPOLL_CHECK:
                if (!poll_timeout && latched_csr_rddata[0])
                    next = EPOLL_SET_CMD;   // WIP still set, keep polling
                else
                    next = SAVE_WRITE;      // done (or timed out = assume done)

            // avl_mem write: xip_controller does WREN+PP+poll internally
            SAVE_WRITE: if (!flash_waitrequest) next = SAVE_NEXT;
            SAVE_NEXT: begin
                if (curr_fx == FX_COUNT-1 && curr_p == PARAM_COUNT-1)
                    next = IDLE;
                else
                    next = SAVE_WRITE;
            end

            LOAD_READ:  if (!flash_waitrequest)  next = LOAD_WAIT;
            LOAD_WAIT:  if (flash_readdatavalid) next = LOAD_STORE;
            LOAD_STORE: next = LOAD_NEXT;
            LOAD_NEXT: begin
                if (!sentinel_ok && sentinel_checked)
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
            // ERASE_SETTLE: no outputs

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
            // ERASE_FIRED: no outputs, just counting

            EPOLL_SET_CMD: begin
                flash_csr_write     = 1'b1;
                flash_csr_addr      = CSR_CMD_SETTING;
                flash_csr_writedata = CMD_RDSR_SETTING;
            end
            // EPOLL_SETTLE: no outputs

            EPOLL_FIRE: begin
                flash_csr_write     = 1'b1;
                flash_csr_addr      = CSR_CMD_CONTROL;
                flash_csr_writedata = CMD_FIRE;
            end
            // EPOLL_FIRED: no outputs

            EPOLL_READ: begin
                flash_csr_read = 1'b1;
                flash_csr_addr = CSR_CMD_RDDATA;
            end
            // EPOLL_READ_WAIT, EPOLL_CHECK: no outputs

            SAVE_WRITE: flash_write = 1'b1;
            SAVE_NEXT:  inc_idx     = 1'b1;

            LOAD_READ:  flash_read  = 1'b1;
            LOAD_STORE: ld_from_mem = 1'b1;
            LOAD_NEXT:  inc_idx     = 1'b1;

            default: ;
        endcase
    end

endmodule