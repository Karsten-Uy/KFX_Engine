module tap_mute_unit #(
    parameter LONG_PRESS_CNT = 50_000_000 
)(
    input  logic clk, rst_n,
    input  logic stable,       // From debounce unit
    output logic is_mute,      // Latched mute state
    output logic delay_pulse   // Single cycle pulse on short press
);
    logic [$clog2(LONG_PRESS_CNT)-1:0] timer;
    logic long_press_triggered;
    logic prev_stable;

    // NOTE: do NOT use a wire/assign for rising edge detection.
    // A combinatorial wire is high between clock edges whenever
    // stable=1 and prev_stable=0, including routing glitches between
    // the two signals. That spuriously toggles is_mute mid-cycle,
    // which gates the DAC on/off at glitch rate = buzz.
    // Instead, evaluate (stable && !prev_stable) only inside always_ff
    // so it resolves once per clock edge.

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
                // Rising edge detected synchronously — safe from glitches
                if (stable && !prev_stable && is_mute) begin
                    is_mute              <= 1'b0;
                    long_press_triggered <= 1'b1;
                end

                if (!long_press_triggered) begin
                    if (timer < LONG_PRESS_CNT) begin
                        timer <= timer + 1;
                    end else begin
                        is_mute              <= 1'b1;
                        long_press_triggered <= 1'b1;
                    end
                end
            end else begin
                // Button released: short press -> tap pulse
                if (prev_stable && !long_press_triggered)
                    delay_pulse <= 1'b1;

                timer                <= 0;
                long_press_triggered <= 0;
            end
        end
    end
endmodule