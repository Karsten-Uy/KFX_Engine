/*
 * controller_fsm.sv
 *
 * Flash save / load state machine for the FX parameter store.
 *
 * Manages the full sequence of SPI flash operations needed to write or
 * read the complete all_params[][][] array (all BANK_COUNT banks) to/from
 * the EPCQ256 via the Intel Generic Serial Flash Interface IP.
 *
 * Flash address layout  (avl_mem uses 22-bit WORD addresses)
 * -----------------------------------------------------------
 *   avl_mem word address = byte address >> 2
 *
 *   SENTINEL_WORD              (slot 0)  → 0xA5 magic byte
 *   FIRST_PARAM_WORD + bank * FX_COUNT * PARAM_COUNT
 *                    + fx   * PARAM_COUNT
 *                    + p                → all_params[bank][fx][p]
 *
 *   Total parameter words = BANK_COUNT * FX_COUNT * PARAM_COUNT
 *                         = 4 * 16 * 8 = 512  (well within a 64 KB sector)
 *
 * Save sequence
 * -------------
 *   1. WREN via CSR.
 *   2. Sector-erase the target 64 KB sector via CSR.
 *   3. Wait ERASE_WAIT_CYCLES (~3.2 s worst case).
 *   4. Write every parameter byte for all banks sequentially to avl_mem.
 *   5. Write the 0xA5 sentinel to slot 0 LAST.
 *
 * Load sequence
 * -------------
 *   1. Read slot 0 — check for 0xA5 sentinel; abort if absent.
 *   2. Read each parameter byte for all banks; pulse ld_from_mem per byte.
 *
 * New port vs original
 * --------------------
 *   curr_bank  — current bank axis of the (bank, fx, p) loop index,
 *                driven by the parent controller's f_bank counter.
 *   All other ports are unchanged.
 */

module controller_fsm (
    input  logic clk,
    input  logic rst_n,
    input  logic save_en,
    input  logic load_en,
    input  logic [$clog2(BANK_COUNT)-1:0]  curr_bank,   // NEW: bank loop index
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

    localparam CSR_CMD_SETTING = 6'd7;
    localparam CSR_CMD_CONTROL = 6'd8;
    localparam CSR_CMD_ADDR    = 6'd9;

    localparam CMD_WREN_SETTING  = 32'h00000006;
    localparam CMD_ERASE_SETTING = 32'h000003D8;
    localparam CMD_FIRE          = 32'h00000001;

    localparam SENTINEL = 8'hA5;

    // EPCQ128A 64 KB sector erase worst-case ~3 s
    localparam ERASE_WAIT_CYCLES = 27'd160_000_000;

    // ----------------------------------------------------------------
    // Flash Address Layout
    // ----------------------------------------------------------------

    localparam [21:0] FLASH_BASE_WORD  = FLASH_BASE[23:2];
    localparam [21:0] SENTINEL_WORD    = FLASH_BASE_WORD;
    localparam [21:0] FIRST_PARAM_WORD = FLASH_BASE_WORD + 22'd1;

    // ----------------------------------------------------------------
    // State Encoding  (unchanged from original)
    // ----------------------------------------------------------------

    typedef enum logic [4:0] {
        IDLE            = 5'd0,
        ERASE_WREN_SET  = 5'd1,
        ERASE_WREN_FIRE = 5'd2,
        ERASE_SET_CMD   = 5'd3,
        ERASE_SET_ADDR  = 5'd4,
        ERASE_FIRE      = 5'd5,
        ERASE_WAIT      = 5'd6,
        SAVE_WRITE      = 5'd7,
        SAVE_HOLD       = 5'd8,
        SAVE_NEXT       = 5'd9,
        SAVE_SENTINEL   = 5'd10,
        SAVE_SEN_HOLD   = 5'd11,
        LOAD_SEN_READ   = 5'd12,
        LOAD_SEN_WAIT   = 5'd13,
        LOAD_READ       = 5'd14,
        LOAD_WAIT       = 5'd15,
        LOAD_STORE      = 5'd16,
        LOAD_NEXT       = 5'd17
    } state_t;

    state_t state, next;
    assign fsm_state_debug = state[3:0];

    // ----------------------------------------------------------------
    // Current Param Word Address
    // bank * FX_COUNT * PARAM_COUNT  +  fx * PARAM_COUNT  +  p
    // ----------------------------------------------------------------

    logic [21:0] param_word_addr;
    assign param_word_addr = FIRST_PARAM_WORD
                           + 22'(curr_bank) * 22'(FX_COUNT)  * 22'(PARAM_COUNT)
                           + 22'(curr_fx)   * 22'(PARAM_COUNT)
                           + 22'(curr_p);

    // ----------------------------------------------------------------
    // Loop-done flags
    // ----------------------------------------------------------------

    // True when all three indices are at their maximum values
    logic all_done;
    assign all_done = (curr_bank == BANK_COUNT - 1) &&
                      (curr_fx   == FX_COUNT   - 1) &&
                      (curr_p    == PARAM_COUNT - 1);

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
            if (state == IDLE) begin
                sentinel_ok <= 1'b0;
                load_valid  <= 1'b0;
            end
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

            ERASE_WREN_SET:  if (!flash_csr_waitrequest) next = ERASE_WREN_FIRE;
            ERASE_WREN_FIRE: if (!flash_csr_waitrequest) next = ERASE_SET_CMD;
            ERASE_SET_CMD:   if (!flash_csr_waitrequest) next = ERASE_SET_ADDR;
            ERASE_SET_ADDR:  if (!flash_csr_waitrequest) next = ERASE_FIRE;
            ERASE_FIRE:      if (!flash_csr_waitrequest) next = ERASE_WAIT;
            ERASE_WAIT:      if (erase_done)              next = SAVE_WRITE;

            SAVE_WRITE: if (!flash_waitrequest) next = SAVE_HOLD;
            SAVE_HOLD:                          next = SAVE_NEXT;
            SAVE_NEXT: begin
                // Advance to sentinel once all (bank, fx, p) combinations written
                if (all_done)
                    next = SAVE_SENTINEL;
                else
                    next = SAVE_WRITE;
            end
            SAVE_SENTINEL: if (!flash_waitrequest) next = SAVE_SEN_HOLD;
            SAVE_SEN_HOLD:                         next = IDLE;

            LOAD_SEN_READ: if (!flash_waitrequest) next = LOAD_SEN_WAIT;
            LOAD_SEN_WAIT: begin
                if (flash_readdatavalid) begin
                    if (flash_readdata[7:0] == SENTINEL)
                        next = LOAD_READ;
                    else
                        next = IDLE;
                end
            end
            LOAD_READ:  if (!flash_waitrequest)  next = LOAD_WAIT;
            LOAD_WAIT:  if (flash_readdatavalid) next = LOAD_STORE;
            LOAD_STORE:                          next = LOAD_NEXT;
            LOAD_NEXT: begin
                if (all_done)
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
        write_sentinel      = 1'b0;
        flash_addr          = param_word_addr;

        case (state)
            IDLE: begin
                fsm_busy = 1'b0;
                rst_idx  = 1'b1;
            end

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
                flash_csr_writedata = {8'b0, FLASH_BASE[23:0]};
            end
            ERASE_FIRE: begin
                flash_csr_write     = 1'b1;
                flash_csr_addr      = CSR_CMD_CONTROL;
                flash_csr_writedata = CMD_FIRE;
            end

            SAVE_WRITE: flash_write = 1'b1;
            SAVE_HOLD:  flash_write = 1'b1;
            SAVE_NEXT:  inc_idx     = 1'b1;

            SAVE_SENTINEL: begin
                flash_write    = 1'b1;
                flash_addr     = SENTINEL_WORD;
                write_sentinel = 1'b1;
            end
            SAVE_SEN_HOLD: begin
                flash_write    = 1'b1;
                flash_addr     = SENTINEL_WORD;
                write_sentinel = 1'b1;
            end

            LOAD_SEN_READ: begin
                flash_read = 1'b1;
                flash_addr = SENTINEL_WORD;
            end

            LOAD_READ:  flash_read  = 1'b1;
            LOAD_STORE: ld_from_mem = 1'b1;
            LOAD_NEXT:  inc_idx     = 1'b1;

            default: ;
        endcase
    end

endmodule