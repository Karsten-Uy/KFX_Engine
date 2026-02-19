
// module controller_fsm #(
//     parameter FX_COUNT    = 16,
//     parameter PARAM_COUNT = 8,
//     parameter FLASH_BASE  = 23'h400000
// ) (
//     input  logic clk,
//     input  logic rst_n,
//     input  logic save_en,
//     input  logic load_en,
//     input  logic [$clog2(FX_COUNT)-1:0]    curr_fx,
//     input  logic [$clog2(PARAM_COUNT)-1:0] curr_p,

//     // MEM port
//     input  logic        flash_waitrequest,
//     input  logic        flash_readdatavalid,
//     output logic [22:0] flash_addr,
//     output logic        flash_read,
//     output logic        flash_write,

//     // CSR port
//     input  logic        flash_csr_waitrequest,
//     input  logic [31:0] flash_csr_readdata,   // registered/buffered in controller.sv
//     output logic [5:0]  flash_csr_addr,
//     output logic        flash_csr_read,
//     output logic        flash_csr_write,
//     output logic [31:0] flash_csr_writedata,

//     output logic        ld_from_mem,
//     output logic        inc_idx,
//     output logic        rst_idx,
//     output logic        fsm_busy,
//     output logic [3:0]  fsm_state_debug,
//     output logic        load_valid
// );

//     // ----------------------------------------------------------------
//     // CSR Register Map — Intel Generic Serial Flash Interface IP
//     // Source: UG-20068, Table "CSR Register Map"
//     //
//     // Addr 0x00 : Read Status Register  (bit 0 = WIP, Read Only)
//     //             Read this to get live flash status after commands.
//     // Addr 0x01 : Command Register      (Write to issue flash commands)
//     //             Write format: [31:24] = opcode
//     //                           [23]    = address present flag (1 if cmd needs addr)
//     //                           [22:0]  = address (when bit 23 = 1)
//     //             For address-less commands (WREN): just write the opcode byte.
//     //             For addressed commands (erase):   pack opcode + addr together.
//     // Addr 0x02 : Read Data Register    (Read Only)
//     // Addr 0x03 : Chip Select Register
//     // ----------------------------------------------------------------

//     // CSR addresses
//     localparam CSR_ADDR_RDSR = 6'h00; // Read Status Register — WIP is bit 0
//     localparam CSR_ADDR_CMD  = 6'h01; // Command Register

//     // Command encodings for Command Register (addr 0x01):
//     //   WREN  : opcode only, no address needed
//     //   ERASE : opcode in [31:24], address-present flag in [23], address in [22:0]
//     localparam OPCODE_WREN   = 32'h00000006;               // Write Enable (0x06)
//     // 64KB block erase: bit23=1 signals address is present, [22:0] = sector address
//     localparam OPCODE_SE     = {8'hD8, 1'b1, FLASH_BASE};  // Erase at FLASH_BASE

//     localparam SENTINEL      = 8'hA5; // Magic byte written first to mark valid save

//     typedef enum logic [3:0] {
//         IDLE         = 4'd0,
//         // Save sequence
//         SAVE_WREN1   = 4'd1,  // Write Enable before erase
//         SAVE_ERASE   = 4'd2,  // Issue sector erase (opcode + address combined)
//         SAVE_POLL1   = 4'd3,  // Issue CSR read of status register (post-erase)
//         SAVE_POLL1_W = 4'd4,  // Wait 1 cycle for csr_data_reg to settle, check WIP
//         SAVE_WREN2   = 4'd5,  // Write Enable before each page program
//         SAVE_WRITE   = 4'd6,  // Write one word via MEM port
//         SAVE_POLL2   = 4'd7,  // Issue CSR read of status register (post-write)
//         SAVE_POLL2_W = 4'd8,  // Wait 1 cycle for csr_data_reg to settle, check WIP
//         SAVE_NEXT    = 4'd9,  // Advance index, loop back or finish
//         // Load sequence
//         LOAD_READ    = 4'd10,
//         LOAD_WAIT    = 4'd11,
//         LOAD_STORE   = 4'd12,
//         LOAD_NEXT    = 4'd13
//     } state_t;

//     state_t state, next;
//     assign fsm_state_debug = state[3:0];

//     // Sentinel check on first LOAD_STORE
//     logic sentinel_ok;
//     logic sentinel_checked;

//     always_ff @(posedge clk) begin
//         if (!rst_n) state <= IDLE;
//         else        state <= next;
//     end

//     always_ff @(posedge clk) begin
//         if (!rst_n) begin
//             sentinel_ok      <= 1'b0;
//             sentinel_checked <= 1'b0;
//             load_valid       <= 1'b0;
//         end else if (state == IDLE) begin
//             sentinel_ok      <= 1'b0;
//             sentinel_checked <= 1'b0;
//         end else if (state == LOAD_STORE && !sentinel_checked) begin
//             sentinel_checked <= 1'b1;
//             if (flash_csr_readdata[7:0] == SENTINEL) begin
//                 sentinel_ok <= 1'b1;
//                 load_valid  <= 1'b1;
//             end else begin
//                 sentinel_ok <= 1'b0;
//                 load_valid  <= 1'b0;
//             end
//         end
//     end

//     // ----------------------------------------------------------------
//     // Next-state logic
//     // ----------------------------------------------------------------
//     always_comb begin
//         next = state;
//         case (state)
//             IDLE: begin
//                 if      (save_en) next = SAVE_WREN1;
//                 else if (load_en) next = LOAD_READ;
//             end

//             // Write Enable accepted → issue erase
//             SAVE_WREN1:   if (!flash_csr_waitrequest) next = SAVE_ERASE;

//             // Erase command accepted → start polling
//             SAVE_ERASE:   if (!flash_csr_waitrequest) next = SAVE_POLL1;

//             // Read issued → move to wait state once accepted
//             SAVE_POLL1:   if (!flash_csr_waitrequest) next = SAVE_POLL1_W;

//             // csr_data_reg now settled — check WIP bit 0
//             // 1 = erase still in progress, 0 = done
//             SAVE_POLL1_W: begin
//                 if (flash_csr_readdata[0]) next = SAVE_POLL1; // re-issue read
//                 else                       next = SAVE_WREN2;
//             end

//             SAVE_WREN2:   if (!flash_csr_waitrequest) next = SAVE_WRITE;
//             SAVE_WRITE:   if (!flash_waitrequest)     next = SAVE_POLL2;

//             // Same two-step poll pattern for post-write
//             SAVE_POLL2:   if (!flash_csr_waitrequest) next = SAVE_POLL2_W;

//             SAVE_POLL2_W: begin
//                 if (flash_csr_readdata[0]) next = SAVE_POLL2; // re-issue read
//                 else                       next = SAVE_NEXT;
//             end

//             SAVE_NEXT: begin
//                 if (curr_fx == FX_COUNT-1 && curr_p == PARAM_COUNT-1)
//                     next = IDLE;
//                 else
//                     next = SAVE_WREN2; // WREN required before every page program
//             end

//             // Load
//             LOAD_READ:  if (!flash_waitrequest)  next = LOAD_WAIT;
//             LOAD_WAIT:  if (flash_readdatavalid) next = LOAD_STORE;
//             LOAD_STORE: next = LOAD_NEXT;

//             LOAD_NEXT: begin
//                 if (!sentinel_ok && sentinel_checked)
//                     next = IDLE; // bad sentinel, abort, keep defaults
//                 else if (curr_fx == FX_COUNT-1 && curr_p == PARAM_COUNT-1)
//                     next = IDLE;
//                 else
//                     next = LOAD_READ;
//             end

//             default: next = IDLE;
//         endcase
//     end

//     // ----------------------------------------------------------------
//     // Output logic
//     // ----------------------------------------------------------------
//     always_comb begin
//         flash_read          = 1'b0;
//         flash_write         = 1'b0;
//         flash_csr_read      = 1'b0;
//         flash_csr_write     = 1'b0;
//         flash_csr_addr      = 6'h00;
//         flash_csr_writedata = 32'h0;
//         ld_from_mem         = 1'b0;
//         inc_idx             = 1'b0;
//         rst_idx             = 1'b0;
//         fsm_busy            = 1'b1;

//         flash_addr = FLASH_BASE[22:0] +
//                      ((23'(curr_fx) * PARAM_COUNT + 23'(curr_p)) << 2);

//         case (state)
//             IDLE: begin
//                 fsm_busy = 1'b0;
//                 rst_idx  = 1'b1;
//             end

//             // Write Enable: opcode-only command, no address
//             SAVE_WREN1,
//             SAVE_WREN2: begin
//                 flash_csr_write     = 1'b1;
//                 flash_csr_addr      = CSR_ADDR_CMD;
//                 flash_csr_writedata = OPCODE_WREN;
//             end

//             // Sector Erase: opcode [31:24] + address-present flag [23] + address [22:0]
//             // The IP extracts the opcode and address and issues the full SPI sequence.
//             SAVE_ERASE: begin
//                 flash_csr_write     = 1'b1;
//                 flash_csr_addr      = CSR_ADDR_CMD;
//                 flash_csr_writedata = OPCODE_SE;
//             end

//             // Poll: read Status Register (addr 0x00), WIP = bit 0
//             // Transition to _W state once read is accepted (waitrequest low)
//             SAVE_POLL1,
//             SAVE_POLL2: begin
//                 flash_csr_read = 1'b1;
//                 flash_csr_addr = CSR_ADDR_RDSR;
//             end

//             // _W states: nothing driven, next-state checks settled csr_data_reg[0]
//             SAVE_POLL1_W,
//             SAVE_POLL2_W: ;

//             SAVE_WRITE: flash_write = 1'b1;
//             SAVE_NEXT:  inc_idx     = 1'b1;

//             LOAD_READ:  flash_read  = 1'b1;
//             LOAD_STORE: ld_from_mem = 1'b1;
//             LOAD_NEXT:  inc_idx     = 1'b1;

//             default: ;
//         endcase
//     end

// endmodule


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

    // avl_mem port — the ONLY port used for actual flash reads/writes.
    // The IP handles erase, WREN, and SPI protocol internally.
    // avl_csr is NOT used for commands — only for IP configuration
    // (baud rate, opcodes etc.) which are already set by IP defaults.
    input  logic        flash_waitrequest,
    input  logic        flash_readdatavalid,
    output logic [22:0] flash_addr,
    output logic        flash_read,
    output logic        flash_write,

    // avl_csr port — wired up but only used to read status if needed.
    // We do NOT write commands through CSR. Tie off outputs to safe values.
    input  logic        flash_csr_waitrequest,
    input  logic [31:0] flash_csr_readdata,
    output logic [5:0]  flash_csr_addr,
    output logic        flash_csr_read,
    output logic        flash_csr_write,
    output logic [31:0] flash_csr_writedata,

    output logic        ld_from_mem,
    output logic        inc_idx,
    output logic        rst_idx,
    output logic        fsm_busy,
    output logic [3:0]  fsm_state_debug,
    output logic        load_valid
);

    // ----------------------------------------------------------------
    // How this IP actually works (from generated source analysis):
    //
    // The intel_generic_serial_flash_interface IP exposes two Avalon ports:
    //
    //   avl_mem  — memory-mapped access to flash contents.
    //              Write here to program flash, read here to read flash.
    //              The IP internally handles: WREN, erase (sector or page),
    //              Page Program, Read — all SPI sequencing is automatic.
    //              You just present an address + data and toggle read/write.
    //
    //   avl_csr  — configuration registers (baud rate, opcodes, timing).
    //              These are pre-configured via DEFAULT_VALUE_REG_* params
    //              at synthesis time. You do NOT send erase commands here.
    //              Do NOT write to CSR during normal operation.
    //
    // Therefore: our FSM only needs to drive avl_mem reads and writes.
    // No WREN states, no erase states, no CSR polling — the IP does it all.
    //
    // Flash layout (word-addressed, 4 bytes per word):
    //   FLASH_BASE + 0x00 : SENTINEL (0xA5) — marks valid save data
    //   FLASH_BASE + 0x04 : params[0][0]
    //   FLASH_BASE + 0x08 : params[0][1]
    //   ...
    //   FLASH_BASE + 4*(FX_COUNT*PARAM_COUNT) : last param
    //
    // Write timing: after asserting write+addr+data, hold until
    // waitrequest deasserts. The IP may hold waitrequest for many cycles
    // while it performs the internal erase+program sequence.
    // ----------------------------------------------------------------

    localparam SENTINEL = 8'hA5;

    typedef enum logic [3:0] {
        IDLE       = 4'd0,
        // Save
        SAVE_WRITE = 4'd1,  // Assert write, hold until waitrequest=0
        SAVE_NEXT  = 4'd2,  // Advance index
        // Load
        LOAD_READ  = 4'd3,  // Assert read, hold until waitrequest=0
        LOAD_WAIT  = 4'd4,  // Wait for readdatavalid
        LOAD_STORE = 4'd5,  // Latch data into params for one cycle
        LOAD_NEXT  = 4'd6   // Advance index or finish
    } state_t;

    state_t state, next;
    assign fsm_state_debug = state[3:0];

    // Sentinel tracking
    logic sentinel_ok;
    logic sentinel_checked;

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
        end else if (state == LOAD_STORE && !sentinel_checked) begin
            // First word read back must be SENTINEL
            sentinel_checked <= 1'b1;
            if (flash_csr_readdata[7:0] == SENTINEL) begin
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
            IDLE: begin
                if      (save_en) next = SAVE_WRITE;
                else if (load_en) next = LOAD_READ;
            end

            // Hold write asserted until IP accepts it (waitrequest=0)
            // The IP will internally handle erase + page program.
            // waitrequest may be held HIGH for tens of thousands of cycles
            // during the erase — this is normal and correct behaviour.
            SAVE_WRITE: if (!flash_waitrequest) next = SAVE_NEXT;

            SAVE_NEXT: begin
                if (curr_fx == FX_COUNT-1 && curr_p == PARAM_COUNT-1)
                    next = IDLE;
                else
                    next = SAVE_WRITE;
            end

            // Hold read asserted until IP accepts it
            LOAD_READ:  if (!flash_waitrequest)  next = LOAD_WAIT;

            // Wait for read data to come back (pipelined, may be several cycles)
            LOAD_WAIT:  if (flash_readdatavalid) next = LOAD_STORE;

            // One cycle to latch into params
            LOAD_STORE: next = LOAD_NEXT;

            LOAD_NEXT: begin
                if (!sentinel_ok && sentinel_checked)
                    next = IDLE; // No valid save found, keep hardcoded defaults
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
        ld_from_mem         = 1'b0;
        inc_idx             = 1'b0;
        rst_idx             = 1'b0;
        fsm_busy            = 1'b1;

        // CSR outputs: never write, never read during operation
        flash_csr_read      = 1'b0;
        flash_csr_write     = 1'b0;
        flash_csr_addr      = 6'h0;
        flash_csr_writedata = 32'h0;

        // Word address: sentinel at FLASH_BASE, params offset by 1 word each
        flash_addr = FLASH_BASE[22:0] +
                     ((23'(curr_fx) * PARAM_COUNT + 23'(curr_p)) << 2);

        case (state)
            IDLE: begin
                fsm_busy = 1'b0;
                rst_idx  = 1'b1;
            end

            // Keep write asserted the entire time waitrequest is high.
            // IP deasserts waitrequest only when it has accepted the transaction
            // (after completing any internal erase+program sequence).
            SAVE_WRITE: flash_write = 1'b1;
            SAVE_NEXT:  inc_idx     = 1'b1;

            LOAD_READ:  flash_read  = 1'b1;
            LOAD_STORE: ld_from_mem = 1'b1;
            LOAD_NEXT:  inc_idx     = 1'b1;

            default: ;
        endcase
    end

endmodule

