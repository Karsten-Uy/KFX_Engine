# Helix at Home (HaH) Processor 🎸

## Overview

**Helix at Home (HaH)** is a **synthesizable multi-effects guitar processor** implemented in **SystemVerilog** on the **DE1-SoC FPGA**. It uses the on-board **audio codec ADC and DAC** to process live audio input from an electric guitar through a configurable chain of digital audio effects.

This project was created to explore **audio DSP in hardware**, with a focus on real-time streaming, pipelined processing, and FPGA-based system design.

The design was initially forked from the *audio-loopback-only* example in
[De1-SoC-Verilog-Audio-HW-FX](https://github.com/navrajkambo/De1-SoC-Verilog-Audio-HW-FX) by Navraj Kambo, which provided basic audio codec configuration and loopback functionality.

---

## Audio Processing Chain

Audio is processed sequentially through the following effect chain:

```
Gain → Gate → EQ → Compressor → Distortion → EQ → Chorus → Delay → Reverb → Gain
```

This structure mimics a traditional digital pedalboard signal flow.

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
| Latency           | 34 Samples (under 1ms)                          |

---
## Block Diagram

<img width="731" height="864" alt="HaH Processor Block Diagram drawio" src="https://github.com/user-attachments/assets/dd7014f6-2e50-4dd3-a2e8-0f2880afdd6e" />

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

### How to control FX
`HEX5-HEX2` display the currently selected FX number and parameter, with the exact mappings shown in the table below; values not listed correspond to no parameter. The current parameter value (ranging from 0 to 255) is visualized on `LEDR[9:0]` as a bar graph, where only `LEDR[9]` lit represents a value of 0 and `LEDR[8:0]` illuminate as the value increases. `KEY[2]` and `KEY[3]` are used to decrease and increase the selected parameter value, respectively. The active FX module is selected using `SW[9:6]`, while `SW[3:1]` choose the parameter within that FX, and `SW[0]` mutes the output signal with `HEX[0]` being a line if it is muted.

### FX Mapping  Table

| FX          | Parameter            | FX Number | Parameter Number  
| ----------- | -------------------- | ----------| ----------------
| Gain1       | fx_gain              | F0        | P0 
| Gate        | fx_threshold         | F1        | P0
| Gate        | fx_attack            | F1        | P1
| Gate        | fx_release           | F1        | P2
| EQ1         | fx_sub_gain          | F2        | P0
| EQ1         | fx_low_gain          | F2        | P1
| EQ1         | fx_mid_gain          | F2        | P2
| EQ1         | fx_high_gain         | F2        | P3
| Compressor  | fx_threshold         | F3        | P0
| Compressor  | fx_ratio             | F3        | P1
| Compressor  | fx_attack            | F3        | P2
| Compressor  | fx_release           | F3        | P4
| Distortion  | fx_drive             | F4        | P0
| Distortion  | fx_makeup_gain       | F4        | P1
| Distortion  | fx_mix               | F4        | P2
| EQ2         | fx_sub_gain          | F5        | P0
| EQ2         | fx_low_gain          | F5        | P1
| EQ2         | fx_mid_gain          | F5        | P2
| EQ2         | fx_high_gain         | F5        | P3
| Chorus      | fx_rate              | F6        | P0
| Chorus      | fx_depth             | F6        | P1
| Chorus      | fx_mix               | F6        | P2
| Delay       | fx_time              | F7        | P0
| Delay       | fx_feedback          | F7        | P1
| Delay       | fx_mix               | F7        | P2
| Reverb      | fx_size              | F8        | P0
| Reverb      | fx_damping           | F8        | P1
| Reverb      | fx_mix               | F8        | P2
| Gain2       | fx_gain              | F9        | P0 

NOTES:
- You should see the FX Number values on HEX5-HEX4, with HEX5 always being F
- You should see the Parameter Number values on HEX3-HEX2, with HEX3 always being P
- The order of FX number represented how the order the FX are connect in series, with the output of F0 being connected to the input of F1 so on and so forth
- Descriptions for what the parameters do are in the next section

## Implemented Effects & Parameters

### Gain

Applies a gain multiplier to the signal.

**Parameters**

* `fx_gain`: Gain multiplier (0–255), where `128 = unity`

---

### Gate

Noise gate using **peak envelope smoothing**. Signals above the threshold pass through, while signals below are muted.

**Parameters**

* `fx_threshold`: Threshold (scaled 0–24480 relative to `audio_in`)
* `fx_attack`: Time for gate to open after exceeding threshold
* `fx_release`: Time for gate to close after falling below threshold

---

### EQ

3-band EQ that splits the signal into **low, mid, and high** frequency bands.

**Parameters**

* `fx_sub_gain`: Sub-band gain (`128 = unity`)
* `fx_low_gain`: Low-band gain (`128 = unity`)
* `fx_mid_gain`: Mid-band gain (`128 = unity`)
* `fx_high_gain`: High-band gain (`128 = unity`)

---

### Compressor

Peak-envelope-based compressor that reduces signal levels above a threshold while leaving lower levels unchanged.

**Parameters**

* `fx_threshold`: Threshold (0–24480 scaled to input)
* `fx_ratio`: Compression ratio from 1:1 (`0`) to 20:1 (`255`)
* `fx_attack`: Time before gain reduction begins
* `fx_release`: Time before gain reduction is released

---

### Distortion

Non-linear distortion using a **3rd-order polynomial approximation of `tanh(x)`**:

```
        {  2/3           , x ≥ 1
f(x) =  {  x − x³/3      , −1 < x < 1
        {  2/3           , x ≤ −1
```

**Parameters**

* `fx_drive`: Input gain into non-linearity

  * `0 = unity`, `255 ≈ 32.875×`
* `fx_makeup_gain`: Output gain (`128 = unity`)
* `fx_mix`: Dry/wet mix

  * `0 = all dry`, `255 = all wet`

---

### Chorus

Creates a thicker sound by duplicating and delaying the input signal, then modulating it with a **triangle-wave LFO** before mixing it back with the original.

**Parameters**

* `fx_rate`: LFO frequency
* `fx_depth`: LFO modulation depth
* `fx_mix`: Dry/wet mix

---

### Delay

Implements an echo effect using delay lines with feedback.

**Parameters**

* `fx_time`: Delay time (larger value = longer delay)
* `fx_feedback`: Feedback amount (capped at 0.875 to prevent runaway)
* `fx_mix`: Dry/wet mix

---

### Reverb

Implements a **Schroeder Reverberator** using parallel feedback comb filters followed by series all-pass filters to simulate room reverberation.

**Parameters**

* `fx_size`: Controls room size (delay lengths)
* `fx_damping`: Controls reverberation damping
* `fx_mix`: Dry/wet mix

---

## Tools, Technologies & Platform

* **FPGA Board:** DE1-SoC
* **HDL:** SystemVerilog
* **Audio Codec:** DE1-SoC on-board codec
* **Synthesis & Programming:** Intel Quartus
* **Simulation:** ModelSim
