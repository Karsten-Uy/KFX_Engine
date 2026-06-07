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
  via a TRS cable to the **TRS input jack on the expression pedal**. Its wiper
  is buffered by a **unity-gain LM358 op-amp** on the DE1-SoC board, and the
  buffer output **feeds both** the Arduino analog input (`A0`) and the DE1-SoC
  ADC input (`ADC_DOUT`). The buffer is essential: without it, the Arduino's
  power state loads the shared wiper node and roughly halves the DE1-SoC reading
  (the buffer is powered from the **DE1-SoC 5 V** so the pedal works whether or
  not the Arduino is connected).

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

   Expression pedal (potentiometer → 1/4" TRS out → cable → pedal TRS in).
   The wiper (Tip) returns to a unity-gain LM358 buffer; the buffer output —
   not the bare wiper — drives both ADC inputs:

     +3.3V ──[ pot top ]──────────────────────────► Ring  ┐
                  │                                        │ 1/4"      TRS      TRS in
               ( wiper )───► (to LM358 buffer, below)      ├─ TRS  ===cable===►  jack on
                  │                                  ► Tip │ output             expression
      GND ──[ pot bottom ]──────────────────────► Sleeve  ┘ jack               pedal
                  │
                 GND (common)

   Wiper buffer — LM358P, V+ = DE1-SoC 5V (GPIO VCC5, pin 11), V- = GND:

        DE1-SoC 5V ──┬──[ 0.1uF ]── GND        (decoupling at the chip)
                     │
                  ┌──┴──────┐
     Tip (wiper)─►│+ \      │
                  │    >─────┼──┬───────────────────────► DE1-SoC ADC_DOUT  (direct)
               ┌─►│- /      │  ├──[ 3.3k–4.7k Rs_ard ]──► Arduino A0
               │  └────┬────┘  │
               │       │ out  [ 10k ]   pull-down → clean heel (~0 V)
               └───────┴───────┴── GND
              (unity-gain feedback)

     Rs_ard: series resistor on the A0 branch ONLY.  With the Arduino unpowered
             the buffer would otherwise hold A0 at ~3 V and back-feed current
             through A0's ESD diode into the dead 5 V rail (visible as a faint LED
             on the unplugged Arduino at full toe).  3.3k–4.7k limits that
             injection to <1 mA; when the Arduino IS powered A0 is high-Z, so the
             drop across it is negligible and the reading is unaffected.  The FPGA
             branch stays direct so the LTC2308 gets a low-impedance drive.
     Power : V+ = DE1-SoC 5V — NOT 3.3 V (LM358 in/out range stops ~1.5 V below
             V+, so 3.3 V would clip above ~1.8 V), and NOT Arduino 5 V (it would
             die when the Arduino is unplugged, defeating standalone operation).
     Unused: tie the 2nd LM358 op-amp as a follower — +in → GND, out → its -in.

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
| Pedal wiper | shared   | `ADC_DOUT`    | `A0`        | Pot → 1/4" TRS out → cable → pedal TRS in. Wiper buffered by an LM358; buffer output feeds the DE1-SoC ADC directly and `A0` through a 3.3k–4.7k series resistor. |

The potentiometer is brought out to a **1/4" TRS output jack** — top to Ring,
wiper to Tip, bottom to Sleeve/GND — and a standard TRS cable carries it to the
**TRS input jack on the expression pedal**. The returning wiper passes through a
**unity-gain LM358 buffer** (powered from the DE1-SoC 5 V) before fanning out, so
neither ADC loads the wiper and the reading is independent of whether the Arduino
is powered. The Arduino reads the buffered wiper on `A0` and maps it
(`POT_EX_START_VAL` .. `POT_EX_END_VAL` → `0..127`) to a MIDI CC that depends on
the active bank (`POT_CC_BANK[]`). The DE1-SoC samples the same buffered wiper
through `ADC_DOUT` for its on-board expression-gain FX.

> **Why the buffer (and why the DE1-SoC 5 V).** The pot is driven from 3.3 V but
> the LTC2308 ADC reference is higher (~4 V), so the wiper only reaches ~3.08 V
> and the raw 12-bit reading never hits full scale. Worse, when **both** the
> DE1-SoC ADC and the Arduino `A0` are wired *directly* to the same node — the
> bare wiper, or even the buffer output with no isolation — the two inputs
> interact, so the DE1-SoC reading depends on whether the Arduino is connected:
> **connecting (powering) the Arduino makes the DE1-SoC reading go up.** That is
> because an *absent or unpowered* Arduino `A0` (its ESD clamp diodes to a 0 V
> rail) loads the shared node down and drags the DE1-SoC reading toward half
> (≈127/255), while a *live* `A0` is high-impedance and stops loading it — so the
> reading rises. A high-impedance op-amp follower fixes this: its input doesn't
> load the pot, and its low-impedance output drives both ADCs identically
> regardless of the Arduino's power state. The buffer removes the loading; the
> firmware then rescales the measured raw heel/toe range to a full 0–255
> (`POT_RAW_MIN`/`POT_RAW_MAX` in [controller.sv](../src/control/controller.sv)).
> Powering the buffer from the DE1-SoC 5 V (not the Arduino's) keeps the pedal
> working standalone.
>
> **Why the A0 series resistor (`Rs_ard`).** The same back-feed that loaded the
> wiper also lights a faint LED on the *unplugged* Arduino at full toe — the
> buffer output would keep doing this (now sourced by the op-amp). A 3.3k–4.7k
> series resistor on the A0 branch limits that injection current to <1 mA, so it
> can't back-power or stress the pin, while leaving the powered reading untouched
> (A0 is high-Z when alive). This mirrors the footswitch isolation resistors;
> the pedal simply never had one.

### Expression-pedal buffer — LM358P pin map

Op-amp **A** (pins 1–3) is the follower; op-amp **B** (pins 5–7) is parked unused.

| Pin | Name | Connect to |
|-----|------|-----------|
| 1   | OUT1 | output node → DE1-SoC ADC input (direct), `A0` via `Rs_ard` (3.3k–4.7k), pin 2 (feedback), 10 kΩ → GND |
| 2   | IN1− | pin 1 (unity-gain feedback) |
| 3   | IN1+ | pedal wiper (TRS Tip) |
| 4   | V−   | GND (common) |
| 5   | IN2+ | GND (park unused op-amp) |
| 6   | IN2− | pin 7 |
| 7   | OUT2 | pin 6 |
| 8   | V+   | DE1-SoC 5 V (GPIO VCC5, ~pin 11); 0.1 µF → GND at the chip |

Discrete parts: **1× LM358P**, **1× 0.1 µF** ceramic (decoupling, pin 8→GND),
**1× 10 kΩ** (output pull-down, pin 1→GND), **1× 3.3k–4.7k** (A0 series, `Rs_ard`).

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
