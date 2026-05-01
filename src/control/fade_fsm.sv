/*
 * fade_fsm.sv
 *
 * Soft-mute / fade-in / fade-out FSM that drives the chain-input
 * scale and the DAC output scale during bank switches and footswitch
 * mute.  Clocked on the audio sample-rate strobe so transitions
 * happen at 48 kHz, not the system clock.
 *
 * State machine
 * -------------
 *   ST_UNMUTED   — full unity (ramp_vol = 256), pass audio through.
 *                  On mute_req: kick off ST_FADE_OUT.
 *
 *   ST_FADE_OUT  — ramp_vol decrements every sample (256 → 0,
 *                  ~5.3 ms).  When it hits 0, transition to ST_MUTED.
 *                  The pre-mute snap is intentionally tight so the
 *                  switch feels responsive.
 *
 *   ST_MUTED     — held until mute_req drops.  `muted` is asserted
 *                  here; consumer logic uses this to drop reset on
 *                  feedback FX (delay/reverb) and to assert flush.
 *                  ramp_vol stays at 0, so the DAC sees silence
 *                  while feedback BRAM clears under reset.
 *
 *   ST_FADE_IN   — ramp_vol increments every FADE_IN_DIV-th sample
 *                  (default 4 → ~21 ms).  Fade-in is deliberately
 *                  slower than fade-out: the BRAM-fill region of
 *                  delay/reverb recirculates this ramp every
 *                  delay_time, and a 5 ms attack region was
 *                  audible as a pop through the feedback path.
 *                  21 ms makes it a smooth swell.  Reaches 256 →
 *                  ST_UNMUTED.
 *
 * Outputs
 * -------
 *   ramp_vol — 0..256 amplitude scale, Q0.8.  Apply at DAC always,
 *              and at chain input during transitions only (consumer
 *              should bypass the multiplier in steady state to keep
 *              the audio path bit-exact).
 *   muted    — high during ST_MUTED.  Drives fx_reset_n on feedback
 *              FX and the flush input on delay/reverb.
 *   unmuted  — high during ST_UNMUTED.  Selects direct ADC passthrough
 *              at the chain input.
 *
 * Style
 * -----
 *   Three-process FSM (state register + next-state combinational
 *   + output combinational) plus a separate sequential block for
 *   the ramp_vol / fade_in_div datapath registers, mirroring the
 *   controller_fsm.sv organisation.
 */

module fade_fsm #(
    parameter int FADE_IN_DIV = 4
)(
    input  logic       clk,
    input  logic       reset_n,
    input  logic       sample_en,    // one-cycle pulse per audio sample
    input  logic       mute_req,     // assert to fade out and hold muted
    output logic [8:0] ramp_vol,
    output logic       muted,
    output logic       unmuted
);

    // ----------------------------------------------------------------
    // State Encoding
    // ----------------------------------------------------------------

    typedef enum logic [1:0] {
        ST_UNMUTED  = 2'd0,
        ST_FADE_OUT = 2'd1,
        ST_MUTED    = 2'd2,
        ST_FADE_IN  = 2'd3
    } fade_state_t;

    fade_state_t state, next;

    // ----------------------------------------------------------------
    // Datapath Registers
    // ----------------------------------------------------------------

    logic [$clog2(FADE_IN_DIV)-1:0] fade_in_div;

    // ----------------------------------------------------------------
    // State Register
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n)         state <= ST_UNMUTED;
        else if (sample_en)   state <= next;
    end

    // ----------------------------------------------------------------
    // Next-State Logic
    // ----------------------------------------------------------------

    always_comb begin
        next = state;
        case (state)
            ST_UNMUTED:
                if (mute_req) next = ST_FADE_OUT;

            ST_FADE_OUT:
                if      (!mute_req)         next = ST_FADE_IN;
                else if (ramp_vol == 9'd0)  next = ST_MUTED;

            ST_MUTED:
                if (!mute_req) next = ST_FADE_IN;

            ST_FADE_IN:
                if      (mute_req)             next = ST_FADE_OUT;
                else if (ramp_vol == 9'd256)   next = ST_UNMUTED;

            default: next = ST_UNMUTED;
        endcase
    end

    // ----------------------------------------------------------------
    // Output Logic  (Moore)
    // ----------------------------------------------------------------

    always_comb begin
        muted   = (state == ST_MUTED);
        unmuted = (state == ST_UNMUTED);
    end

    // ----------------------------------------------------------------
    // Datapath: ramp_vol + fade_in_div
    //
    // ramp_vol decrements every sample in ST_FADE_OUT until it reaches
    // 0; increments every FADE_IN_DIV samples in ST_FADE_IN until it
    // reaches 256.  Holds in ST_UNMUTED (256) and ST_MUTED (0).
    //
    // fade_in_div is held at 0 in every state except ST_FADE_IN, so the
    // first ramp_vol increment after entering ST_FADE_IN happens
    // FADE_IN_DIV samples in.
    // ----------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            ramp_vol    <= 9'd256;
            fade_in_div <= '0;
        end else if (sample_en) begin
            case (state)
                ST_FADE_OUT: begin
                    if (ramp_vol != 9'd0)
                        ramp_vol <= ramp_vol - 1'b1;
                    fade_in_div <= '0;
                end

                ST_FADE_IN: begin
                    if (ramp_vol != 9'd256) begin
                        if (fade_in_div == FADE_IN_DIV - 1) begin
                            fade_in_div <= '0;
                            ramp_vol    <= ramp_vol + 1'b1;
                        end else begin
                            fade_in_div <= fade_in_div + 1'b1;
                        end
                    end
                end

                // ST_UNMUTED + ST_MUTED: ramp_vol holds its current value
                // (256 in UNMUTED, 0 in MUTED).  No assignment = flop-with-enable
                // inferred; this is NOT a latch because we are inside always_ff.
                default: fade_in_div <= '0;
            endcase
        end
    end

endmodule
