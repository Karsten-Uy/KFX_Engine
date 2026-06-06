# KFX Engine — Wiring Guide

This document describes how the physical controls (footswitches, tap/mute
switch, expression pedal, and tap LED) are wired between the **DE1-SoC FPGA
board** and the **Arduino (MIDIUSB)**.

## Overview

The five footswitches are **shared** between the FPGA and the Arduino: the
FPGA reads them for on-board DSP control while the Arduino reads the same
switches to emit USB-MIDI to a DAW. Both devices read the switches as
**active-low** (pressed = logic LOW).

Key facts about the topology:

- **Each input pulls itself up.** There is no single shared pull-up rail.
  The **FPGA configures its own (internal) pull-up** on each GPIO, and the
  **Arduino** branch is pulled up by the MCU's internal `INPUT_PULLUP`. Each
  path (to the FPGA and to the Arduino) effectively has its own pull-up.
- A switch only ever **shorts its node to the common ground** when pressed —
  it never sources current, so both pulled-up inputs read LOW together.
- **Ground is common** across the DE1-SoC, the Arduino, and the pedal.
- Each switch node fans out through a **series resistor to the FPGA** and a
  **series resistor to the Arduino**, so neither input can drive the other.
- The **tap/status LED** is driven **only by the DE1-SoC** (`GPIO_1_LED`).
- The **potentiometer** is wired to a **1/4" TRS output jack**, which connects
  via a TRS cable to the **TRS input jack on the expression pedal**. Its
  **wiper feeds both** the Arduino analog input (`A0`) and the DE1-SoC ADC
  input (`ADC_DOUT`).

## Block diagram

```
              DE1-SoC (FPGA)                         Arduino
       ┌──────────────────────────┐          ┌──────────────────┐
       │  GPIO_1[0] bank 1  <───── │          │  D9  bank 1      │
       │  GPIO_1[1] bank 2  <───── │          │  D8  bank 2      │
       │  GPIO_1[2] bank 3  <───── │          │  D7  bank 3      │
       │  GPIO_1[3] bank 4  <───── │          │  D6  bank 4      │
       │  GPIO_1[4] mute    <───── │          │  D5  tap/mute    │
       │                           │          │                  │
       │  ADC_DOUT (pedal)  <───── │          │  A0  (pedal)     │
       │  GPIO_1_LED ──────► LED   │          │                  │
       │  GND ───────────────────  │ ──────── │  GND  (common)   │
       └──────────────────────────┘          └──────────────────┘

   One switch shown (×5: 4 bank + 1 tap/mute).
   Each side pulls itself up; the switch only shorts the node to GND:

     (FPGA VCC)                         (Arduino 5V)
         │                                   │
      [ Rpu_fpga ]  ← FPGA internal       [ Rpu_ard ]  ← Arduino INPUT_PULLUP
         │              pull-up               │
   FPGA  ┤                                    ├  Arduino
  GPIO_1[n] ──[ Rs_fpga ]──┐      ┌──[ Rs_ard ]── Dn
                           │      │
                           |______|
                           │      
                        ( switch )
                           │
                          GND   pressed → node to GND → both read LOW

   Expression pedal (potentiometer → 1/4" TRS out → cable → pedal TRS in):

     +3.3V ──[ pot top ]──────────────────────────► Ring  ┐
                  │                                        │ 1/4"      TRS      TRS in
               ( wiper )──┬──► Arduino A0                  ├─ TRS  ===cable===►  jack on
                  │       └──► DE1-SoC ADC_DOUT ─────► Tip │ output             expression
      GND ──[ pot bottom ]──────────────────────► Sleeve  ┘ jack               pedal
                  │
                 GND (common)

   Tap / status LED (DE1-SoC only):

     (LED VCC) ──[ Rpu_led pull-up ]──┬── LED ──  GPIO_1_LED (FPGA drives LOW to light)
                                      │
                                   (anode/cathode orientation per board)
```

## Footswitch / button pin map

| Control      | Function                       | FPGA signal  | Arduino pin | Active |
|--------------|--------------------------------|--------------|-------------|--------|
| Bank 1       | Select preset bank 0           | `GPIO_1[0]`  | `D9`        | LOW    |
| Bank 2       | Select preset bank 1           | `GPIO_1[1]`  | `D8`        | LOW    |
| Bank 3       | Select preset bank 2           | `GPIO_1[2]`  | `D7`        | LOW    |
| Bank 4       | Select preset bank 3           | `GPIO_1[3]`  | `D6`        | LOW    |
| Tap / Mute   | Tap tempo; hold ~1 s to mute   | `GPIO_1[4]`  | `D5`        | LOW    |

> Arduino bank pins come from `BUT_BIN[] = {9, 8, 7, 6}` and the tap/mute pin
> from `BUT_TM = 5` in [KFX_midi.h](../Arduino/KFX_midi/KFX_midi.h). The FPGA
> mapping (`GPIO_1[3:0]` banks, `GPIO_1[4]` mute) is in
> [AudioFX.sv](../src/AudioFX.sv).

## LED and pedal

| Signal      | Owner    | FPGA signal   | Arduino pin | Notes                                              |
|-------------|----------|---------------|-------------|----------------------------------------------------|
| Tap LED     | DE1-SoC  | `GPIO_1_LED`  | —           | Pulled up; FPGA sinks current to light it. Solid when muted, pulses at tap tempo. |
| Pedal wiper | shared   | `ADC_DOUT`    | `A0`        | Pot → 1/4" TRS out → cable → pedal TRS in. Wiper (Tip) feeds both ADC inputs. |

The potentiometer is brought out to a **1/4" TRS output jack** — top to Ring,
wiper to Tip, bottom to Sleeve/GND — and a standard TRS cable carries it to the
**TRS input jack on the expression pedal**. The Arduino reads the wiper on `A0`
and maps it (`POT_EX_START_VAL` .. `POT_EX_END_VAL` → `0..127`) to a MIDI CC
that depends on the active bank (`POT_CC_BANK[]`). The DE1-SoC samples the same
wiper through `ADC_DOUT` for its on-board expression-gain FX.

## Notes / assumptions

- **Active-low rationale.** Each side pulls its own input up — the FPGA via
  its configured internal pull-up (`Rpu_fpga`) and the Arduino via
  `INPUT_PULLUP` (`Rpu_ard`) — so an idle (open) switch reads HIGH and a
  pressed switch (node tied to GND) reads LOW on both devices independently.
  There is no single shared pull-up rail.
- **Series resistors** (`Rs_fpga`, `Rs_ard`) isolate the two inputs and limit
  current; a typical value is ~1 kΩ. Tune to match your hardware.
- **LED pull-up.** The tap LED also has a pull-up resistor (`Rpu_led`); the
  FPGA drives `GPIO_1_LED` LOW to sink current and light it.
- **Common ground is mandatory.** The Arduino, DE1-SoC, and pedal must share
  ground or the active-low logic levels will not be valid across boards.
