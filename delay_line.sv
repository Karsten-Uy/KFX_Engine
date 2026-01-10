module delay_line #(
    parameter DATA_W = 16,
    parameter MAX_DELAY_SAMPLES = 24000,
    parameter ADDR_W = $clog2(MAX_DELAY_SAMPLES)
)(
    input  logic                     clk,
    input  logic                     reset_n,
    input  logic signed [DATA_W-1:0] data_in,
    output logic signed [DATA_W-1:0] data_out,
    input  logic [ADDR_W-1:0]        delay_samples, 
    input  logic                     sample_en
);

    // Force M10K inference
    (* ramstyle = "M10K" *) logic signed [DATA_W-1:0] buffer [0:MAX_DELAY_SAMPLES-1];
    
    logic [ADDR_W-1:0] write_ptr;
    logic [ADDR_W-1:0] read_ptr;
    logic signed [DATA_W-1:0] ram_out;

    // 1. Address Calculation (Combinational is fine for ADDR)
    always_comb begin
        if (write_ptr >= delay_samples)
            read_ptr = write_ptr - delay_samples;
        else
            read_ptr = MAX_DELAY_SAMPLES + write_ptr - delay_samples;
    end

    // 2. The RAM Block (Strict Synchronous Pattern)
    // Do NOT put interpolation or bypass logic inside this specific block
    always_ff @(posedge clk) begin
        if (sample_en) begin
            buffer[write_ptr] <= data_in;
            ram_out <= buffer[read_ptr]; // This is the "Magic" line for inference
        end
    end

    // 3. Logic & Pointer Management
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            write_ptr <= 0;
            data_out  <= 0;
        end else if (sample_en) begin
            // Output Logic
            if (delay_samples == 0)
                data_out <= data_in;
            else
                data_out <= ram_out;

            // Increment Write Pointer
            if (write_ptr >= MAX_DELAY_SAMPLES - 1)
                write_ptr <= 0;
            else
                write_ptr <= write_ptr + 1;
        end
    end

endmodule