/*
 * host_if.sv
 *
 * Command parser / responder for the PC host interface.  Sits between the byte
 * stream from jtag_uart_adapter and the controller's all_params store.  Emits
 * single-cycle control pulses that slot into the controller's existing
 * all_params writer, and serializes responses back to the host.
 *
 * Request frame (PC -> FPGA), FIXED 7 bytes:
 *     [0x5A][OPCODE][ARG0][ARG1][ARG2][ARG3][CHK]
 *     CHK = OPCODE ^ ARG0 ^ ARG1 ^ ARG2 ^ ARG3      (unused args sent as 0)
 *
 * Response frames (FPGA -> PC), all prefixed 0xA5; the 2nd byte disambiguates:
 *     ACK  : [0xA5][0x00]
 *     NACK : [0xA5][err]          err 01=checksum 02=opcode 03=busy 04=read-only
 *     READ : [0xA5][0x10][bank][fx][param][value][chk]
 *     BANK : [0xA5][0x11][bank][chk]                    chk = 0x11 ^ bank
 *     DUMP : [0xA5][0x20][0x02][0x00] + 512 value bytes + [chk]
 *     PONG : [0xA5][0xF0][VER_MAJ][VER_MIN][chk]
 *
 * Opcodes:
 *   0x01 WRITE  A0=bank A1=fx A2=param A3=value
 *   0x10 READ   A0=bank A1=fx A2=param
 *   0x11 GBNK   (no args)                           (get current/live bank -> BANK)
 *   0x20 DUMP   (no args)
 *   0x30 RESET  A0=scope(0=param 1=fx 2=bank 3=all) A1=bank A2=fx A3=param
 *   0x40 RDEF   A0=bank A1=fx A2=param            (read factory default, no write)
 *   0x50 SAVE   (no args)
 *   0x51 LOAD   (no args)
 *   0xF0 PING   (no args)
 *
 * FX7[0] (expression/pot) is read-only -> WRITE returns NACK 0x04.
 * WRITE/RESET/SAVE/LOAD while fsm_busy -> NACK 0x03.  FX15 mirroring across
 * banks is handled in the controller, not here.
 */
module host_if import lab_pkg::*; (
    input  logic clk,
    input  logic reset_n,

    // ---- Byte stream from/to jtag_uart_adapter ----
    input  logic [7:0] rx_data,
    input  logic       rx_valid,
    output logic       rx_ready,
    output logic [7:0] tx_data,
    output logic       tx_valid,
    input  logic       tx_ready,

    // ---- Control outputs to the controller ----
    output logic                           host_wr_en,
    output logic [$clog2(BANK_COUNT)-1:0]  host_bank,
    output logic [$clog2(FX_COUNT)-1:0]    host_fx,
    output logic [$clog2(PARAM_COUNT)-1:0] host_param,
    output logic [PARAM_W-1:0]             host_data,
    output logic                           host_rst_en,
    output logic [1:0]                     host_rst_scope,
    output logic                           host_save_pulse,
    output logic                           host_load_pulse,

    // ---- Readback inputs from the controller (combinational on host_*) ----
    input  logic [PARAM_W-1:0]             host_rd_value,       // all_params[host_bank][host_fx][host_param]
    input  logic [PARAM_W-1:0]             host_default_value,  // param_default(host_bank,host_fx,host_param)

    // ---- Live bank from the controller (for the GBNK query) ----
    input  logic [$clog2(BANK_COUNT)-1:0]  bank_sel,

    input  logic                           fsm_busy
);

    localparam int BW = $clog2(BANK_COUNT);
    localparam int FW = $clog2(FX_COUNT);
    localparam int PW = $clog2(PARAM_COUNT);

    // Protocol constants
    localparam logic [7:0] REQ_SYNC = 8'h5A;
    localparam logic [7:0] RSP_SYNC = 8'hA5;
    localparam logic [7:0] OP_WRITE = 8'h01,
                           OP_READ  = 8'h10,
                           OP_GBNK  = 8'h11,
                           OP_DUMP  = 8'h20,
                           OP_RESET = 8'h30,
                           OP_RDEF  = 8'h40,
                           OP_SAVE  = 8'h50,
                           OP_LOAD  = 8'h51,
                           OP_PING  = 8'hF0;
    localparam logic [7:0] ST_OK    = 8'h00,
                           ERR_CHK  = 8'h01,
                           ERR_OP   = 8'h02,
                           ERR_BUSY = 8'h03,
                           ERR_RO   = 8'h04;
    localparam logic [7:0] VER_MAJ  = 8'h01,
                           VER_MIN  = 8'h00;

    typedef enum logic [3:0] {
        S_SYNC, S_OP, S_ARGS, S_CHK, S_EXEC, S_RWAIT, S_BUF,
        S_DHDR, S_DADDR, S_DDATA, S_DCHK
    } st_t;

    st_t        st;
    logic [7:0] opcode;
    logic [7:0] arg [0:3];
    logic [1:0] argi;
    logic [7:0] chk_acc;
    logic       use_default;

    // Short-response buffer (max 7 bytes: READ frame)
    logic [7:0] rsp [0:6];
    logic [2:0] rsp_len, rsp_idx;

    // DUMP state
    logic [BW-1:0] wbank;
    logic [FW-1:0] wfx;
    logic [PW-1:0] wparam;
    logic [9:0]    dcount;     // 0..511
    logic [7:0]    dchk;
    logic [1:0]    dhdr_idx;   // 0..3 header bytes

    // ----------------------------------------------------------------
    // Receive-ready and transmit-data are combinational on state
    // ----------------------------------------------------------------
    assign rx_ready = (st == S_SYNC) || (st == S_OP) || (st == S_ARGS) || (st == S_CHK);

    always_comb begin
        tx_valid = 1'b0;
        tx_data  = 8'h00;
        case (st)
            S_BUF: begin
                tx_valid = 1'b1;
                tx_data  = rsp[rsp_idx];
            end
            S_DHDR: begin
                tx_valid = 1'b1;
                case (dhdr_idx)
                    2'd0:    tx_data = RSP_SYNC;
                    2'd1:    tx_data = OP_DUMP;
                    2'd2:    tx_data = 8'h02;   // length hi (512 = 0x0200)
                    default: tx_data = 8'h00;   // length lo
                endcase
            end
            S_DDATA: begin
                tx_valid = 1'b1;
                tx_data  = host_rd_value;
            end
            S_DCHK: begin
                tx_valid = 1'b1;
                tx_data  = dchk;
            end
            default: ;
        endcase
    end

    // ----------------------------------------------------------------
    // Main FSM
    // ----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            st              <= S_SYNC;
            argi            <= 2'd0;
            rsp_idx         <= 3'd0;
            rsp_len         <= 3'd0;
            host_wr_en      <= 1'b0;
            host_rst_en     <= 1'b0;
            host_save_pulse <= 1'b0;
            host_load_pulse <= 1'b0;
            host_bank       <= '0;
            host_fx         <= '0;
            host_param      <= '0;
            host_data       <= '0;
            host_rst_scope  <= 2'd0;
            use_default     <= 1'b0;
        end else begin
            // single-cycle pulses default low
            host_wr_en      <= 1'b0;
            host_rst_en     <= 1'b0;
            host_save_pulse <= 1'b0;
            host_load_pulse <= 1'b0;

            case (st)
                // ---- Receive a 7-byte request ----
                S_SYNC: begin
                    rsp_idx <= 3'd0;
                    if (rx_valid && rx_data == REQ_SYNC)
                        st <= S_OP;
                end

                S_OP: if (rx_valid) begin
                    opcode  <= rx_data;
                    chk_acc <= rx_data;
                    argi    <= 2'd0;
                    st      <= S_ARGS;
                end

                S_ARGS: if (rx_valid) begin
                    arg[argi] <= rx_data;
                    chk_acc   <= chk_acc ^ rx_data;
                    if (argi == 2'd3) st <= S_CHK;
                    else              argi <= argi + 2'd1;
                end

                S_CHK: if (rx_valid) begin
                    if (rx_data == chk_acc) begin
                        st <= S_EXEC;
                    end else begin
                        rsp[0]  <= RSP_SYNC; rsp[1] <= ERR_CHK;
                        rsp_len <= 3'd2;     rsp_idx <= 3'd0;
                        st      <= S_BUF;
                    end
                end

                // ---- Execute the decoded command ----
                S_EXEC: begin
                    case (opcode)
                        OP_WRITE: begin
                            if (arg[1] == 8'd7 && arg[2] == 8'd0) begin
                                rsp[0] <= RSP_SYNC; rsp[1] <= ERR_RO;
                                rsp_len <= 3'd2; rsp_idx <= 3'd0; st <= S_BUF;
                            end else if (fsm_busy) begin
                                rsp[0] <= RSP_SYNC; rsp[1] <= ERR_BUSY;
                                rsp_len <= 3'd2; rsp_idx <= 3'd0; st <= S_BUF;
                            end else begin
                                host_bank  <= arg[0][BW-1:0];
                                host_fx    <= arg[1][FW-1:0];
                                host_param <= arg[2][PW-1:0];
                                host_data  <= arg[3];
                                host_wr_en <= 1'b1;
                                rsp[0] <= RSP_SYNC; rsp[1] <= ST_OK;
                                rsp_len <= 3'd2; rsp_idx <= 3'd0; st <= S_BUF;
                            end
                        end

                        OP_READ, OP_RDEF: begin
                            host_bank   <= arg[0][BW-1:0];
                            host_fx     <= arg[1][FW-1:0];
                            host_param  <= arg[2][PW-1:0];
                            use_default <= (opcode == OP_RDEF);
                            st          <= S_RWAIT;
                        end

                        OP_GBNK: begin
                            rsp[0] <= RSP_SYNC;
                            rsp[1] <= OP_GBNK;
                            rsp[2] <= 8'(bank_sel);
                            rsp[3] <= OP_GBNK ^ 8'(bank_sel);
                            rsp_len <= 3'd4; rsp_idx <= 3'd0; st <= S_BUF;
                        end

                        OP_DUMP: begin
                            wbank <= '0; wfx <= '0; wparam <= '0;
                            dcount <= 10'd0; dchk <= 8'h00; dhdr_idx <= 2'd0;
                            st <= S_DHDR;
                        end

                        OP_RESET: begin
                            if (fsm_busy) begin
                                rsp[0] <= RSP_SYNC; rsp[1] <= ERR_BUSY;
                                rsp_len <= 3'd2; rsp_idx <= 3'd0; st <= S_BUF;
                            end else begin
                                host_rst_scope <= arg[0][1:0];
                                host_bank      <= arg[1][BW-1:0];
                                host_fx        <= arg[2][FW-1:0];
                                host_param     <= arg[3][PW-1:0];
                                host_rst_en    <= 1'b1;
                                rsp[0] <= RSP_SYNC; rsp[1] <= ST_OK;
                                rsp_len <= 3'd2; rsp_idx <= 3'd0; st <= S_BUF;
                            end
                        end

                        OP_SAVE: begin
                            if (fsm_busy) begin
                                rsp[0] <= RSP_SYNC; rsp[1] <= ERR_BUSY;
                            end else begin
                                host_save_pulse <= 1'b1;
                                rsp[0] <= RSP_SYNC; rsp[1] <= ST_OK;
                            end
                            rsp_len <= 3'd2; rsp_idx <= 3'd0; st <= S_BUF;
                        end

                        OP_LOAD: begin
                            if (fsm_busy) begin
                                rsp[0] <= RSP_SYNC; rsp[1] <= ERR_BUSY;
                            end else begin
                                host_load_pulse <= 1'b1;
                                rsp[0] <= RSP_SYNC; rsp[1] <= ST_OK;
                            end
                            rsp_len <= 3'd2; rsp_idx <= 3'd0; st <= S_BUF;
                        end

                        OP_PING: begin
                            rsp[0] <= RSP_SYNC;
                            rsp[1] <= OP_PING;
                            rsp[2] <= VER_MAJ;
                            rsp[3] <= VER_MIN;
                            rsp[4] <= OP_PING ^ VER_MAJ ^ VER_MIN;
                            rsp_len <= 3'd5; rsp_idx <= 3'd0; st <= S_BUF;
                        end

                        default: begin
                            rsp[0] <= RSP_SYNC; rsp[1] <= ERR_OP;
                            rsp_len <= 3'd2; rsp_idx <= 3'd0; st <= S_BUF;
                        end
                    endcase
                end

                // ---- READ / RDEF: address now stable, value valid ----
                S_RWAIT: begin
                    rsp[0] <= RSP_SYNC;
                    rsp[1] <= OP_READ;
                    rsp[2] <= arg[0];
                    rsp[3] <= arg[1];
                    rsp[4] <= arg[2];
                    rsp[5] <= use_default ? host_default_value : host_rd_value;
                    rsp[6] <= OP_READ ^ arg[0] ^ arg[1] ^ arg[2]
                              ^ (use_default ? host_default_value : host_rd_value);
                    rsp_len <= 3'd7; rsp_idx <= 3'd0;
                    st <= S_BUF;
                end

                // ---- Emit a short response from rsp[] ----
                S_BUF: begin
                    if (tx_valid && tx_ready) begin
                        if (rsp_idx == rsp_len - 3'd1) st <= S_SYNC;
                        else                           rsp_idx <= rsp_idx + 3'd1;
                    end
                end

                // ---- DUMP: 4-byte header ----
                S_DHDR: begin
                    if (tx_ready) begin
                        if (dhdr_idx == 2'd3) st <= S_DADDR;
                        else                  dhdr_idx <= dhdr_idx + 2'd1;
                    end
                end

                // ---- DUMP: present current walker address ----
                S_DADDR: begin
                    host_bank  <= wbank;
                    host_fx    <= wfx;
                    host_param <= wparam;
                    st <= S_DDATA;
                end

                // ---- DUMP: send one value byte, advance walker ----
                S_DDATA: begin
                    if (tx_ready) begin
                        dchk <= dchk ^ host_rd_value;
                        if (dcount == 10'd511) begin
                            st <= S_DCHK;
                        end else begin
                            dcount <= dcount + 10'd1;
                            if (wparam == PARAM_COUNT - 1) begin
                                wparam <= '0;
                                if (wfx == FX_COUNT - 1) begin
                                    wfx   <= '0;
                                    wbank <= wbank + 1'b1;
                                end else begin
                                    wfx <= wfx + 1'b1;
                                end
                            end else begin
                                wparam <= wparam + 1'b1;
                            end
                            st <= S_DADDR;
                        end
                    end
                end

                // ---- DUMP: trailing checksum ----
                S_DCHK: begin
                    if (tx_ready) st <= S_SYNC;
                end

                default: st <= S_SYNC;
            endcase
        end
    end

endmodule
