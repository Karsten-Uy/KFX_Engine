
module debounce_unit (
    input  logic clk, rst_n, in,
    output logic stable, pulse
);

    // ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;

    logic sync0, sync1, prev;
    logic [$clog2(DEBOUNCE_CNT_MAX)-1:0] count;

    // pulse is combinational — fires the same cycle stable rises
    assign pulse = stable && !prev;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sync0  <= 0;
            sync1  <= 0;
            stable <= 0;
            prev   <= 0;
            count  <= 0;
        end else begin
            sync0 <= in;
            sync1 <= sync0;

            if (sync1 == stable)
                count <= 0;
            else if (count == DEBOUNCE_CNT_MAX-1) begin
                stable <= sync1;
                count  <= 0;
            end else
                count <= count + 1;

            prev <= stable;
        end
    end
endmodule