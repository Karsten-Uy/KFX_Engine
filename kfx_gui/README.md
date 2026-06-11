# kfx_gui — KFX Engine Host Parameter Tool

PC-side suite to read, edit, reset, and save the pedalboard's effect parameters
over the **JTAG-UART** (the on-board USB-Blaster cable you already use to
program the board). The Arduino keeps doing MIDI independently — this tool does
not touch it.

Managed with [`uv`](https://docs.astral.sh/uv/).

## Layout

| File | Purpose |
| ---- | ------- |
| `protocol.py` | Byte protocol + transports + `Client`; also a CLI (wire format: [`../PROTOCOL.md`](../PROTOCOL.md)) |
| `params.py`   | FX / parameter names & ranges (mirrors `src/lab_pkg.sv`) |
| `presets.py`  | Export / import the 4 banks as JSON |
| `gui.py`      | Tkinter desktop editor (Python stdlib) |
| `test_protocol.py` | Offline self-test (mock FPGA, no hardware) |
| `pyproject.toml` | `uv` project + dependencies |

## Setup (uv)

All commands run from inside this `kfx_gui/` folder.

```
uv sync                         # create .venv and install intel-jtag-uart (Tkinter is stdlib)
```

Other prerequisites:

1. **Program the board** with the FPGA build that includes the `JtagUart` IP +
   `host_if`.
2. **Quartus installed** — `intel-jtag-uart` wraps Quartus's `jtag_atlantic`
   library. Put Quartus `bin64` on your `PATH` (e.g.
   `C:\intelFPGA\18.1\quartus\bin64`) so the DLLs load.
3. **Release any other JTAG session** first — close `nios2-terminal`, the
   Programmer's auto-detect, or any SignalTap session, or the UART won't open.
   (Also close this tool before re-programming the FPGA.)

## Quick check (no hardware)

```
uv run python test_protocol.py     # mock FPGA; prints ALL PROTOCOL TESTS PASSED
```

## CLI

```
uv run python protocol.py ping
uv run python protocol.py dump
uv run python protocol.py read  <bank> <fx> <param>
uv run python protocol.py write <bank> <fx> <param> <value>
uv run python protocol.py reset <scope> [bank] [fx] [param]   # scope 0=param 1=fx 2=bank 3=all
uv run python protocol.py save                                 # persist to flash (~3 s, mutes)
uv run python protocol.py load
```

Example: set Bank 2 (LEAD) reverb mix to 90 → `uv run python protocol.py write 2 9 7 90`

## GUI

```
uv run python gui.py
```

Click **Connect**, pick a **Bank**, drag a knob/fader (it streams to the board
in real time as you drag), **Reset Bank/All**, **Save/Load Flash**, or
**Export/Import** a preset JSON. The Expression gain (FX7) is read-only (the
hardware pedal drives it); Master Gain (FX15) is global and mirrored across all
banks.

### Controls

#### Editing a parameter

Every knob, fader, EQ band, and the reverb tail selector edits one parameter.
Edits apply to the board **live** — you hear them immediately — but they live in
the board's volatile working RAM until you **Save Flash** (see below).

| Gesture | Effect |
| ------- | ------ |
| **Drag** a knob / fader / EQ slider (up–down, or left–right on the rack faders) | Sweeps the value; it **streams to the board in real time** while you drag, not just when you release. Writes are coalesced so the JTAG link is never flooded. |
| **Mouse wheel** over a control | Nudge the value ±1. |
| **Double-click** a control | Reset just that one parameter to its factory default. |
| Click the **numeric readout** and type | Enter a value directly — **Enter** applies, **Esc** cancels. |
| **Reverb decay** (4-step selector) | Click a tail length: SHORT / MED / ORIG / LONG. |

Read-only slots (the Expression Gain, FX7 — driven by the hardware pedal) can't
be dragged; their readout still updates live as the pedal moves.

#### Banks

The tabs **0 CLEAN / 1 CRUNCH / 2 LEAD / 3 AMBIENT** pick which of the four
preset banks you view and edit; switching tabs re-reads that bank from the board.
**Follow** (top-right toggle) snaps the view to whatever bank the pedal is
currently live on, so the GUI tracks foot-switch bank changes; turn it off to
pin the view to one bank while the pedal is on another.

#### Toolbar buttons

| Button | What it does |
| ------ | ------------ |
| **Connect / Reconnect** | Open the JTAG-UART and ping the firmware. |
| **Read** | Re-read the current bank's parameters from the board and refresh the display (e.g. after an external change). |
| **Reset Bank** | Reset the current bank's parameters to factory defaults (live, on the board — not yet saved to flash). |
| **Reset All** | Reset **all four** banks to factory defaults (asks to confirm first). |
| **Save Flash** | Persist the presets to non-volatile flash — see below. |
| **Load Flash** | Reload the presets from flash — see below. |
| **Export** | Save the four banks to a JSON file on the PC. |
| **Import** | Load banks from a JSON file and write them to the board. |

#### Save Flash vs. Load Flash

The board keeps two copies of the presets: a **live working set in RAM** (what
the audio chain actually uses, and what your edits change instantly) and a
**saved copy in the on-board EPCQ flash** (non-volatile — it survives a power
cycle). Editing a control only touches the working RAM; flash is untouched until
you explicitly save.

- **Save Flash** copies the current state of **all four banks** from working RAM
  into flash in one shot — not just the bank you're viewing. The board erases
  and rewrites a flash sector, which takes **~3 seconds and mutes the audio**
  while it runs (the GUI shows a "Saving to flash — audio muted" overlay). After
  it finishes, the presets are stored permanently and (if the design was
  programmed as a power-persistent `.jic`) reload automatically on the next
  power-up. Dial in all four banks, then save once.

- **Load Flash** does the reverse: it copies the four banks **from flash back
  into working RAM**, overwriting your current edits. Use it to revert to the
  last saved state. If the flash has never been saved (no valid data sentinel),
  the load safely aborts and leaves the working RAM untouched.

So the rule of thumb: **edits are live but temporary; Save Flash makes them
permanent; Load Flash throws away unsaved edits and restores the last save.**

### Launch as a Windows app (no terminal)

Double-click [`launch_kfx_gui.vbs`](./launch_kfx_gui.vbs) — it starts the GUI
from this folder with **no console window** (it uses the venv's `pythonw.exe`,
falling back to `uv run` if the venv is missing).

To add a **Start Menu** entry (searchable, pinnable), run once:

```
powershell -ExecutionPolicy Bypass -File install_shortcut.ps1
```

Then open Start, search **"KFX Engine GUI"**, and right-click → **Pin to Start**
or **Pin to taskbar**. The shortcut points back at this repo, so editing
`gui.py` (or `git pull`) updates the app on the next launch — nothing is bundled
or frozen. To see startup errors (the no-console launcher hides them), run
`uv run python gui.py` from a terminal.

## Notes

- The **wire protocol** (request/response frames, opcodes, error codes,
  checksums, the JTAG transport stack, and worked byte-level examples) is
  specified in [`../PROTOCOL.md`](../PROTOCOL.md). The FPGA side that parses it is
  [`../src/control/host_if.sv`](../src/control/host_if.sv); keep the two in sync.
- `params.py` mirrors `src/lab_pkg.sv` by hand — keep them in sync if you change
  the FX/parameter layout. Factory defaults are read live from the board, so
  "reset to default" always matches the hardware.
- The protocol is transport-agnostic: to use a plain USB-serial UART instead of
  JTAG later, add a `SerialTransport` (pyserial) implementing
  `write` / `read` / `flush_input` and pass it to `Client`.
