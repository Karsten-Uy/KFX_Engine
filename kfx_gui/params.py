"""
params.py — KFX Engine parameter metadata (names, ranges, special cases).

This table mirrors the FX/parameter layout defined in src/lab_pkg.sv and the
fx_* modules.  **lab_pkg.sv is canonical** — keep this in sync with it.

All parameters are 8-bit (0..255).  Unused FX slots (11-14) are omitted.
"""

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
