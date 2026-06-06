# KFX Engine — Arduino USB-MIDI Controller

This folder contains the Arduino firmware that turns the KFX Engine pedalboard
into a class-compliant **USB-MIDI controller**. The same footswitches and
expression pedal that drive the DE1-SoC FPGA DSP are wired in parallel to an
Arduino, so the controls can also drive a DAW or any MIDI software.

For the full controller/FPGA project, see the [top-level README](../README.md).
For the shared-control wiring (per-device pull-ups, series resistors, common
ground, and the ¼" TRS pedal connection), see [`docs/WIRING.md`](../docs/WIRING.md).

## Contents

| Sketch | Purpose |
| ------ | ------- |
| [`KFX_midi/KFX_midi.ino`](./KFX_midi/KFX_midi.ino) | Main USB-MIDI controller firmware |
| [`KFX_midi/KFX_midi.h`](./KFX_midi/KFX_midi.h) | Pin assignments, CC map, and timing/calibration constants |
| [`ButtonTest/ButtonTest.ino`](./ButtonTest/ButtonTest.ino) | Bring-up sketch that prints all digital/analog pin states to Serial for wiring verification |

## Hardware

* An Arduino with **native USB** (ATmega32U4-based: Leonardo, Micro, Pro Micro,
  or similar) — required for the [MIDIUSB](https://github.com/arduino-libraries/MIDIUSB)
  library to enumerate as a USB-MIDI device.
* 4 bank-select footswitches + 1 tap/mute footswitch (active-low).
* 1 TRS expression pedal (potentiometer).

The switches and pedal are shared with the FPGA — they are **not** exclusive to
the Arduino. Each input is pulled up on the Arduino side via `INPUT_PULLUP`.

### Pin map

| Control          | Arduino pin | Notes                              |
| ---------------- | ----------- | ---------------------------------- |
| Bank 1           | `D9`        | `INPUT_PULLUP`, active-low         |
| Bank 2           | `D8`        | `INPUT_PULLUP`, active-low         |
| Bank 3           | `D7`        | `INPUT_PULLUP`, active-low         |
| Bank 4           | `D6`        | `INPUT_PULLUP`, active-low         |
| Tap / mute       | `D5`        | `INPUT_PULLUP`, active-low         |
| Expression pedal | `A0`        | Pot wiper (Tip of the ¼" TRS jack) |

Pins are defined by `BUT_BIN[] = {9, 8, 7, 6}`, `BUT_TM = 5`, and `POT_EX = A0`
in [`KFX_midi.h`](./KFX_midi/KFX_midi.h).

## MIDI behavior

All messages are sent on **MIDI channel 1** (channel index 0).

* **Bank footswitches** — selecting a bank mutes the other three bank CCs and
  sends the active bank's CC **last**, so DAWs that map to the most recent MIDI
  event (e.g. Studio One 5) register the correct control. On a bank switch the
  current pedal value is re-sent on the new bank's CC so the parameter doesn't
  jump.
* **Tap / mute footswitch** — a tap sends a short delay-tap CC pulse; holding
  ~1 s toggles mute on. While muted, a quick tap-and-release unmutes (and does
  **not** emit a delay tap).
* **Expression pedal** — the wiper (`A0`) is mapped to `0–127` and sent on a
  per-bank CC. A small hysteresis (`POT_HYSTERSIS`) suppresses CC spam from
  analog jitter.

### Default CC map

| Control          | CC (per bank)                            |
| ---------------- | ---------------------------------------- |
| Bank select 1–4  | `80`, `81`, `82`, `83` (`ccValues_KB`)   |
| Expression pedal | `4`, `66`, `67`, `68` by active bank (`POT_CC_BANK`) |
| Delay tap        | `96` (`DEL_TAP_CC`)                      |
| Mute             | `120` (`MUTE_CC`)                        |

Edit these constants in [`KFX_midi.h`](./KFX_midi/KFX_midi.h) to match your DAW
mapping.

### Tunable constants

| Constant | Meaning |
| -------- | ------- |
| `DEBOUNCE_TIME` | Per-loop debounce delay (ms) |
| `TAP_PULSE_TIME` | Width of the delay-tap CC pulse (ms) |
| `MUTE_HOLD_TIME` | Hold duration to toggle mute (ms) |
| `POT_HYSTERSIS` | Minimum CC change before re-sending the pedal value |
| `POT_EX_START_VAL` / `POT_EX_END_VAL` | Raw `analogRead` range at heel / toe, used for calibration |

## Build & upload

1. Install the **Arduino IDE** (or `arduino-cli`).
2. Install the **MIDIUSB** library via the Library Manager
   (Tools → Manage Libraries → search "MIDIUSB").
3. Select your native-USB board under **Tools → Board**.
4. Open [`KFX_midi/KFX_midi.ino`](./KFX_midi/KFX_midi.ino), then Upload.
5. The board enumerates as a USB-MIDI device; open your DAW and map the CCs
   above (or use MIDI-learn).

To verify wiring first, upload [`ButtonTest/ButtonTest.ino`](./ButtonTest/ButtonTest.ino)
and open the Serial Monitor at **9600 baud** — it prints the live state of
digital pins 2–9 and analog pins A0–A5.
