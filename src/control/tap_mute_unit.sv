module tap_mute_unit (
    input  logic clk, rst_n,
    input  logic stable,       // From debounce unit
    output logic is_mute,      // Latched mute state
    output logic delay_pulse   // Single cycle pulse on short press
);

    // ---------------- PACKAGE IMPORTS ----------------
    import lab_pkg::*;

    logic [$clog2(MUTE_START_CNT)-1:0] timer;
    logic long_press_triggered;
    logic prev_stable;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            timer                <= 0;
            is_mute              <= 0;
            delay_pulse          <= 0;
            long_press_triggered <= 0;
            prev_stable          <= 0;
        end else begin
            delay_pulse <= 0;
            prev_stable <= stable;

            if (stable) begin
                if (stable && !prev_stable && is_mute) begin
                    // Rising edge while muted: unmute immediately
                    is_mute              <= 1'b0;
                    long_press_triggered <= 1'b1;
                end else if (!long_press_triggered) begin
                    // Not yet triggered: count toward long press
                    if (timer < MUTE_START_CNT - 1) begin
                        timer <= timer + 1;
                    end else begin
                        // Long press threshold reached: engage mute
                        is_mute              <= 1'b1;
                        long_press_triggered <= 1'b1;
                    end
                end
                // If long_press_triggered and not a rising-edge-while-muted,
                // do nothing: hold current state until release
            end else begin
                // Button released
                if (prev_stable && !long_press_triggered) begin
                    // Was a short press: emit tap tempo pulse
                    delay_pulse <= 1'b1;
                end

                // Reset for next press
                timer                <= 0;
                long_press_triggered <= 0;
            end
        end
    end
endmodule