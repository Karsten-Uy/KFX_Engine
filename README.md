# KFX Engine 🎸

## Overview

The **KFX Engine** is a **synthesizable multi-effects guitar processor** implemented in **SystemVerilog** on the **DE1-SoC FPGA**. It uses the on-board **audio codec ADC and DAC** to process live audio input from an electric guitar through a configurable chain of digital audio effects.

This project was created to explore **audio DSP in hardware**, with a focus on real-time streaming, pipelined processing, and FPGA-based system design.

The design was initially forked from the *audio-loopback-only* example in
[De1-SoC-Verilog-Audio-HW-FX](https://github.com/navrajkambo/De1-SoC-Verilog-Audio-HW-FX) by Navraj Kambo, which provided basic audio codec configuration and loopback functionality.

---

## Audio Processing Chain

Audio is processed sequentially through the following effect chain:

```
Gain -> Gate -> EQ -> Compressor -> Distortion -> EQ -> Chorus -> Gain -> Delay -> Reverb -> Gain
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
| Latency           | 25-30 samples (~520-625 µs @ 48 kHz)            |

---

## Audio Latency Breakdown

Total latency from `LINE IN` to `LINE OUT` is the sum of register stages in each FX module. All values in 48 kHz samples (one sample = ~20.83 µs).

| Stage | Samples | Detail |
| ----- | ------: | ------ |
| FX 0 — Input Gain | 1 | `fx_gain` output register |
| FX 1 — Gate | 0 | `audio_out` is combinational (assign-driven multiplier) |
| FX 2 — EQ 1 | 2 | leaky-integrator band-split + output register |
| FX 3 — Compressor | 10 | 1 (input gain) + 8 (lookahead) + 1 (output) — lookahead is intentional |
| FX 4 — Distortion | 6 (engaged) / 1 (bypassed) | 6-stage drive/clip/post pipeline; mix=0 routes `audio_in` directly through 1 register |
| FX 5 — EQ 2 | 2 | same module as EQ 1 |
| FX 6 — Chorus | 3 | 2 (delay-line pipeline) + 1 (output register) |
| FX 7 — Expression Gain | 1 | `fx_gain` output register |
| FX 8 — Delay | 2 | 1 (delay-line RAM) + 1 (output register) |
| FX 9 — Reverb | 1 | dry path: combinational mix + output register |
| FX 10 — Output Gain | 1 | `fx_gain` output register |
| FX 15 — Global Gain | 1 | `fx_gain` output register |
| DAC register | <1 | runs at CLOCK_50, ~20 ns ≈ 0.001 audio samples |

* **Worst case** (every effect engaged with `fx_mix > 0`): **30 samples ≈ 625 µs**
* **Best case** (distortion at `fx_mix = 0`): **25 samples ≈ 521 µs**

The compressor's lookahead is the largest contributor (one third of the chain). It's not waste — the lookahead lets the gain reduction apply to the same peak that triggered it, instead of acting on already-clipped samples.

---
## Block Diagram

![AudioFX Processor Block Diagram](./HaH%20Processor%20Block%20Diagram.drawio.png)

---

## Usage Instructions
The following sections outline how to use the board with the base hardware that lacks periferals

### Software Required

- Quartus Prime for compilation and programming the FPGA
  - `Quartus Prime Version 18.1.0 Build 09/12/2018 SJ Lite Edition` was used to develop this project
- Modelsim for running testbenches

### Minimum Hardware Needed
NOTE* This list is just to run the project without periferals, all DSP functionality and control can be done with just this hardware

- [x1 DE1 SoC Board](https://www.terasic.com.tw/cgi-bin/page/archive.pl?Language=English&No=836)
  - x1 USB Blaster Cable
  - x1 Power Cable
- [x2 AUX Cable](https://www.amazon.ca/dp/B09261T14K/ref=twister_B095W3XT2K?_encoding=UTF8)
  - x1 whatever you connect to output, can be speacker, headphone, audio interface, etc
- [x1 1/4 inch to AUX adapter](https://www.amazon.ca/Adapter-6-35mm-Female-Headphone-Connector/dp/B084VGXK45/ref=sr_1_3?s=electronics&sr=1-3)
- x1 Guitar or your choice

### How to install and run on the board

1. Clone this repo into the machine with Quartus Prime
2. Open quartus prime and run the `scripts/program_sof.tcl` script
3. Click `KEY[0]` to reset the board
4. Connect one of the AUX cables to the green "LINE IN" port at the top left of the board and then connect the 1/4 inch to AUX adapter to the other end then plug that into you guitar
5. Connect the other AUX cable to the blue "LINE OUT" port at the top left of the board and then connect it to the output device
6. PLAY

#### How to create .jic file for power persistant design
1. Compile via quartus to generate the .sof file normally
2. Go to `File` > `Convert Programming File` in Quartus and then create the .jic file with the following settings and then click `Generate`
    - Configuration device: `EPCQ128A`
    - Flash Loader: `5CSEMA5`
    - SOF Data: .sof file generated in step 1 (should be `output_files/AudioFX.sof`)
    - Name: Whatever you want it to be (right now, I set the latest one to be `output_file.jic`)
3. Plug in the DE1 SoC and open the `Programmer` tool then click `Auto Detect` and in the popup select `5CSEMA5`
4. Right click on the second chip in the GUI (`5CSEMA5`) and click `Change File` and select the file generated in step 2
5. Check the `Program/Configure` box for the selected box and then click `Start` 
    - This takes a few minutes to program 

### How to control FX

`HEX5-HEX2` display the currently selected FX number and parameter, with the exact mappings shown in the table below; values not listed correspond to no parameter. The current parameter value (ranging from 0 to 255) is visualized on `LEDR[9:0]` as a bar graph, where only `LEDR[9]` lit represents a value of 0 and `LEDR[8:0]` illuminate as the value increases. `KEY[2]` and `KEY[3]` are used to decrease and increase the selected parameter value, respectively. The active FX module is selected using `SW[9:6]`, while `SW[4:2]` choose the parameter within that FX. To save a set of parameters, flip up `SW[0]` and a `b` should appear on `HEX1` briefly. Once the `b` is gone, the parameters have been saved. To load saved parameters, flip `SW[1]` up and down.

### SW Map Table
| SW Number | Usage                              |
| --------- | ---------------------------------- |
| SW9       | FX[3] and Freq/Note Tuner Toggle   | 
| SW8       | FX[2]                              | 
| SW7       | FX[1]                              | 
| SW6       | FX[0]                              | 
| SW5       | Param[2]                           | 
| SW4       | Param[1]                           | 
| SW3       | Param[0]                           | 
| SW2       | Switch Bank on rising edge         | 
| SW1       | Load Saved Params on rising edge   | 
| SW0       | Save Current Params on rising edge | 

### KEY Map Table
| KEY Number | Usage                     |
| ---------- | ------------------------- |
| KEY[3]     | Decrease Parameter Values | 
| KEY[2]     | Increase Parameter Values | 
| KEY[1]     | Mute / Tap Delay          | 
| KEY[0]     | Design Reset              | 

### FX Mapping Table

| FX          | Parameter       | FX Num | Parameter Num |
| ----------- | --------------- | --------- | ---------------- |
| Input Gain  | fx_gain         | F0        | P0               |
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
| Distortion  | fx_bias         | F4        | P2               |
| Distortion  | fx_sag          | F4        | P3               |
| Distortion  | fx_tone         | F4        | P4               |
| Distortion  | fx_tightness    | F4        | P5               |
| Distortion  | fx_smooth       | F4        | P6               |
| Distortion  | fx_mix          | F4        | P7               |
| EQ2         | fx_sub_gain     | F5        | P0               |
| EQ2         | fx_low_gain     | F5        | P1               |
| EQ2         | fx_mid_gain     | F5        | P2               |
| EQ2         | fx_high_gain    | F5        | P3               |
| Chorus      | fx_rate         | F6        | P0               |
| Chorus      | fx_depth        | F6        | P1               |
| Chorus      | fx_mix          | F6        | P7               |
| EXP Gain    | fx_gain         | F7*       | P0*              |
| Delay       | fx_time         | F8        | P0               |
| Delay       | fx_feedback     | F8        | P1               |
| Delay       | fx_mix          | F8        | P7               |
| Reverb      | fx_size         | F9        | P0               |
| Reverb      | fx_damping      | F9        | P1               |
| Reverb      | fx_decay        | F9        | P2               |
| Reverb      | fx_mix          | F9        | P7               |
| Output Gain | fx_gain         | F10       | P0               |
| Global Gain | fx_gain         | F15       | P0               |

NOTES:
- You should see the FX Number values on HEX5-HEX4, with HEX5 always being F
- You should see the Parameter Number values on HEX3-HEX2, with HEX3 always being P
- The order of FX numbers represents the order the FX are connected in series, with the output of F0 being connected to the input of F1, and so on
- Gain2 should be modulated by the expression pedal
- **F15 (Global Gain)** is the only "global" slot — its value is mirrored across all four banks. Editing it on any bank instantly updates the same slot on every other bank, and saving captures the same value on all banks to flash. Use it as a chain-wide master volume that survives bank switches.
- Descriptions for what the parameters do are in the next section

### Saving and Loading Presets (Banks)

The pedalboard stores **four independent preset banks** in the on-board EPCQ256 SPI flash. Each bank is a complete snapshot of every parameter for every FX in the chain — selecting a different bank instantly recalls a totally different sound (different gate threshold, EQ curve, distortion drive, delay time, reverb size, etc.) without losing what you had configured on the other banks.

**What a save captures.** A single save writes **all four banks** to flash at once, not just the active one. So the workflow is: dial in bank 0 the way you want it (using the bank switch on `GPIO_1[0]` or `SW[2]` to be on bank 0, then editing FX/params), switch to bank 1, dial that one in, then bank 2, then bank 3 — and finally save once. After the save, every bank's full state is in flash and survives a power cycle.

**Storage layout.** Total preset data is `BANK_COUNT × FX_COUNT × PARAM_COUNT = 4 × 16 × 8 = 512 bytes`, which fits comfortably inside one 64 KB EPCQ sector. The first byte of the sector is a `0xA5` **sentinel** that marks the data as valid — this lets the loader distinguish a freshly-erased flash (all `0xFF`) from a real saved preset, so a board with no save history won't load garbage on boot.

**Save sequence** (triggered by `SW[0]` rising edge — flip up):

1. `b` appears on `HEX1` (`fsm_busy = 1`) and the audio chain is muted to suppress glitches from mid-stream parameter writes.
2. `WREN` (write enable) command issued to flash via CSR.
3. The full 64 KB sector is erased — this is the slow part, **about 3 seconds worst-case**, during which `b` stays lit.
4. All 512 parameter bytes (every bank, every FX, every param) are written sequentially.
5. The `0xA5` sentinel is written to slot 0 **last** — so if power is lost mid-save the sentinel won't be present and the next boot's load will safely abort instead of using a half-written preset.
6. `b` clears, audio fades back in. Save complete.

**Load sequence** (triggered by `SW[1]` rising edge — flip up then down):

1. Read slot 0 from flash; check for `0xA5`. If absent, abort silently (board keeps current in-RAM presets).
2. If present, read all 512 parameter bytes and write them into the live `params` array, bank by bank.
3. The current bank's parameters are immediately reflected on the FX chain.

**Power-persistent operation.** If you flash the design as a `.jic` file (see "How to create .jic file for power persistant design" above), the saved bank data lives in the EPCQ256 alongside the bitstream and survives a full power-off. On any subsequent boot, flipping `SW[1]` recalls the four banks exactly as they were last saved.

## Periferal Usage

### Periferal Hardware
NOTE* The periferals only add live stage accessable controls and do not change the DSP functionality.

- [5x Momentary Soft Touch Foot Switch](https://www.amazon.ca/dp/B08TBTWDYV)
- [1x 15" x 5.7" Aluminum Alloy Guitar Effects PedalBoard with Carry Bag](https://www.amazon.ca/dp/B0D5CBVMHY)
- [1x Expression Pedal](https://www.amazon.ca/dp/B07CZJYLJV) - any TRS expression pedal works
- Masking Tape
- [Soldering Iron](https://www.amazon.ca/Soldering-Electronics-Adjustable-Temperature-Repairing/dp/B097XX76V4)
- Glue Gun
- Electronic Cardboard Boxes or Aluminium cast die boxes for buttons and electronics
- AUX cables you are willing to cut
- [x1 AUX to 1/4 TRS for expression pedal](https://www.amazon.ca/Hosa-GPM-103-3-5mm-TRS-Adaptor/dp/B000068O3T)
- [Electronics Kit](https://www.amazon.ca/dp/B01ERP6WL4)
  - Wires
  - Resistors
  - x1 LED
  - [Multimeter](https://www.amazon.ca/dp/B01ISAMUA6)

### Wiring & Pin Map

| Peripheral             | DE1-SoC pin   | Behavior                                                                      |
| ---------------------- | ------------- | ----------------------------------------------------------------------------- |
| Bank footswitch 0      | `GPIO_1[0]`   | Press -> activate preset bank 0                                                |
| Bank footswitch 1      | `GPIO_1[1]`   | Press -> activate preset bank 1                                                |
| Bank footswitch 2      | `GPIO_1[2]`   | Press -> activate preset bank 2                                                |
| Bank footswitch 3      | `GPIO_1[3]`   | Press -> activate preset bank 3                                                |
| Mute / tuner footswitch | `GPIO_1[4]`  | Tap to mute (OR'd with KEY[1]); while muted the HEX displays show the tuner  |
| Tap / mute LED          | `GPIO_1_LED` | Solid ON while muted; pulses at the current tap-tempo when unmuted           |
| Expression pedal        | ADC channel 0 (`ADC_DOUT`) | Drives FX 7 (Expression Gain); sweep adjusts overall chain volume |

All footswitches are momentary (active-low) - wire one terminal to the `GPIO_1` pin and through a 10K resistor then to ground; an internal pull-up on the FPGA holds the line high when not pressed. For the Expression pedal, the wiper is connected to the ADC channel and the other 2 pins are connect 2 ground and the 3.3V pin on the `GPIO` pins. The LED is connected to a `GPIO_1_LED`, which is `GPIO_5` through a 1k resistor into ground.

### Tuner

The on-board YIN-based pitch tracker is always running on the raw ADC input regardless of mute state. To use it:

1. Press `KEY[1]` (or the mute footswitch on `GPIO_1[4]`) to mute the audio chain.
2. While muted, the six HEX displays show the tuner output:
   * **`SW[9]` low -> note mode**: `HEX5`/`HEX4` show the note letter and `#` (sharp marker), `HEX3` shows the octave digit, `HEX0` shows a tuning indicator:
     * `V` - string is *flat*, tighten it (raise pitch).
     * `^` - string is *sharp*, loosen it (lower pitch).
     * `-` - within ±5 cents of the target note (in tune).
   * **`SW[9]` high -> frequency mode**: `HEX5–HEX4` show `Fr`, and `HEX3–HEX0` show the measured fundamental in Hz (e.g. `247` for B3).
3. The note classifier holds the displayed note for a ±10-cent hysteresis window past each chromatic boundary, so notes near the half-semitone line don't flicker between adjacent letters.
4. After ~500 ms of silence the display falls back to all dashes.

Press `KEY[1]` (or the mute footswitch) again to un-mute and resume audio processing.

### Bank Switching

Each of the four bank footswitches loads its corresponding preset bank from flash. The fade FSM ramps the DAC down -> flips `bank_sel` -> ramps back up over ~126 ms total to suppress the click that would otherwise occur when delay/reverb feedback paths and IIR coefficients change instantaneously.

### Tap Tempo

While unmuted, repeatedly tap the mute footswitch (or `KEY[1]`) on the beat. The controller measures the inter-tap interval and sets the delay time to that BPM. The tap-tempo LED pulses on each beat to confirm. Long-pressing the same switch (>500 ms) instead activates mute / tuner mode rather than registering as a tap.

### Expression Pedal

The expression pedal at FX 7 is a wet-only volume control inserted between the chorus and delay stages. With the pedal heel-down, the chain is silent at that point; Useful for swells and volume-controlled feedback into delay and reverb.

## Implemented Effects & Parameters

### Gain

Applies a gain multiplier to the signal.

**Parameters**

* `fx_gain`: Gain multiplier (0–255), where `32 = unity`. Values above 32 amplify; values below 32 attenuate.

The same `fx_gain` module is reused as **Input Gain (F0)**, **Output Gain (F10)**, **Expression Gain (F7)** (driven by the external expression pedal at FX 7), and **Global Gain (F15)**. The first three are bank-specific; the last is global — the controller mirrors writes to F15 across every bank's params slot, so adjusting it on one bank changes it on all of them, and a single save persists the value to flash.

---

### Gate

Noise gate with a soft-knee and adjustable floor gain. Signals above the threshold pass through at unity; signals below are attenuated toward the depth floor. The knee region smoothly transitions between open and closed rather than switching abruptly.

**Bypass behavior**: when `fx_threshold == 0` and `fx_knee == 0` the gate becomes a true wire - `audio_out = audio_in` with no multiplier on the path. This avoids the small per-sample LSB truncation the multiply otherwise produces on every positive sample.

**Parameters**

* `fx_threshold`: Gate open level (scaled to the full 16-bit signal range). Set to `0` together with `fx_knee = 0` for true bypass.
* `fx_attack`: Speed at which the gate opens after the signal exceeds the threshold (`0` = instant, `255` = slowest). Linear amplitude ramp.
* `fx_release`: Speed at which the gate closes after the signal falls below the threshold (`0` = instant, `255` = slowest). Linear amplitude ramp - for a smoother decay tail use higher values (~200–240).
* `fx_knee`: Soft-knee half-width - widens the transition region around the threshold (`0` = hard switch, `255` = widest knee).
* `fx_depth`: Gain floor when the gate is fully closed (`0` = full mute, `255` = unity - effectively bypasses gating).

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

Peak-envelope-based compressor with 8-sample lookahead that reduces signal levels above a threshold while leaving lower levels unchanged. Includes independent input and output gain stages and a parallel dry/wet blend for New York-style parallel compression.

**Bypass behavior**: at `fx_mix = 0` the wet term contributes 0 and the output collapses to the lookahead-delayed dry signal - mathematically a clean bypass with naturally-matched latency to any partial-mix value, so you can sweep `fx_mix` smoothly through 0 without timing artifacts. For a *bit-exact* unity-gain dry signal also set `fx_input_gain = 64` (the dry path is post-input-gain).

**Parameters**

* `fx_threshold`: Compression onset level (0–255, scaled to full 16-bit range)
* `fx_ratio`: Compression ratio - `0` = 1:1 (no compression), `255` = maximum ratio
* `fx_attack`: Time before gain reduction begins after exceeding the threshold (upper nibble controls slew rate)
* `fx_release`: Time before gain reduction is released after falling below the threshold (upper nibble controls slew rate)
* `fx_input_gain`: Pre-compression input gain (`64 = unity`)
* `fx_makeup_gain`: Post-compression output gain (`64 = unity`)
* `fx_mix`: Dry/wet blend (`0` = fully dry / mathematical bypass, `255` = ~99.6% wet)

---

### Distortion

Amp-style distortion that models the full signal chain of an overdriven guitar amplifier through seven processing stages.

**Bypass behavior**: at `fx_mix = 0` the entire wet chain (drive, clipping, DC blocker, makeup, and cabinet IIR) is bypassed at the output - `audio_out = audio_in`. This is important because the cabinet IIR runs continuously and accumulates per-sample truncation noise; bypassing it at mix=0 keeps banks that don't use distortion completely clean.

**Stability**: the cabinet IIR's pole coefficient is `safe_tone / 256` where `safe_tone = fx_tone + 10`. For `fx_tone ≥ 246` the raw value exceeds 256, which would make the IIR unstable and ring; the design clamps `safe_tone` at exactly 256 in that band so the cabinet stays at unity gain and never diverges.

The seven stages:

1. **Pre-emphasis** - A first-difference high-shelf filter (`emph = x + (x − x_prev) >> 2`) boosts the presence band (~3 kHz) before the signal hits the clipping stage, adding bite and pick attack to the distorted tone.

2. **Drive** - Multiplies the pre-emphasized signal by a gain in the range 1× to 32.875× (`drive_gain = 256 + fx_drive × 32`). Higher drive pushes more of the signal into the clipping region.

3. **Asymmetric bias** - A fixed +5% full-scale DC offset is added before clamping. This shifts the clipping threshold so positive and negative half-cycles clip at different levels, introducing even-order harmonics that give the distortion a warmer, more tube-like character.

4. **Soft clip (tanh approximation)** - The biased signal is passed through a 3rd-order polynomial approximation of `tanh(x)`, which smoothly compresses peaks rather than hard-squaring them:

   ```
           {  +2/3              , x ≥ +1
   f(x) =  {  x − x³/3          , −1 < x < 1
           {  −2/3              , x ≤ −1
   ```

   Division by 3 is approximated as `(x + x>>2 + x>>4 + x>>6) >> 2` (error ≤ 0.39%, inaudible).

5. **Wet/dry mix** - Blends the clipped signal with the original dry input (`0` = fully dry, `255` = ~99.6% wet), enabling parallel or blended distortion tones.

6. **Makeup gain** - Compensates for the level reduction caused by clipping (`128 = unity`).

7. **Cabinet simulation** - Two cascaded one-pole IIR low-pass filters (fc ≈ 4.4 kHz @ 48 kHz) roll off the harsh ultrasonic content produced by hard clipping, approximating the frequency response of a guitar speaker cabinet.

**Latency:** 6 samples.

**Parameters**

* `fx_drive`: Amount of gain into the clipping stage (`0` = 1× / unity, `255` ≈ 32.875×)
* `fx_makeup_gain`: Output level after clipping and cabinet simulation (`128 = unity`)
* `fx_bias`: Asymmetric DC bias added before clipping - controls the harmonic balance (more even-order harmonics at higher values, more "tube-like")
* `fx_sag`: Power-supply sag emulation depth - at high values the drive collapses briefly during loud transients, mimicking tube-amp compression
* `fx_tone`: Cabinet IIR cutoff (`0` = darkest / heaviest filtering, `246–255` = brightest / fully open with safe-tone clamp)
* `fx_tightness`: Pre-clip high-pass amount - higher values tighten low-end bloom under high gain
* `fx_smooth`: Post-clip low-pass amount - higher values reduce fizz / aliasing artifacts
* `fx_mix`: Dry/wet blend (`0` = true bypass, `255` = ~99.6% wet)

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

**Decay vs. size are independent.** `fx_size` scales the comb delay lengths (controls *what kind of room* - small = dense early reflections, large = sparse, spacious), and `fx_decay` selects the comb feedback gain in 4 discrete steps (controls *how long the tail rings*). This lets you set up small-room/long-tail or large-room/short-tail combinations that a single "size" parameter couldn't reach.

**Parameters**

* `fx_size`: Room size - scales all four comb filter delays (`0` = smallest / densest room, `255` = largest / most spacious)
* `fx_damping`: High-frequency damping of the reverb tail (`0` = bright / full HF content, `255` = dark / heavily damped)
* `fx_decay`: Tail length / RT60 - 4 discrete steps selected by the upper two bits:
  * `0–63` → short tail (~1–2 s at max delay)
  * `64–127` → medium (~3 s)
  * `128–191` → original behavior (~7-8 s)
  * `192–255` → long (~15+ s)
* `fx_mix`: Dry/wet blend (`0` = fully dry, `255` = ~99.6% wet)

---

## Tools, Technologies & Platform

* **FPGA Board:** DE1-SoC
* **HDL:** SystemVerilog
* **Algorithmic Prototyping:** Python
* **Audio Codec:** DE1-SoC on-board codec
* **Synthesis & Programming:** Intel Quartus
* **Simulation:** ModelSim