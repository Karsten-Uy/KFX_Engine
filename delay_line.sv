// // // Reusable delay line module for audio effects
// // // Uses RAM inference for efficient FPGA implementation
// // module delay_line #(
// //     parameter DATA_W = 16,
// //     parameter MAX_DELAY_SAMPLES = 65536,  // Adjust based on your memory budget
// //     parameter ADDR_W = $clog2(MAX_DELAY_SAMPLES)
// // )(
// //     input  logic                    clk,
// //     input  logic                    reset_n,
// //     input  logic signed [DATA_W-1:0] data_in,
// //     output logic signed [DATA_W-1:0] data_out,
// //     input  logic [ADDR_W-1:0]       delay_samples,  // How many samples to delay
// //     input  logic                    write_en
// // );

// //     // RAM buffer with ramstyle attribute to force RAM inference
// //     (* ramstyle = "M10K" *) logic signed [DATA_W-1:0] buffer [0:MAX_DELAY_SAMPLES-1];
    
// //     logic [ADDR_W-1:0] write_ptr;
// //     logic [ADDR_W-1:0] read_ptr;
// //     logic signed [DATA_W-1:0] read_data;
    
// //     // Calculate read pointer
// //     always_comb begin
// //         if (delay_samples > write_ptr)
// //             read_ptr = MAX_DELAY_SAMPLES[ADDR_W-1:0] - (delay_samples - write_ptr);
// //         else
// //             read_ptr = write_ptr - delay_samples;
// //     end
    
// //     // Synchronous RAM inference pattern
// //     always_ff @(posedge clk) begin
// //         if (write_en) begin
// //             buffer[write_ptr] <= data_in;
// //         end
// //         read_data <= buffer[read_ptr];
// //     end
    
// //     // Write pointer and output logic
// //     always_ff @(posedge clk) begin
// //         if (!reset_n) begin
// //             write_ptr <= 0;
// //             data_out <= 0;
// //         end else if (write_en) begin
// //             data_out <= read_data;
            
// //             // Increment write pointer (circular)
// //             if (write_ptr >= MAX_DELAY_SAMPLES[ADDR_W-1:0] - 1)
// //                 write_ptr <= 0;
// //             else
// //                 write_ptr <= write_ptr + 1;
// //         end
// //     end

// // endmodule


// // Reusable delay line module for audio effects
// // Uses RAM inference for efficient FPGA implementation
// module delay_line #(
//     parameter DATA_W = 16,
//     parameter MAX_DELAY_SAMPLES = 65536,
//     parameter ADDR_W = $clog2(MAX_DELAY_SAMPLES)
// )(
//     input  logic                    clk,
//     input  logic                    reset_n,
//     input  logic signed [DATA_W-1:0] data_in,
//     output logic signed [DATA_W-1:0] data_out,
//     input  logic [ADDR_W-1:0]       delay_samples,  // How many samples to delay
//     input  logic                    write_en
// );

//     // RAM buffer with ramstyle attribute to force RAM inference
//     (* ramstyle = "M10K" *) logic signed [DATA_W-1:0] buffer [0:MAX_DELAY_SAMPLES-1];
    
//     logic [ADDR_W-1:0] write_ptr;
//     logic [ADDR_W-1:0] read_ptr;
//     logic signed [DATA_W-1:0] read_data;
    
//     // Calculate read pointer with proper handling of delay_samples = 0
//     always_comb begin
//         if (delay_samples == 0) begin
//             // No delay - read what we just wrote (bypass mode)
//             read_ptr = write_ptr;
//         end else if (delay_samples > write_ptr) begin
//             // Wrap around case
//             read_ptr = MAX_DELAY_SAMPLES[ADDR_W-1:0] - (delay_samples - write_ptr);
//         end else begin
//             // Normal case
//             read_ptr = write_ptr - delay_samples;
//         end
//     end
    
//     // Synchronous RAM inference pattern
//     // Split read and write for proper RAM inference
//     always_ff @(posedge clk) begin
//         if (write_en) begin
//             buffer[write_ptr] <= data_in;
//         end
//         read_data <= buffer[read_ptr];
//     end
    
//     // Write pointer management and output
//     always_ff @(posedge clk) begin
//         if (!reset_n) begin
//             write_ptr <= 0;
//             data_out <= 0;
//         end else if (write_en) begin
//             // Special case: when delay is 0, output the input directly
//             if (delay_samples == 0)
//                 data_out <= data_in;
//             else
//                 data_out <= read_data;
            
//             // Increment write pointer (circular)
//             if (write_ptr >= MAX_DELAY_SAMPLES[ADDR_W-1:0] - 1)
//                 write_ptr <= 0;
//             else
//                 write_ptr <= write_ptr + 1;
//         end
//     end

// endmodule

// module delay_line #(
//     parameter DATA_W = 16,
//     parameter MAX_DELAY_SAMPLES = 24000,
//     parameter ADDR_W = $clog2(MAX_DELAY_SAMPLES)
// )(
//     input  logic                     clk,
//     input  logic                     reset_n,
//     input  logic signed [DATA_W-1:0] data_in,
//     output logic signed [DATA_W-1:0] data_out,
//     input  logic [ADDR_W-1:0]        delay_samples, 
//     input  logic                     sample_en
// );

//     (* ramstyle = "M10K" *) logic signed [DATA_W-1:0] buffer [0:MAX_DELAY_SAMPLES-1];
    
//     logic [ADDR_W-1:0] write_ptr;
//     logic [ADDR_W-1:0] read_ptr_a, read_ptr_b;
//     logic signed [DATA_W-1:0] out_a, out_b;
    
//     // Slew-limiting the delay path to prevent "jumps"
//     logic [ADDR_W-1:0] current_delay;
    
//     always_ff @(posedge clk) begin
//         if (!reset_n) begin
//             current_delay <= 0;
//         end else if (sample_en) begin
//             if (current_delay < delay_samples)      current_delay <= current_delay + 1;
//             else if (current_delay > delay_samples) current_delay <= current_delay - 1;
//         end
//     end

//     // Pointer Logic
//     // We read current_delay (A) and current_delay + 1 (B) for interpolation
//     always_comb begin
//         read_ptr_a = (write_ptr >= current_delay) ? 
//                      (write_ptr - current_delay) : 
//                      (MAX_DELAY_SAMPLES + write_ptr - current_delay);
                     
//         read_ptr_b = (read_ptr_a == 0) ? 
//                      (MAX_DELAY_SAMPLES - 1) : 
//                      (read_ptr_a - 1);
//     end

//     // Dual-port RAM read/write
//     always_ff @(posedge clk) begin
//         if (sample_en) begin
//             buffer[write_ptr] <= data_in;
//             out_a <= buffer[read_ptr_a];
//             out_b <= buffer[read_ptr_b];
            
//             // Increment write pointer
//             if (write_ptr >= MAX_DELAY_SAMPLES - 1) write_ptr <= 0;
//             else write_ptr <= write_ptr + 1;
//         end
//     end

//     // Simple Linear Interpolation (Average of two samples)
//     // For true high-fidelity, you'd use fractional bits, but a 50/50 mix 
//     // during transitions effectively removes the "shredding" sound.
//     assign data_out = (current_delay == 0) ? data_in : 
//                       $signed((out_a >>> 1) + (out_b >>> 1));

// endmodule


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

    (* ramstyle = "M10K" *) logic signed [DATA_W-1:0] buffer [0:MAX_DELAY_SAMPLES-1];
    logic [ADDR_W-1:0] write_ptr, read_ptr_a, read_ptr_b;
    logic [ADDR_W-1:0] current_delay;

    // Smoothly transition the delay time (prevents zipper buzz)
    always_ff @(posedge clk) begin
        if (!reset_n) current_delay <= 0;
        else if (sample_en) begin
            if (current_delay < delay_samples)      current_delay <= current_delay + 1;
            else if (current_delay > delay_samples) current_delay <= current_delay - 1;
        end
    end

    // Pointer math
    assign read_ptr_a = (write_ptr >= current_delay) ? 
                         (write_ptr - current_delay) : 
                         (MAX_DELAY_SAMPLES + write_ptr - current_delay);
    assign read_ptr_b = (read_ptr_a == 0) ? (MAX_DELAY_SAMPLES - 1) : (read_ptr_a - 1);

    always_ff @(posedge clk) begin
        if (sample_en) begin
            // 1. Write the current input (audio + feedback) to the buffer
            buffer[write_ptr] <= data_in;
            
            // 2. Output the delayed value for the NEXT cycle's feedback
            // We average two samples for interpolation
            if (current_delay == 0) 
                data_out <= data_in;
            else 
                data_out <= $signed((buffer[read_ptr_a] >>> 1) + (buffer[read_ptr_b] >>> 1));

            // 3. Move the write head
            if (write_ptr >= MAX_DELAY_SAMPLES - 1) write_ptr <= 0;
            else write_ptr <= write_ptr + 1;
        end
    end
endmodule