"""
demo_mock.py — run the KFX Engine GUI with NO hardware, to try the UI / the
bank-switch swipe animation offline.

It reuses the existing FpgaEmu + MockTransport from test_protocol.py (a faithful
behavioral model of the board) behind the real protocol.Client, so the GUI talks
to it exactly as it would to the FPGA — only the transport is faked. Each of the
4 banks is preloaded with visibly different values so the vertical swipe between
banks is obvious.

Run:  uv run python demo_mock.py

Then just click the bank tabs (0 CLEAN / 1 CRUNCH / 2 LEAD / 3 AMBIENT):
  - clicking a HIGHER bank swipes the strips UP, a LOWER bank swipes DOWN.
Knobs/faders are fully interactive (writes go to the in-memory mock).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import protocol as P                          # noqa: E402
import params as M                            # noqa: E402
import gui                                    # noqa: E402
from test_protocol import FpgaEmu, MockTransport  # noqa: E402


def _seed_distinct_banks(emu):
    """Give each bank a clearly different parameter set so the swipe is visible.

    fx15 (Master) is global — the GUI always reads it from bank 0 — so it stays
    put across switches, which is the correct behavior to demonstrate."""
    bank_base = [40, 100, 160, 215]           # low / mid-low / mid-high / high
    for bank in range(P.BANK_COUNT):
        for fx in M.active_fx():
            for i, p in enumerate(M.active_params(fx)):
                v = (bank_base[bank] + fx * 9 + i * 13) % 256
                emu.params[P.dump_index(bank, fx, p)] = v


def main():
    emu = FpgaEmu()
    _seed_distinct_banks(emu)

    app = gui.KfxGui()

    # Inject the mock client the same way _on_connected would, minus the JTAG open.
    app.client = P.Client(MockTransport(emu))
    app.conn_lbl.config(text="Connected — MOCK (no board)")
    app.set_connected(True)
    app.refresh()                              # initial read of bank 0 (no swipe)

    app.mainloop()


if __name__ == "__main__":
    main()
