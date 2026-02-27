/*
 * controller_fsm.sv
 *
 * Flash save / load state machine for the FX parameter store.
 *
 * Manages the full sequence of SPI flash operations needed to write or
 * read the complete params[][] array to/from the EPCQ256 via the Intel
 * Generic Serial Flash Interface IP (two Avalon-MM buses: avl_mem for
 * data reads/writes, avl_csr for command/erase control).
 *
 * Save sequence
 * -------------
 *   1. Issue WREN via CSR (erase does NOT auto-issue WREN).
 *   2. Send a sector-erase command for the target 64 KB sector via CSR.
 *   3. Wait ERASE_WAIT_CYCLES for the erase to complete (~3.2 s worst case).
 *   4. Write every parameter byte sequentially to avl_mem.
 *   5. Write the 0xA5 sentinel to slot 0 LAST — a valid sentinel guarantees
 *      all params were written successfully.
 *
 * Load sequence
 * -------------
 *   1. Read slot 0 and check for the 0xA5 sentinel.
 *      If absent, abort immediately; load_valid is left low.
 *   2. Read each parameter byte sequentially and pulse ld_from_mem so the
 *      parent controller can write it into params[][].
 *
 * Flash address layout  (avl_mem uses 22-bit WORD addresses)
 * -----------------------------------------------------------
 *   avl_mem word address = byte address >> 2  (the IP shifts left by 2 internally)
 *   FLASH_BASE_WORD + 0         → sentinel (0xA5)
 *   FLASH_BASE_WORD + 1         → params[0][0]
 *   ...
 *   FLASH_BASE_WORD + fx*P + p  → params[fx][p]
 *
 * Ports
 * -----
 *   save_en / load_en  — single-cycle request pulses from controller
 *   curr_fx / curr_p   — loop index driven by the parent's index counters
 *   latched_readdata   — last avl_mem read word, held for parent to sample
 *   ld_from_mem        — single-cycle pulse: write latched_readdata into params
 *   inc_idx            — pulse: advance the (curr_fx, curr_p) loop index
 *   rst_idx            — pulse: reset the loop index to (0, 0)
 *   fsm_busy           — high whenever the FSM is not in IDLE
 *   load_valid         — high if the last load found a valid sentinel
 *   write_sentinel     — high while the FSM is writing 0xA5 (not a param byte)
 */

module controller_fsm (
    input  logic clk,
    input  logic rst_n,
    input  logic save_en,
    input  logic load_en,
    input  logic [$clog2(FX_COUNT)-1:0]    curr_fx,
    input  logic [$clog2(PARAM_COUNT)-1:0] curr_p,

    // avl_mem — data reads and writes
    input  logic        flash_waitrequest,
    input  logic        flash_readdatavalid,
    input  logic [31:0] flash_readdata,
    output logic [21:0] flash_addr,
    output logic        flash_read,
    output logic        flash_write,

    // avl_csr — WREN and sector-erase commands
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
    output logic        write_sentinel
);

    import lab_pkg::*;

    // ----------------------------------------------------------------
    // CSR Register Map
    // ----------------------------------------------------------------

    localparam CSR_CMD_SETTING = 6'd7;  // command opcode register
    localparam CSR_CMD_CONTROL = 6'd8;  // command fire / status register
    localparam CSR_CMD_ADDR    = 6'd9;  // command address register

    localparam CMD_WREN_SETTING  = 32'h00000006;  // opcode 06h (WREN), no address
    localparam CMD_ERASE_SETTING = 32'h000003D8;  // opcode D8h (sector erase), 3-byte addr
    localparam CMD_FIRE          = 32'h00000001;  // write to CSR_CMD_CONTROL to execute

    localparam SENTINEL = 8'hA5;  // magic byte written last on save; checked first on load

    // EPCQ128A 64 KB sector erase worst-case ~3 s; 160 M cycles @ 50 MHz = 3.2 s
    localparam ERASE_WAIT_CYCLES = 27'd160_000_000;

    // ----------------------------------------------------------------
    // Flash Address Layout
    // ----------------------------------------------------------------

    // avl_mem takes 22-bit WORD addresses; xip_addr_adaption shifts left
    // by 2 internally to produce the SPI byte address.
    //   word_addr = byte_addr >> 2
    localparam [21:0] FLASH_BASE_WORD  = FLASH_BASE[23:2];
    localparam [21:0] SENTINEL_WORD    = FLASH_BASE_WORD;           // slot 0
    localparam [21:0] FIRST_PARAM_WORD = FLASH_BASE_WORD + 22'd1;  // slot 1

    // ----------------------------------------------------------------
    // State Encoding
    // ----------------------------------------------------------------

    typedef enum logic [4:0] {
        IDLE            = 5'd0,

        // WREN + erase  (WREN must be issued manually before sector erase)
        ERASE_WREN_SET  = 5'd1,   // write CMD_SETTING = WREN opcode
        ERASE_WREN_FIRE = 5'd2,   // fire WREN via CMD_CONTROL
        ERASE_SET_CMD   = 5'd3,   // write CMD_SETTING = sector-erase opcode
        ERASE_SET_ADDR  = 5'd4,   // write CMD_ADDR = sector byte address
        ERASE_FIRE      = 5'd5,   // fire erase command
        ERASE_WAIT      = 5'd6,   // fixed-time wait for erase completion

        // Save: write all params, then write sentinel last
        SAVE_WRITE      = 5'd7,   // assert write, wait for !waitrequest
        SAVE_HOLD       = 5'd8,   // hold write one extra cycle (XIP pipeline flush)
        SAVE_NEXT       = 5'd9,   // de-assert write, increment loop index
        SAVE_SENTINEL   = 5'd10,  // write 0xA5 sentinel to slot 0
        SAVE_SEN_HOLD   = 5'd11,  // hold sentinel write one extra cycle

        // Load: validate sentinel, then read all params
        LOAD_SEN_READ   = 5'd12,  // issue read of slot 0
        LOAD_SEN_WAIT   = 5'd13,  // wait for readdatavalid, check sentinel
        LOAD_READ       = 5'd14,  // issue read of current param slot
        LOAD_WAIT       = 5'd15,  // wait for readdatavalid
        LOAD_STORE      = 5'd16,  // pulse ld_from_mem to commit byte to params
        LOAD_NEXT       = 5'd17   // increment loop index; loop or finish
    } state_t;

    state_t state, next;
    assign fsm_state_debug = state[3:0];

    // ----------------------------------------------------------------
    // Current Param Word Address  (combinational from loop index)
    // ----------------------------------------------------------------

    logic [21:0] param_word_addr;
    assign param_word_addr = FIRST_PARAM_WORD
                           + 22'(curr_fx) * 22'(PARAM_COUNT)
                           + 22'(curr_p);

    // ----------------------------------------------------------------
    // Erase Wait Counter
    // ----------------------------------------------------------------

    logic [26:0] erase_cnt;

    always_ff @(posedge clk) begin
        if (!rst_n || state != ERASE_WAIT)
            erase_cnt <= '0;
        else if (erase_cnt != ERASE_WAIT_CYCLES)
            erase_cnt <= erase_cnt + 1'b1;
    end

    logic erase_done;
    assign erase_done = (erase_cnt == ERASE_WAIT_CYCLES);

    // ----------------------------------------------------------------
    // Read Data Latch
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!rst_n)
            latched_readdata <= 32'hFFFFFFFF;
        else if (flash_readdatavalid)
            latched_readdata <= flash_readdata;
    end

    // ----------------------------------------------------------------
    // Sentinel / load_valid Tracking
    // ----------------------------------------------------------------

    logic sentinel_ok;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sentinel_ok <= 1'b0;
            load_valid  <= 1'b0;
        end else begin
            // Clear on every new operation
            if (state == IDLE) begin
                sentinel_ok <= 1'b0;
                load_valid  <= 1'b0;
            end
            // Latch result when sentinel read returns
            if (state == LOAD_SEN_WAIT && flash_readdatavalid) begin
                sentinel_ok <= (flash_readdata[7:0] == SENTINEL);
                load_valid  <= (flash_readdata[7:0] == SENTINEL);
            end
        end
    end

    // ----------------------------------------------------------------
    // State Register
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!rst_n) state <= IDLE;
        else        state <= next;
    end

    // ----------------------------------------------------------------
    // Next-State Logic
    // ----------------------------------------------------------------

    always_comb begin
        next = state;
        case (state)
            IDLE:
                if      (save_en) next = ERASE_WREN_SET;
                else if (load_en) next = LOAD_SEN_READ;

            // WREN + Erase
            ERASE_WREN_SET:  if (!flash_csr_waitrequest) next = ERASE_WREN_FIRE;
            ERASE_WREN_FIRE: if (!flash_csr_waitrequest) next = ERASE_SET_CMD;
            ERASE_SET_CMD:   if (!flash_csr_waitrequest) next = ERASE_SET_ADDR;
            ERASE_SET_ADDR:  if (!flash_csr_waitrequest) next = ERASE_FIRE;
            ERASE_FIRE:      if (!flash_csr_waitrequest) next = ERASE_WAIT;
            ERASE_WAIT:      if (erase_done)              next = SAVE_WRITE;

            // Save
            SAVE_WRITE: if (!flash_waitrequest) next = SAVE_HOLD;
            SAVE_HOLD:                          next = SAVE_NEXT;
            SAVE_NEXT: begin
                if (curr_fx == FX_COUNT - 1 && curr_p == PARAM_COUNT - 1)
                    next = SAVE_SENTINEL;
                else
                    next = SAVE_WRITE;
            end
            SAVE_SENTINEL: if (!flash_waitrequest) next = SAVE_SEN_HOLD;
            SAVE_SEN_HOLD:                         next = IDLE;

            // Load
            LOAD_SEN_READ: if (!flash_waitrequest) next = LOAD_SEN_WAIT;
            LOAD_SEN_WAIT: begin
                if (flash_readdatavalid) begin
                    if (flash_readdata[7:0] == SENTINEL)
                        next = LOAD_READ;
                    else
                        next = IDLE;  // no valid save data found
                end
            end
            LOAD_READ:  if (!flash_waitrequest)  next = LOAD_WAIT;
            LOAD_WAIT:  if (flash_readdatavalid) next = LOAD_STORE;
            LOAD_STORE:                          next = LOAD_NEXT;
            LOAD_NEXT: begin
                if (curr_fx == FX_COUNT - 1 && curr_p == PARAM_COUNT - 1)
                    next = IDLE;
                else
                    next = LOAD_READ;
            end

            default: next = IDLE;
        endcase
    end

    // ----------------------------------------------------------------
    // Output Logic
    // ----------------------------------------------------------------

    always_comb begin
        // Safe defaults — all bus signals de-asserted
        flash_read          = 1'b0;
        flash_write         = 1'b0;
        flash_csr_read      = 1'b0;
        flash_csr_write     = 1'b0;
        flash_csr_addr      = 6'h0;
        flash_csr_writedata = 32'h0;
        ld_from_mem         = 1'b0;
        inc_idx             = 1'b0;
        rst_idx             = 1'b0;
        fsm_busy            = 1'b1;  // busy in every state except IDLE
        write_sentinel      = 1'b0;
        flash_addr          = param_word_addr;  // default address follows loop index

        case (state)
            IDLE: begin
                fsm_busy = 1'b0;
                rst_idx  = 1'b1;   // keep index at 0 while idle
            end

            // ---- WREN + Erase CSR commands ----
            ERASE_WREN_SET: begin
                flash_csr_write     = 1'b1;
                flash_csr_addr      = CSR_CMD_SETTING;
                flash_csr_writedata = CMD_WREN_SETTING;
            end
            ERASE_WREN_FIRE: begin
                flash_csr_write     = 1'b1;
                flash_csr_addr      = CSR_CMD_CONTROL;
                flash_csr_writedata = CMD_FIRE;
            end
            ERASE_SET_CMD: begin
                flash_csr_write     = 1'b1;
                flash_csr_addr      = CSR_CMD_SETTING;
                flash_csr_writedata = CMD_ERASE_SETTING;
            end
            ERASE_SET_ADDR: begin
                flash_csr_write     = 1'b1;
                flash_csr_addr      = CSR_CMD_ADDR;
                flash_csr_writedata = {8'b0, FLASH_BASE[23:0]};  // byte address, zero-extended
            end
            ERASE_FIRE: begin
                flash_csr_write     = 1'b1;
                flash_csr_addr      = CSR_CMD_CONTROL;
                flash_csr_writedata = CMD_FIRE;
            end

            // ---- Save data writes ----
            SAVE_WRITE: flash_write = 1'b1;
            SAVE_HOLD:  flash_write = 1'b1;  // hold for XIP pipeline flush
            SAVE_NEXT:  inc_idx     = 1'b1;

            SAVE_SENTINEL: begin
                flash_write    = 1'b1;
                flash_addr     = SENTINEL_WORD;
                write_sentinel = 1'b1;
            end
            SAVE_SEN_HOLD: begin
                flash_write    = 1'b1;
                flash_addr     = SENTINEL_WORD;
                write_sentinel = 1'b1;  // hold for XIP pipeline flush
            end

            // ---- Load sentinel check ----
            LOAD_SEN_READ: begin
                flash_read = 1'b1;
                flash_addr = SENTINEL_WORD;
            end

            // ---- Load param reads ----
            LOAD_READ:  flash_read  = 1'b1;
            LOAD_STORE: ld_from_mem = 1'b1;  // one-cycle write-enable to params[][]
            LOAD_NEXT:  inc_idx     = 1'b1;

            default: ;
        endcase
    end

endmodule