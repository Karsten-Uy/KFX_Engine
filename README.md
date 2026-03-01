# Helix at Home (HaH) Processor 🎸

## TODO
- updated documentation
- Scripting documentation
  - build.tcl and program_sof.tcl work but not program_jic.tcl

## Overview

**Helix at Home (HaH)** is a **synthesizable multi-effects guitar processor** implemented in **SystemVerilog** on the **DE1-SoC FPGA**. It uses the on-board **audio codec ADC and DAC** to process live audio input from an electric guitar through a configurable chain of digital audio effects.

This project was created to explore **audio DSP in hardware**, with a focus on real-time streaming, pipelined processing, and FPGA-based system design.

The design was initially forked from the *audio-loopback-only* example in
[De1-SoC-Verilog-Audio-HW-FX](https://github.com/navrajkambo/De1-SoC-Verilog-Audio-HW-FX) by Navraj Kambo, which provided basic audio codec configuration and loopback functionality.

---

## Audio Processing Chain

Audio is processed sequentially through the following effect chain:

```
Gain → Gate → EQ → Compressor → Distortion → EQ → Chorus → Gain → Delay → Reverb → Gain
```

---

## Hardware Interface (DE1-SoC)

### User Controls

* **Switches & Buttons**

  * Select effects and parameters
  * Increment / decrement parameter values
* **HEX Displays**

  * Show selected effect and parameter
  * Display current parameter value
* **LEDs**

  * Visual feedback for parameter values and selection state

### Audio I/O

* **Input:** DE1-SoC LINE IN (electric guitar)
* **Output:** DE1-SoC LINE OUT

---

## Audio & System Specifications

| Feature           | Value                                           |
| ----------------- | ----------------------------------------------- |
| Input             | Mono (left channel duplicated for guitar input) |
| Output            | Stereo                                          |
| Audio Resolution  | 16-bit                                          |
| Sampling Rate     | 48 kHz                                          |
| Internal Clock    | 50 MHz                                          |
| Max FX Slots      | 16                                              |
| Parameters per FX | Up to 8                                         |
| Latency           | under 1ms                                       |

---
## Block Diagram

![AudioFX Processor Block Diagram](./HaH%20Processor%20Block%20Diagram.drawio.png)

---

## Usage Instructions
The following sections outline how to use the board

### Hardware + Software Needed

Hardware
- x1 DE1 SoC Board 
  - x1 USB Blaster Cable
  - x1 Power Cable
- x2 AUX Cable
  - x1 whatever you connect to output, can be speacker, headphone, audio interface, etc
- x1 1/4 inch to AUX adapter
- x1 Guitar or your choice

Software
- Quartus Prime
  - `Quartus Prime Version 18.1.0 Build 09/12/2018 SJ Lite Edition` was used to develop this project

### How to install and run on the board

1. Clone this repo into the machine with Quartus Prime
2. Open quartus prime and use the `Programmer` tool the program the board with the `./AudioFX.sof` that is in the root directory of this repo, should not need any changes to project file or repo to do this
3. Click `KEY[0]` to reset the board
4. Connect one of the AUX cables to the green "LINE IN" port at the top left of the board and then connect the 1/4 inch to AUX adapter to the other end then plug that into you guitar
5. Connect the other AUX cable to the blue "LINE OUT" port at the top left of the board and then connect it to the output device
6. PLAY

#### How to create .jic file for power persistant design
1. Compile via quartus to generate the .sof file normally
2. Go to `File` > `Convert Programming File` in Quartus and then create the .jic file with the following settings and then click `Generate`
  - Configuration device: `EPCQ128A`
  - Flash Loader: `5CSEMA5`
  - SOF Data: .sof file generated in step 1 (should be `AudioFX.sof`)
  - Name: Whatever you want it to be (right now, I set the latest one to be `output_file.jic`)
3. Plug in the DE1 SoC and open the `Programmer` tool then click `Auto Detect` and in the popup select `5CSEMA5`
4. Right click on the second chip in the GUI and click `Change File` and select the file generated in step 2
5. Check the `Program/Configure` box for the selected box and then click `Start` 
  - This takes a few minutes to compile

### How to control FX

`HEX5-HEX2` display the currently selected FX number and parameter, with the exact mappings shown in the table below; values not listed correspond to no parameter. The current parameter value (ranging from 0 to 255) is visualized on `LEDR[9:0]` as a bar graph, where only `LEDR[9]` lit represents a value of 0 and `LEDR[8:0]` illuminate as the value increases. `KEY[2]` and `KEY[3]` are used to decrease and increase the selected parameter value, respectively. The active FX module is selected using `SW[9:6]`, while `SW[4:2]` choose the parameter within that FX, and `SW[0]` mutes the output signal with `HEX0` being a line if it is muted. To save a set of parameters, press `KEY[1]` and a `b` should appear on `HEX1` briefly. Once the `b` is gone, the parameters have been saved. To load saved parameters, flip `SW[1]` up and down.

### FX Mapping Table

| FX          | Parameter       | FX Number | Parameter Number |
| ----------- | --------------- | --------- | ---------------- |
| Gain1       | fx_gain         | F0        | P0               |
| Gate        | fx_threshold    | F1        | P0               |
| Gate        | fx_attack       | F1        | P1               |
| Gate        | fx_release      | F1        | P2               |
| Gate        | fx_knee         | F1        | P3               |
| Gate        | fx_depth        | F1        | P4               |
| EQ1         | fx_sub_gain     | F2        | P0               |
| EQ1         | fx_low_gain     | F2        | P1               |
| EQ1         | fx_mid_gain     | F2        | P2               |
| EQ1         | fx_high_gain    | F2        | P3               |
| Compressor  | fx_threshold    | F3        | P0               |
| Compressor  | fx_ratio        | F3        | P1               |
| Compressor  | fx_attack       | F3        | P2               |
| Compressor  | fx_release      | F3        | P3               |
| Compressor  | fx_input_gain   | F3        | P4               |
| Compressor  | fx_makeup_gain  | F3        | P5               |
| Compressor  | fx_mix          | F3        | P7               |
| Distortion  | fx_drive        | F4        | P0               |
| Distortion  | fx_makeup_gain  | F4        | P1               |
| Distortion  | fx_mix          | F4        | P7               |
| EQ2         | fx_sub_gain     | F5        | P0               |
| EQ2         | fx_low_gain     | F5        | P1               |
| EQ2         | fx_mid_gain     | F5        | P2               |
| EQ2         | fx_high_gain    | F5        | P3               |
| Chorus      | fx_rate         | F6        | P0               |
| Chorus      | fx_depth        | F6        | P1               |
| Chorus      | fx_mix          | F6        | P7               |
| Gain2       | fx_gain         | F7*       | P0*              |
| Delay       | fx_time         | F8        | P0               |
| Delay       | fx_feedback     | F8        | P1               |
| Delay       | fx_mix          | F8        | P7               |
| Reverb      | fx_size         | F9        | P0               |
| Reverb      | fx_damping      | F9        | P1               |
| Reverb      | fx_mix          | F9        | P7               |
| Gain2       | fx_gain         | F10       | P0               |

NOTES:
- You should see the FX Number values on HEX5-HEX4, with HEX5 always being F
- You should see the Parameter Number values on HEX3-HEX2, with HEX3 always being P
- The order of FX numbers represents the order the FX are connected in series, with the output of F0 being connected to the input of F1, and so on
- Gain2 should be modulated by the expression pedal
- Descriptions for what the parameters do are in the next section

## Implemented Effects & Parameters

### Gain

Applies a gain multiplier to the signal.

**Parameters**

* `fx_gain`: Gain multiplier (0–255), where `32 = unity`. Values above 32 amplify; values below 32 attenuate.

---

### Gate

Noise gate with a soft-knee and adjustable floor gain. Signals above the threshold pass through at unity; signals below are attenuated toward the depth floor. The knee region smoothly transitions between open and closed rather than switching abruptly.

**Parameters**

* `fx_threshold`: Gate open level (scaled to the full 16-bit signal range)
* `fx_attack`: Speed at which the gate opens after the signal exceeds the threshold (`0` = instant, `255` = slowest)
* `fx_release`: Speed at which the gate closes after the signal falls below the threshold (`0` = instant, `255` = slowest)
* `fx_knee`: Soft-knee half-width — widens the transition region around the threshold (`0` = hard switch, `255` = widest knee)
* `fx_depth`: Gain floor when the gate is fully closed (`0` = full mute, `255` = unity — effectively bypasses gating)

---

### EQ

4-band EQ that splits the signal into **sub, low, mid, and high** frequency bands and applies independent gain to each.

**Parameters**

* `fx_sub_gain`: Sub-band gain (`128 = unity`)
* `fx_low_gain`: Low-band gain (`128 = unity`)
* `fx_mid_gain`: Mid-band gain (`128 = unity`)
* `fx_high_gain`: High-band gain (`128 = unity`)

---

### Compressor

Peak-envelope-based compressor with lookahead that reduces signal levels above a threshold while leaving lower levels unchanged. Includes independent input and output gain stages and a parallel dry/wet blend for New York-style parallel compression.

**Parameters**

* `fx_threshold`: Compression onset level (0–255, scaled to full 16-bit range)
* `fx_ratio`: Compression ratio — `0` = 1:1 (no compression), `255` = maximum ratio
* `fx_attack`: Time before gain reduction begins after exceeding the threshold (upper nibble controls slew rate)
* `fx_release`: Time before gain reduction is released after falling below the threshold (upper nibble controls slew rate)
* `fx_input_gain`: Pre-compression input gain (`64 = unity`)
* `fx_makeup_gain`: Post-compression output gain (`64 = unity`)
* `fx_mix`: Dry/wet blend (`0` = fully dry, `255` = ~99.6% wet)

---

### Distortion

Amp-style distortion that models the full signal chain of an overdriven guitar amplifier through seven processing stages:

1. **Pre-emphasis** — A first-difference high-shelf filter (`emph = x + (x − x_prev) >> 2`) boosts the presence band (~3 kHz) before the signal hits the clipping stage, adding bite and pick attack to the distorted tone.

2. **Drive** — Multiplies the pre-emphasized signal by a gain in the range 1× to 32.875× (`drive_gain = 256 + fx_drive × 32`). Higher drive pushes more of the signal into the clipping region.

3. **Asymmetric bias** — A fixed +5% full-scale DC offset is added before clamping. This shifts the clipping threshold so positive and negative half-cycles clip at different levels, introducing even-order harmonics that give the distortion a warmer, more tube-like character.

4. **Soft clip (tanh approximation)** — The biased signal is passed through a 3rd-order polynomial approximation of `tanh(x)`, which smoothly compresses peaks rather than hard-squaring them:

   ```
           {  +2/3              , x ≥ +1
   f(x) =  {  x − x³/3          , −1 < x < 1
           {  −2/3              , x ≤ −1
   ```

   Division by 3 is approximated as `(x + x>>2 + x>>4 + x>>6) >> 2` (error ≤ 0.39%, inaudible).

5. **Wet/dry mix** — Blends the clipped signal with the original dry input (`0` = fully dry, `255` = ~99.6% wet), enabling parallel or blended distortion tones.

6. **Makeup gain** — Compensates for the level reduction caused by clipping (`128 = unity`).

7. **Cabinet simulation** — Two cascaded one-pole IIR low-pass filters (fc ≈ 4.4 kHz @ 48 kHz) roll off the harsh ultrasonic content produced by hard clipping, approximating the frequency response of a guitar speaker cabinet.

**Latency:** 6 samples.

**Parameters**

* `fx_drive`: Amount of gain into the clipping stage (`0` = 1× / unity, `255` ≈ 32.875×)
* `fx_makeup_gain`: Output level after clipping and cabinet simulation (`128 = unity`)
* `fx_mix`: Dry/wet blend (`0` = fully dry, `255` = ~99.6% wet)

---

### Chorus

Creates a thicker sound by duplicating and delaying the input signal, then modulating the delay time with a **triangle-wave LFO** before mixing it back with the original. Two quadrature voices (0° and 90°) produce a lush stereo spread.

**Parameters**

* `fx_rate`: LFO frequency (`0` = very slow, `255` = fastest)
* `fx_depth`: LFO modulation depth (`0` = no modulation, `255` = maximum)
* `fx_mix`: Dry/wet blend (`0` = fully dry, `255` = ~99.6% wet)

---

### Delay

Implements an echo effect using delay lines with feedback.

**Parameters**

* `fx_time`: Delay time (larger value = longer delay, scaled across the full delay buffer range)
* `fx_feedback`: Number of echo repeats (`0` = single echo, higher values = more repeats; internally capped to prevent runaway feedback)
* `fx_mix`: Dry/wet blend (`0` = fully dry, `255` = ~99.6% wet)

---

### Reverb

Implements a **Schroeder Reverberator** using parallel damped feedback comb filters followed by series all-pass filters to simulate room reverberation.

**Parameters**

* `fx_size`: Room size / decay time — scales all comb filter delays (`0` = smallest room / shortest tail, `255` = largest room / longest tail)
* `fx_damping`: High-frequency damping of the reverb tail (`0` = bright / full HF content, `255` = dark / heavily damped)
* `fx_mix`: Dry/wet blend (`0` = fully dry, `255` = ~99.6% wet)

---

## Tools, Technologies & Platform

* **FPGA Board:** DE1-SoC
* **HDL:** SystemVerilog
* **Audio Codec:** DE1-SoC on-board codec
* **Synthesis & Programming:** Intel Quartus
* **Simulation:** ModelSim