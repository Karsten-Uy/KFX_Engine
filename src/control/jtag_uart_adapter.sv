/*
 * jtag_uart_adapter.sv
 *
 * Avalon-MM master front-end for the generated `JtagUart` IP (Altera JTAG UART).
 * Converts the JTAG UART's register interface into a simple byte stream for
 * host_if, so the command parser stays transport-agnostic.
 *
 * JTAG UART register map (word-addressed, 32-bit):
 *   data    (address 0): read  -> [7:0]=RX byte, [15]=RVALID, [31:16]=RAVAIL
 *                        write -> [7:0]=TX byte
 *   control (address 1): read  -> [31:16]=WSPACE (free space in TX FIFO)
 *
 * NOTE: the generated slave (JtagUart/synthesis/JtagUart.v) uses ACTIVE-LOW
 * read_n / write_n and a waitrequest handshake.
 *
 * Byte-stream interface to host_if
 * --------------------------------
 *   rx_data/rx_valid  one-cycle strobe when a byte arrives; only fetched while
 *                     rx_ready is high (host_if can accept it).
 *   tx_data/tx_valid  host_if presents a byte and holds it until tx_ready
 *                     pulses (byte accepted into the JTAG UART write FIFO).
 *
 * A single Avalon master serializes RX and TX.  TX has priority so command
 * responses (including the 512-byte DUMP) flush out; RX is polled whenever the
 * host has nothing queued to send.
 */
module jtag_uart_adapter (
    input  logic        clk,
    input  logic        reset_n,

    // ---- Avalon-MM master to the generated JtagUart IP ----
    output logic        av_chipselect,
    output logic        av_address,      // 0 = data reg, 1 = control reg
    output logic        av_read_n,       // active LOW
    input  logic [31:0] av_readdata,
    output logic        av_write_n,      // active LOW
    output logic [31:0] av_writedata,
    input  logic        av_waitrequest,

    // ---- Byte stream from JTAG (RX, PC -> FPGA) ----
    output logic [7:0]  rx_data,
    output logic        rx_valid,
    input  logic        rx_ready,

    // ---- Byte stream to JTAG (TX, FPGA -> PC) ----
    input  logic [7:0]  tx_data,
    input  logic        tx_valid,
    output logic        tx_ready
);

    typedef enum logic [1:0] {
        IDLE,
        RX_READ,   // reading the data register (pops one RX char)
        TX_CTRL,   // reading the control register (check WSPACE)
        TX_WRITE   // writing the data register (push one TX char)
    } state_t;

    state_t state;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            state         <= IDLE;
            av_chipselect <= 1'b0;
            av_address    <= 1'b0;
            av_read_n     <= 1'b1;
            av_write_n    <= 1'b1;
            av_writedata  <= 32'b0;
            rx_data       <= 8'b0;
            rx_valid      <= 1'b0;
            tx_ready      <= 1'b0;
        end else begin
            // one-cycle strobes default low
            rx_valid <= 1'b0;
            tx_ready <= 1'b0;

            case (state)
                IDLE: begin
                    av_chipselect <= 1'b0;
                    av_read_n     <= 1'b1;
                    av_write_n    <= 1'b1;
                    if (tx_valid) begin
                        // start TX: first read control reg to check WSPACE
                        av_address    <= 1'b1;       // control
                        av_chipselect <= 1'b1;
                        av_read_n     <= 1'b0;
                        state         <= TX_CTRL;
                    end else if (rx_ready) begin
                        // poll data reg for an incoming byte
                        av_address    <= 1'b0;       // data
                        av_chipselect <= 1'b1;
                        av_read_n     <= 1'b0;
                        state         <= RX_READ;
                    end
                end

                RX_READ: begin
                    if (!av_waitrequest) begin
                        av_chipselect <= 1'b0;
                        av_read_n     <= 1'b1;
                        if (av_readdata[15]) begin   // RVALID
                            rx_data  <= av_readdata[7:0];
                            rx_valid <= 1'b1;
                        end
                        state <= IDLE;
                    end
                end

                TX_CTRL: begin
                    if (!av_waitrequest) begin
                        av_read_n <= 1'b1;
                        if (av_readdata[31:16] != 16'd0) begin
                            // space available -> write the data byte
                            av_address    <= 1'b0;   // data
                            av_writedata  <= {24'b0, tx_data};
                            av_chipselect <= 1'b1;
                            av_write_n    <= 1'b0;
                            state         <= TX_WRITE;
                        end else begin
                            // FIFO full -> retry (tx_valid still held by host_if)
                            av_chipselect <= 1'b0;
                            state         <= IDLE;
                        end
                    end
                end

                TX_WRITE: begin
                    if (!av_waitrequest) begin
                        av_chipselect <= 1'b0;
                        av_write_n    <= 1'b1;
                        tx_ready      <= 1'b1;       // byte accepted
                        state         <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
