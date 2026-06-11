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

Click **Connect**, pick a **Bank**, drag sliders (writes live on release),
**Reset Bank/All**, **Save/Load Flash**, or **Export/Import** a preset JSON.
The Expression gain (FX7) is read-only (the hardware pedal drives it); Master
Gain (FX15) is global and mirrored across all banks.

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
