// --- Auto Repeat Generation ---
module repeat_unit (
    input  logic clk, rst_n, stable,
    output logic pulse
);

    // ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;

    logic [$clog2(REPEAT_START_CNT)-1:0] hold_cnt;
    logic [$clog2(REPEAT_RATE_CNT)-1:0]  rate_cnt;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            hold_cnt <= 0; rate_cnt <= 0; pulse <= 0;
        end else begin
            pulse <= 0;
            if (stable) begin
                if (hold_cnt < REPEAT_START_CNT) hold_cnt <= hold_cnt + 1;
                else if (rate_cnt == REPEAT_RATE_CNT-1) begin
                    rate_cnt <= 0; pulse <= 1;
                end else rate_cnt <= rate_cnt + 1;
            end else begin
                hold_cnt <= 0; rate_cnt <= 0;
            end
        end
    end
endmodule