"""
params.py — KFX Engine parameter metadata (names, ranges, special cases).

This table mirrors the FX/parameter layout defined in src/lab_pkg.sv and the
fx_* modules.  **lab_pkg.sv is canonical** — keep this in sync with it.

All parameters are 8-bit (0..255).  Unused FX slots (11-14) are omitted.
"""

import math

PARAM_MIN = 0
PARAM_MAX = 255

BANK_NAMES = ["CLEAN", "CRUNCH", "LEAD", "AMBIENT"]

# fx index -> (display name, {param index: param name})
FX = {
    0:  ("Input Gain",  {0: "gain"}),
    1:  ("Noise Gate",  {0: "threshold", 1: "attack", 2: "release", 3: "knee", 4: "depth"}),
    2:  ("EQ 1 (pre)",  {0: "sub", 1: "low", 2: "mid", 3: "high"}),
    3:  ("Compressor",  {0: "threshold", 1: "ratio", 2: "attack", 3: "release",
                         4: "in gain", 5: "makeup", 7: "mix"}),
    4:  ("Distortion",  {0: "drive", 1: "makeup", 2: "bias", 3: "sag", 4: "tone",
                         5: "tightness", 6: "smooth", 7: "mix"}),
    5:  ("EQ 2 (post)", {0: "sub", 1: "low", 2: "mid", 3: "high"}),
    6:  ("Chorus",      {0: "rate", 1: "depth", 7: "mix"}),
    7:  ("Expression",  {0: "gain"}),   # read-only: driven by the expression pedal/pot
    8:  ("Delay",       {0: "time", 1: "feedback", 7: "mix"}),
    9:  ("Reverb",      {0: "size", 1: "damping", 2: "decay", 3: "mod depth",
                         4: "diffusion", 5: "predelay", 6: "width", 7: "mix"}),
    10: ("Output Gain", {0: "gain"}),
    15: ("Master Gain", {0: "gain"}),   # global: mirrored across all banks by the FPGA
}

# (fx, param) pairs the host must not write (FPGA NACKs them anyway)
READ_ONLY = {(7, 0)}

# FX slots that are global (one value shared across all banks)
GLOBAL_FX = {15}


def active_fx():
    """FX indices that have parameters, in display order."""
    return sorted(FX.keys())


def fx_name(fx: int) -> str:
    return FX[fx][0]


def active_params(fx: int):
    """Param indices for an FX, in order."""
    return sorted(FX[fx][1].keys())


def param_name(fx: int, param: int) -> str:
    return FX[fx][1][param]


def is_read_only(fx: int, param: int) -> bool:
    return (fx, param) in READ_ONLY


def is_global(fx: int) -> bool:
    return fx in GLOBAL_FX


def bank_name(bank: int) -> str:
    return BANK_NAMES[bank] if 0 <= bank < len(BANK_NAMES) else f"Bank {bank}"


# reverse lookups (for preset import by name)
def fx_by_name(name: str):
    for idx, (nm, _) in FX.items():
        if nm == name:
            return idx
    return None


def param_by_name(fx: int, name: str):
    for idx, nm in FX[fx][1].items():
        if nm == name:
            return idx
    return None


# ---------------------------------------------------------------------------
# Display conversion — raw 8-bit byte <-> human units
#
# The FPGA always stores/transmits the raw 0..255 byte; these helpers only
# change how a value is shown and typed in the GUI.  Two converted kinds:
#
#   dB  : every gain-like param.  The byte is a linear multiplier the DSP
#         applies as (sample * byte) >> shift, so the byte maps to gain
#         relative to a reference R (= 1<<shift, the unity/flat point):
#             dB = 20*log10(byte / R)        byte 0 -> -inf (muted)
#         R per param (mirrors the shifts in the fx_* modules):
#             fx_gain (in/out/master/expr) >>5  -> R=32
#             compressor in-gain / makeup  >>6  -> R=64
#             distortion makeup            >>7  -> R=128
#             EQ band gains (fx_eq)        >>8, flat detent at 128 -> R=128
#   pct : wet/dry mix.  DSP blends (wet-dry)*byte>>8; shown 0..100% across
#         the full byte range:  pct = byte/255*100.
#
# Anything not listed stays a raw 0..255 integer.
# ---------------------------------------------------------------------------
DB_REF = {
    (0, 0): 32, (10, 0): 32, (15, 0): 32, (7, 0): 32,   # in / out / master / expr
    (3, 4): 64, (3, 5): 64,                             # compressor in-gain, makeup
    (4, 1): 128,                                        # distortion makeup
    (2, 0): 128, (2, 1): 128, (2, 2): 128, (2, 3): 128,  # EQ 1 bands
    (5, 0): 128, (5, 1): 128, (5, 2): 128, (5, 3): 128,  # EQ 2 bands
}

MIX = {(3, 7), (4, 7), (6, 7), (8, 7), (9, 7)}

_INF_TOKENS = {"-inf", "inf", "-∞", "∞", "mute"}


def _to_pct(v: int) -> int:
    return int(round(v / 255.0 * 100.0))


def fmt_value(fx: int, param: int, v, compact: bool = False) -> str:
    """Raw byte -> display string with units (e.g. '+3.5 dB', '0.0 dB', '50%').

    compact=True drops the ' dB' suffix and the leading '+' (e.g. '3.5', '-0.5',
    '0.0') for dense readouts like the graphic-EQ band sliders.
    """
    v = int(round(v))
    r = DB_REF.get((fx, param))
    if r is not None:
        if v <= 0:
            return "-inf"
        db = 20.0 * math.log10(v / float(r))
        if compact:
            return "0.0" if abs(db) < 0.05 else "%.1f" % db
        return "0.0 dB" if abs(db) < 0.05 else "%+.1f dB" % db
    if (fx, param) in MIX:
        return "%d%%" % _to_pct(v)
    return str(v)


def edit_str(fx: int, param: int, v) -> str:
    """Raw byte -> bare number shown while editing (no unit suffix).

    A muted dB band edits as '-60.0', which parses back to byte 0, so the
    mute state round-trips through the inline editor.
    """
    v = int(round(v))
    r = DB_REF.get((fx, param))
    if r is not None:
        if v <= 0:
            return "-60.0"
        return "%.1f" % (20.0 * math.log10(v / float(r)))
    if (fx, param) in MIX:
        return "%d" % _to_pct(v)
    return str(v)


def parse_value(fx: int, param: int, text: str):
    """Display/bare text -> clamped raw byte, or None if unparseable (revert)."""
    s = text.strip().lower()
    for tok in ("db", "%", "x", "×"):
        if s.endswith(tok):
            s = s[: -len(tok)].strip()
    if s == "":
        return None
    r = DB_REF.get((fx, param))
    if r is not None and s in _INF_TOKENS:
        return 0
    try:
        x = float(s)
    except ValueError:
        return None
    if r is not None:
        b = r * (10.0 ** (x / 20.0))
    elif (fx, param) in MIX:
        b = x / 100.0 * 255.0
    else:
        b = x
    return max(PARAM_MIN, min(PARAM_MAX, int(round(b))))


def display_width(fx: int, param: int, compact: bool = False) -> int:
    """Character width the inline readout needs for this param's format."""
    if (fx, param) in DB_REF:
        return 5 if compact else 9   # "-12.0" / "-inf"  vs  "+18.0 dB" (+1 slack)
    if (fx, param) in MIX:
        return 5   # e.g. "100%"
    return 3       # raw 0..255
