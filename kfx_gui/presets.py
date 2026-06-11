"""
presets.py — export/import the 4 banks as human-readable JSON.

Export reads the whole board (one DUMP) and writes a name-keyed JSON file.
Import writes the values back parameter-by-parameter (skipping the read-only
Expression gain; the global Master Gain is written once and mirrored by the
FPGA across all banks).
"""
import os
import sys
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import protocol as P  # noqa: E402
import params as M    # noqa: E402

PRESET_VERSION = 1


def export_preset(client: P.Client, path: str) -> None:
    data = client.dump()
    banks = []
    expression = []
    for bank in range(P.BANK_COUNT):
        fxd = {}
        for fx in M.active_fx():
            if M.is_global(fx) or fx == 7:
                continue
            fxd[M.fx_name(fx)] = {
                M.param_name(fx, p): data[P.dump_index(bank, fx, p)]
                for p in M.active_params(fx)
            }
        banks.append({"name": M.bank_name(bank), "fx": fxd})
        expression.append(data[P.dump_index(bank, 7, 0)])

    doc = {
        "version": PRESET_VERSION,
        "tool": "kfx-engine",
        "banks": banks,
        "global": {M.fx_name(15): {M.param_name(15, 0): data[P.dump_index(0, 15, 0)]}},
        "_expression_readonly": expression,  # snapshot only; not written on import
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)


def parse_preset(path: str) -> tuple[list[tuple[int, int, int, int]], list[str]]:
    """Parse a preset file into a flat list of (bank, fx, param, value) writes.

    Pure parsing — no board I/O — so callers (e.g. the GUI) can reflect the file
    on screen immediately before the slow per-parameter writes go out over JTAG.
    Read-only slots are skipped; unknown FX/params are dropped with a warning.
    """
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)

    warnings: list[str] = []
    entries: list[tuple[int, int, int, int]] = []

    if doc.get("version") != PRESET_VERSION:
        warnings.append(f"file version {doc.get('version')} != {PRESET_VERSION}; trying anyway")

    for bank, bankobj in enumerate(doc.get("banks", [])):
        for fxname, pd in bankobj.get("fx", {}).items():
            fx = M.fx_by_name(fxname)
            if fx is None:
                warnings.append(f"unknown FX '{fxname}' (skipped)")
                continue
            for pname, val in pd.items():
                p = M.param_by_name(fx, pname)
                if p is None:
                    warnings.append(f"unknown param '{fxname}/{pname}' (skipped)")
                    continue
                if M.is_read_only(fx, p):
                    continue
                entries.append((bank, fx, p, int(val) & 0xFF))

    for fxname, pd in doc.get("global", {}).items():
        fx = M.fx_by_name(fxname)
        if fx is None:
            warnings.append(f"unknown global FX '{fxname}' (skipped)")
            continue
        for pname, val in pd.items():
            p = M.param_by_name(fx, pname)
            if p is None:
                warnings.append(f"unknown global param '{fxname}/{pname}' (skipped)")
                continue
            entries.append((0, fx, p, int(val) & 0xFF))  # FPGA mirrors FX15

    return entries, warnings


def write_entries(client: P.Client, entries: list[tuple[int, int, int, int]]) -> int:
    """Write pre-parsed (bank, fx, param, value) entries to the board."""
    for bank, fx, p, val in entries:
        client.write_param(bank, fx, p, val)
    return len(entries)


def import_preset(client: P.Client, path: str) -> tuple[int, list[str]]:
    """Write a preset file to the board. Returns (count_written, warnings)."""
    entries, warnings = parse_preset(path)
    return write_entries(client, entries), warnings
