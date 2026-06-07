"""
gui.py — KFX Engine parameter editor, redesigned as a DAW-style mixer console.

The whole view/presentation layer is drawn to look and feel like a modern mixer
(Studio One / Logic / Cubase): a horizontal row of channel strips, each with a
colored name plate, rotary knobs / graphic-EQ sliders, and a tall vertical
fader. The global gain becomes a gold MASTER strip on the far right.

This view matches the "KFX Mixer Console" design prototype. Per the final design
iterations: no volume meters and no bypass toggles (the board has neither), the
knob-less gain stages and the master run their faders full-height, each effect
gets one bigger "hero" knob, and Reverb's decay is a 4-step tail selector.

Only the view changed. The backend interface is untouched:
  protocol  as P   — P.Client, P.JtagTransport, P.dump_index, P.BANK_COUNT,
                     P.SCOPE_BANK, P.SCOPE_ALL, P.ProtocolError, and the
                     client.ping/dump/write_param/reset/save_flash/load_flash calls
  params    as M   — active_fx, active_params, fx_name, param_name, is_global,
                     is_read_only, bank_name, PARAM_MIN, PARAM_MAX
  presets          — export_preset / import_preset

ALL structure (which FX exist, which params, names, ranges, global/read-only
flags) is derived from the M.* helpers so the UI stays in sync with the model;
nothing about the FX list is hardcoded.

NOTE on names: this model's M.param_name() returns short display names
("gain", "mix", "drive", "sub", "in gain", "mod depth", ...), NOT the SystemVerilog
fx_* identifiers. All the name-keyed logic below (category, fader selection, EQ
detection, reset references, labels) is keyed off those short names.

Run:  uv run python gui.py
"""
import os
import sys
import math
import queue
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import protocol as P  # noqa: E402
import params as M    # noqa: E402
import presets        # noqa: E402

import tkinter as tk                                   # noqa: E402
import tkinter.font as tkfont                          # noqa: E402
from tkinter import filedialog, messagebox             # noqa: E402

# ----------------------------------------------------------------------------
# Palette — dark, professional console look
# ----------------------------------------------------------------------------
BG        = "#1e1f24"   # near-black charcoal window
PANEL     = "#26272e"   # channel strip panel
PANEL_HI  = "#2c2d35"   # raised
PANEL_LO  = "#202127"   # recessed wells
SEP       = "#33343d"   # thin separators
INK       = "#e7e8ec"
DIM       = "#9a9ca6"
FAINT     = "#6c6e78"
READOUT   = "#f2f3f6"
WELL      = "#0e0f12"
HEADER_INK = "#12130f"  # dark text on colored name plate

# Global UI scale. The whole console (knobs, faders, EQ sliders, fonts, the
# strip widths derived from them) shrinks/grows with this one number so the full
# channel set — including the Master strip — fits the screen. Lower = smaller.
# Bump down toward ~0.7 on small / high-DPI laptops, up to 1.0 on big monitors.
SCALE = 0.85


def sc(x):
    """Scale a pixel dimension by SCALE (min 1)."""
    return max(1, int(round(x * SCALE)))


def fsz(pt):
    """Scale a font point size by SCALE (min 6 so text stays legible)."""
    return max(6, int(round(pt * SCALE)))


# per-strip height floor: header + body + fader zone. Strips grow beyond this to
# fill a larger window; below it they keep this much so they never collapse (a Tk
# frame with pack_propagate(False) and no height shrinks to ~0).
STRIP_H = sc(568)

# per-category accents (headers + fader caps)
ACCENT = {
    "gain":   "#8b929b",   # Input / Output — neutral steel gray
    "master": "#e0b54a",   # Master Gain — gold / amber
    "exp":    "#3fa39a",   # Expression Gain — muted teal (PEDAL)
    "dyn":    "#4f8fd1",   # Gate / Compressor — blue
    "eq":     "#5fae6b",   # EQ1 / EQ2 — green
    "drive":  "#d56b3e",   # Distortion — orange / red
    "mod":    "#9173cc",   # Chorus / Delay / Reverb — purple / violet
}
CAT_LABEL = {
    "gain": "Gain", "master": "Master", "exp": "Expression",
    "dyn": "Dynamics", "eq": "EQ", "drive": "Drive", "mod": "Time / Mod",
}

# the four EQ band names (real model uses short names, not fx_*_gain)
EQ_BANDS = {"sub", "low", "mid", "high"}
EQ_SLIDER_W = sc(28)    # graphic-EQ band slider width
EQ_SLIDER_H = sc(184)   # graphic-EQ band slider height (tall, like a real graphic EQ)
EQ_AXIS_W = sc(34)      # width of the shared dB scale on the left of an EQ strip
# dB gridlines / axis ticks, as (raw byte, label).  Byte positions are linear in
# travel; the labels are the dB they map to (ref 128): +6 / 0 / -6 / -12.
EQ_TICKS = ((255, "+6"), (128, "0"), (64, "-6"), (32, "-12"))

# short uppercase labels per parameter (keyed by this model's short names)
PLAB = {
    "gain": "GAIN", "threshold": "THRESH", "attack": "ATK", "release": "REL",
    "knee": "KNEE", "depth": "DEPTH", "ratio": "RATIO", "in gain": "IN",
    "makeup": "MAKEUP", "mix": "MIX", "drive": "DRIVE", "bias": "BIAS",
    "sag": "SAG", "tone": "TONE", "tightness": "TIGHT", "smooth": "SMOOTH",
    "rate": "RATE", "time": "TIME", "feedback": "FBK", "size": "SIZE",
    "damping": "DAMP", "sub": "SUB", "low": "LOW", "mid": "MID", "high": "HIGH",
    "decay": "DECAY", "mod depth": "MOD", "diffusion": "DIFFUSE",
    "predelay": "PRE-DLY", "width": "WIDTH",
}


def plab(name):
    return PLAB.get(name, name.upper())


def clamp(v):
    return max(M.PARAM_MIN, min(M.PARAM_MAX, int(round(v))))


# ----------------------------------------------------------------------------
# Model introspection — everything is derived from M.* so the UI tracks the model
# ----------------------------------------------------------------------------
def param_names(fx):
    return {M.param_name(fx, p) for p in M.active_params(fx)}


def pindex(fx, name):
    """Index of the param with the given name within fx, or None."""
    for p in M.active_params(fx):
        if M.param_name(fx, p) == name:
            return p
    return None


def any_readonly(fx):
    return any(M.is_read_only(fx, p) for p in M.active_params(fx))


def category(fx):
    if M.is_global(fx):
        return "master"
    if any_readonly(fx):          # expression-pedal slot
        return "exp"
    s = param_names(fx)
    if "drive" in s:
        return "drive"
    if EQ_BANDS <= s:
        return "eq"
    if "threshold" in s and ("ratio" in s or "knee" in s):
        return "dyn"
    if s & {"rate", "time", "size"}:
        return "mod"
    return "gain"


def is_eq(fx):
    return EQ_BANDS <= param_names(fx)


def fader_param(fx):
    """The strip's signature param rendered as the tall fader (index), or None."""
    if is_eq(fx):
        return None  # EQ strips have no fader; the 4 bands are the controls
    # priority: gain stages -> wet/dry mix -> gate threshold
    for target in ("gain", "mix", "threshold"):
        p = pindex(fx, target)
        if p is not None:
            return p
    params = list(M.active_params(fx))
    return params[-1] if params else None


def fader_unity(fx, fp):
    # gain faders have a unity reference at 32
    return 32 if M.param_name(fx, fp) == "gain" else None


def ref_value(fx, p):
    """Double-click reset target: model default if exposed, else documented unity."""
    for attr in ("param_default", "default_value", "default"):
        fn = getattr(M, attr, None)
        if callable(fn):
            try:
                d = fn(fx, p)
                if d is not None:
                    return clamp(d)
            except Exception:
                pass
    name = M.param_name(fx, p)
    if name == "gain":
        return 32                                  # gain unity
    if name in EQ_BANDS:
        return 128                                 # EQ band unity
    if name == "in gain":
        return 64                                  # compressor input unity
    if name == "makeup":
        # distortion makeup unity is 128; compressor makeup unity is 64
        return 128 if "drive" in param_names(fx) else 64
    return None


# ============================================================================
# Canvas drawing primitives (knob / fader / EQ band)
# ============================================================================
def draw_knob(cv, value, accent, enabled, size=38):
    cv.delete("all")
    S = size
    cx = cy = S / 2
    cy += 1
    R = size * 0.34
    t = value / 255.0
    # 270-degree sweep, gap at the bottom: min lower-left (225), max lower-right (-45)
    cv.create_arc(cx - R - 3, cy - R - 3, cx + R + 3, cy + R + 3,
                  start=225, extent=-270, style="arc", outline="#16171c", width=4)
    arc = accent if enabled else "#4a4b54"
    if t > 0:
        cv.create_arc(cx - R - 3, cy - R - 3, cx + R + 3, cy + R + 3,
                      start=225, extent=-270 * t, style="arc", outline=arc, width=4)
    cv.create_oval(cx - R, cy - R, cx + R, cy + R, fill=PANEL_HI, outline="#15161a")
    cv.create_oval(cx - R + 3, cy - R + 3, cx + R - 3, cy + R - 3, outline="#3a3b45")
    ang = math.radians(225 - 270 * t)
    px, py = cx + math.cos(ang) * (R - 2), cy - math.sin(ang) * (R - 2)
    ix, iy = cx + math.cos(ang) * 5, cy - math.sin(ang) * 5
    cv.create_line(ix, iy, px, py, fill=(READOUT if enabled else FAINT),
                   width=2, capstyle="round")


def draw_fader(cv, value, accent, enabled, unity=None, w=46, h=200):
    cv.delete("all")
    cx = w / 2
    top, bot = 12, h - 14
    span = bot - top
    t = value / 255.0
    capY = bot - span * t
    for tk_ in (0, .12, .25, .4, .55, .7, .85, 1):
        y = bot - span * tk_
        cv.create_line(cx - 8, y, cx - 4, y, fill="#34353d")
        cv.create_line(cx + 4, y, cx + 8, y, fill="#34353d")
    cv.create_rectangle(cx - 3.5, top, cx + 3.5, bot, fill=WELL, outline="#0a0b0d")
    if unity is not None:
        uy = bot - span * (unity / 255.0)
        cv.create_line(cx - 10, uy, cx + 10, uy, fill=accent, width=2)
    capW, capH = w - 14, 22
    cap_fill = "#3a3b45" if enabled else "#2a2b32"
    cv.create_rectangle(cx - capW / 2, capY - capH / 2, cx + capW / 2, capY + capH / 2,
                        fill=cap_fill, outline="#121317")
    cv.create_line(cx - capW / 2 + 4, capY, cx + capW / 2 - 4, capY,
                   fill=(accent if enabled else FAINT), width=3, capstyle="round")
    cv.create_line(cx - capW / 2 + 4, capY - 4, cx + capW / 2 - 4, capY - 4,
                   fill="#52535e")


def draw_eq(cv, value, accent, enabled, w=EQ_SLIDER_W, h=EQ_SLIDER_H):
    cv.delete("all")
    cx = w / 2
    top, bot = 10, h - 10
    span = bot - top
    t = value / 255.0
    capY = bot - span * t
    # dB gridlines (byte-linear positions); 0 dB (byte 128) drawn solid as the detent
    for b, _lab in EQ_TICKS:
        gy = bot - span * (b / 255.0)
        if b == 128:
            cv.create_line(2, gy, w - 2, gy, fill="#6a6d77")
        else:
            cv.create_line(3, gy, w - 3, gy, fill="#3a3b44", dash=(2, 2))
    # track
    cv.create_rectangle(cx - 2.5, top, cx + 2.5, bot, fill=WELL, outline="#26272e")
    # round handle (like the reference graphic EQ)
    r = 6
    ring = accent if enabled else "#4a4b54"
    cv.create_oval(cx - r, capY - r, cx + r, capY + r,
                   fill=PANEL_HI, outline=ring, width=2)
    cv.create_oval(cx - 2, capY - 2, cx + 2, capY + 2,
                   fill=(READOUT if enabled else FAINT), outline="")


def draw_eq_axis(cv, h=EQ_SLIDER_H, w=EQ_AXIS_W):
    """Shared dB scale drawn to the left of an EQ strip's four bands.

    Only the numeric ticks live on the canvas; the 'GAIN' / '(dB)' captions are
    real labels above/below it, so nothing collides with the top tick."""
    cv.delete("all")
    top, bot = 10, h - 10
    span = bot - top
    for b, lab in EQ_TICKS:
        y = bot - span * (b / 255.0)
        cv.create_line(w - 6, y, w - 2, y, fill="#4a4b54")
        cv.create_text(w - 8, y, text=lab, anchor="e", fill=DIM,
                       font=("TkDefaultFont", 7))


# ============================================================================
# Control widgets — each reads/writes value through the gui value cache and
# commits to the board on RELEASE (so JTAG is not flooded during a drag).
# ============================================================================
class ValueEntry(tk.Entry):
    """Numeric readout that doubles as an inline editor.

    Looks like the old value label (flat, borderless, centered) but lets the user
    click and type a value: digits only while typing, clamped to PARAM_MIN..PARAM_MAX
    and written to the board on Return / focus-out. Read-only when its control is
    read-only or the board is disconnected.
    """
    def __init__(self, parent, font, fg, bg, on_commit, get_value, is_editable,
                 fmt=None, editfmt=None, parse=None, width=3):
        self._var = tk.StringVar()
        super().__init__(parent, textvariable=self._var, font=font, fg=fg, bg=bg,
                         readonlybackground=bg, disabledbackground=bg,
                         insertbackground=fg, justify="center", width=width,
                         bd=0, relief="flat", highlightthickness=0)
        self._on_commit = on_commit
        self._get_value = get_value
        self._is_editable = is_editable
        # Unit-aware display/edit/parse. Defaults preserve the old raw-byte behavior.
        self._fmt = fmt or (lambda v: str(int(v)))           # blurred: "+3.5 dB"
        self._editfmt = editfmt or (lambda v: str(int(v)))   # focused: bare "-6.0"
        self._parse = parse or (lambda s: int(s) if s.strip().isdigit() else None)
        self.configure(validate="key",
                       validatecommand=(self.register(self._validate), "%P"))
        self.bind("<Return>", self._commit)
        self.bind("<FocusOut>", self._commit)
        self.bind("<Escape>", self._cancel)
        self.bind("<FocusIn>", self._focus_in)
        self.set_display(self._get_value())

    @staticmethod
    def _validate(proposed):
        # Allow a signed decimal so dB ("-6.0") and the raw forms can be typed.
        if proposed in ("", "-", "+", ".", "-.", "+."):
            return True
        if len(proposed) > 8:
            return False
        body = proposed[1:] if proposed[0] in "+-" else proposed
        if body.count(".") > 1:
            return False
        return all(ch.isdigit() or ch == "." for ch in body)

    def set_display(self, v):
        # Refresh the shown value (called on drag / wheel / dump), but never clobber
        # text while the user is mid-edit. Also tracks editable state.
        if self.focus_get() is not self:
            self._var.set(self._fmt(v))
        self.configure(state=("normal" if self._is_editable() else "readonly"))

    def _focus_in(self, e=None):
        # Swap the formatted readout for a bare, editable number and select it.
        if not self._is_editable():
            return
        self._var.set(self._editfmt(self._get_value()))
        self.select_range(0, "end")
        self.icursor("end")

    def _commit(self, e=None):
        if not self._is_editable():
            return
        v = self._parse(self._var.get())
        if v is None:                       # unparseable -> revert to current
            v = int(self._get_value())
        if v != int(self._get_value()):     # only write the board on a real change
            self._on_commit(v)
        self._var.set(self._fmt(v))         # reflect the (possibly clamped) value
        if e is not None and getattr(e, "keysym", "") == "Return":
            self.master.focus_set()         # drop focus so it "locks in"

    def _cancel(self, e=None):
        self._var.set(self._fmt(self._get_value()))
        self.master.focus_set()


class _Control:
    def __init__(self, gui, fx, p):
        self.gui, self.fx, self.p = gui, fx, p
        self.ro = M.is_read_only(fx, p)
        gui.controls.append(self)

    def value(self):
        return self.gui.get_value(self.fx, self.p)

    def active(self):
        return self.gui.enabled and not self.ro

    def make_value_entry(self, parent, font, fg=READOUT, compact=False):
        """Build the editable numeric readout wired to this control.

        compact=True uses the suffix-less dB form (for the dense EQ band sliders).
        """
        fx, p = self.fx, self.p
        return ValueEntry(parent, font=font, fg=fg, bg=PANEL,
                          on_commit=self._set_from_entry,
                          get_value=self.value, is_editable=self.active,
                          fmt=lambda v: M.fmt_value(fx, p, v, compact),
                          editfmt=lambda v: M.edit_str(fx, p, v),
                          parse=lambda s: M.parse_value(fx, p, s),
                          width=M.display_width(fx, p, compact))

    def _set_from_entry(self, v):
        # apply a typed value: cache it, redraw the control, and write to the board
        self.gui.set_value(self.fx, self.p, v)
        self.redraw()
        self.gui.commit(self.fx, self.p)


class Knob(_Control):
    def __init__(self, parent, gui, fx, p, accent, size=38):
        super().__init__(gui, fx, p)
        self.accent = accent
        self.size = size
        f = tk.Frame(parent, bg=PANEL)
        self.frame = f
        tk.Label(f, text=plab(M.param_name(fx, p)), font=gui.f_label,
                 fg=FAINT, bg=PANEL).pack()
        self.cv = tk.Canvas(f, width=size, height=size, bg=PANEL, highlightthickness=0)
        self.cv.pack()
        # compact dB (no " dB" suffix) keeps knob readouts tight and the columns even
        self.lbl = self.make_value_entry(
            f, font=(gui.f_fval if size >= sc(50) else gui.f_val), compact=True)
        self.lbl.pack()
        if not self.ro:
            self.cv.configure(cursor="sb_v_double_arrow")
            self.cv.bind("<Button-1>", self._press)
            self.cv.bind("<B1-Motion>", self._motion)
            self.cv.bind("<ButtonRelease-1>", self._release)
            self.cv.bind("<Double-Button-1>", self._dbl)
            self.cv.bind("<MouseWheel>", self._wheel)
            self.cv.bind("<Button-4>", lambda e: self._step(1))
            self.cv.bind("<Button-5>", lambda e: self._step(-1))
        self.redraw()

    def redraw(self):
        draw_knob(self.cv, self.value(), self.accent, self.active(), self.size)
        self.lbl.set_display(self.value())

    def _press(self, e):
        self._last = e.y

    def _motion(self, e):
        if not self.active():
            return
        dy = self._last - e.y
        self._last = e.y
        if dy:
            self.gui.set_value(self.fx, self.p, self.value() + dy * 0.9)
            self.redraw()

    def _release(self, e):
        if self.active():
            self.gui.commit(self.fx, self.p)

    def _dbl(self, e):
        if not self.active():
            return
        r = ref_value(self.fx, self.p)
        if r is not None:
            self.gui.set_value(self.fx, self.p, r)
            self.redraw()
            self.gui.commit(self.fx, self.p)

    def _wheel(self, e):
        self._step(1 if e.delta > 0 else -1)

    def _step(self, d):
        if not self.active():
            return
        self.gui.set_value(self.fx, self.p, self.value() + d)
        self.redraw()
        self.gui.commit(self.fx, self.p)


class EqBand(_Control):
    def __init__(self, grid, gui, fx, p, accent, col):
        super().__init__(gui, fx, p)
        self.accent = accent
        self.cv_h = EQ_SLIDER_H
        # gridded into the EQ block's shared grid (column = band, rows = value /
        # slider / name) so every row keeps one uniform height and lines up with
        # the dB axis column beside it.
        self.lbl = self.make_value_entry(grid, font=gui.f_val, compact=True)
        self.lbl.grid(row=0, column=col, padx=3, sticky="s")
        self.cv = tk.Canvas(grid, width=EQ_SLIDER_W, height=self.cv_h, bg=PANEL,
                            highlightthickness=0)
        self.cv.grid(row=1, column=col, padx=3)
        tk.Label(grid, text=plab(M.param_name(fx, p)), font=gui.f_label,
                 fg=FAINT, bg=PANEL).grid(row=2, column=col, padx=3, pady=(2, 0),
                                          sticky="n")
        self.cv.configure(cursor="sb_v_double_arrow")
        self.cv.bind("<Button-1>", self._press)
        self.cv.bind("<B1-Motion>", self._motion)
        self.cv.bind("<ButtonRelease-1>", self._release)
        self.cv.bind("<Double-Button-1>", self._dbl)
        self.redraw()

    def set_height(self, h):
        # let the band slider grow to fill the strip, like the channel faders
        if abs(h - self.cv_h) < 2:
            return
        self.cv_h = h
        self.cv.config(height=h)
        self.redraw()

    def redraw(self):
        draw_eq(self.cv, self.value(), self.accent, self.active(),
                w=EQ_SLIDER_W, h=self.cv_h)
        self.lbl.set_display(self.value())

    def _press(self, e):
        self._last = e.y

    def _motion(self, e):
        if not self.active():
            return
        dy = self._last - e.y
        self._last = e.y
        if dy:
            self.gui.set_value(self.fx, self.p, self.value() + dy * 1.5)
            self.redraw()

    def _release(self, e):
        if self.active():
            self.gui.commit(self.fx, self.p)

    def _dbl(self, e):
        if not self.active():
            return
        self.gui.set_value(self.fx, self.p, 128)
        self.redraw()
        self.gui.commit(self.fx, self.p)


class Stepper(_Control):
    """Reverb decay: 4 discrete tail steps (0-63 short, 64-127 med,
    128-191 original, 192-255 long), rendered as a 4-position selector."""
    STEPS = [("SHORT", 31), ("MED", 95), ("ORIG", 159), ("LONG", 223)]

    def __init__(self, parent, gui, fx, p, accent):
        super().__init__(gui, fx, p)
        self.accent = accent
        f = tk.Frame(parent, bg=PANEL)
        self.frame = f
        tk.Label(f, text=plab(M.param_name(fx, p)) + " — TAIL", font=gui.f_label,
                 fg=FAINT, bg=PANEL).pack(pady=(0, 3))
        grid = tk.Frame(f, bg=PANEL)
        grid.pack()
        grid.columnconfigure(0, weight=1)
        grid.columnconfigure(1, weight=1)
        self.cells = []
        for i, (lab, val) in enumerate(self.STEPS):
            c = tk.Label(grid, text=lab, font=gui.f_label, bg=PANEL_LO, fg=DIM,
                         bd=1, relief="solid", padx=3, pady=4, width=5)
            c.grid(row=i // 2, column=i % 2, padx=2, pady=2, sticky="nsew")
            c.bind("<Button-1>", lambda e, vv=val: self._pick(vv))
            self.cells.append(c)
        self.redraw()

    def redraw(self):
        idx = min(3, self.value() // 64)
        for i, c in enumerate(self.cells):
            if i == idx and self.active():
                c.config(bg=self.accent, fg="#ffffff")
            else:
                c.config(bg=PANEL_LO, fg=(DIM if self.gui.enabled else FAINT))

    def _pick(self, v):
        if not self.active():
            return
        self.gui.set_value(self.fx, self.p, v)
        self.redraw()
        self.gui.commit(self.fx, self.p)


class Fader(_Control):
    def __init__(self, parent, gui, fx, p, accent, master=False, fill=False, wide=False):
        super().__init__(gui, fx, p)
        self.accent = accent
        self.unity = fader_unity(fx, p)
        self.w = sc(58) if master else (sc(54) if wide else sc(46))
        self.h = sc(222) if (master or fill) else sc(200)
        f = tk.Frame(parent, bg=PANEL)
        self.frame = f
        lbl = plab(M.param_name(fx, p))
        if master:
            lbl = "MASTER"
        tk.Label(f, text=lbl, font=gui.f_label, fg=FAINT, bg=PANEL).pack(pady=(0, 4))
        self.cv = tk.Canvas(f, width=self.w, height=self.h, bg=PANEL,
                            highlightthickness=0)
        self.cv.pack()
        self.lbl = self.make_value_entry(
            f, font=(gui.f_fval if not master else gui.f_master),
            fg=(accent if master else READOUT))
        self.lbl.pack(pady=(5, 0))
        if not self.ro:
            self.cv.configure(cursor="sb_v_double_arrow")
            self.cv.bind("<Button-1>", self._press)
            self.cv.bind("<B1-Motion>", self._motion)
            self.cv.bind("<ButtonRelease-1>", self._release)
            self.cv.bind("<Double-Button-1>", self._dbl)
            self.cv.bind("<MouseWheel>", self._wheel)
            self.cv.bind("<Button-4>", lambda e: self._step(1))
            self.cv.bind("<Button-5>", lambda e: self._step(-1))
        self.redraw()

    def redraw(self):
        draw_fader(self.cv, self.value(), self.accent, self.active(),
                   unity=self.unity, w=self.w, h=self.h)
        self.lbl.set_display(self.value())

    def set_height(self, h):
        # Used by knob-less gain strips + the MASTER strip so the fader fills
        # the strip vertically.
        if abs(h - self.h) < 2:
            return
        self.h = h
        self.cv.config(height=h)
        self.redraw()

    def _press(self, e):
        self._last = e.y

    def _motion(self, e):
        if not self.active():
            return
        dy = self._last - e.y
        self._last = e.y
        if dy:
            self.gui.set_value(self.fx, self.p, self.value() + dy * (255.0 / (self.h - 26)))
            self.redraw()

    def _release(self, e):
        if self.active():
            self.gui.commit(self.fx, self.p)

    def _dbl(self, e):
        if not self.active():
            return
        r = ref_value(self.fx, self.p)
        if r is not None:
            self.gui.set_value(self.fx, self.p, r)
            self.redraw()
            self.gui.commit(self.fx, self.p)

    def _wheel(self, e):
        self._step(1 if e.delta > 0 else -1)

    def _step(self, d):
        if not self.active():
            return
        self.gui.set_value(self.fx, self.p, self.value() + d)
        self.redraw()
        self.gui.commit(self.fx, self.p)


# ============================================================================
# Channel strip
# ============================================================================
class Strip:
    def __init__(self, parent, gui, fx):
        self.gui, self.fx = gui, fx
        self.master = M.is_global(fx)
        self.readonly = any_readonly(fx)
        self.cat = category(fx)
        accent = ACCENT[self.cat]
        self.controls = []

        # ---- decide the layout up front so the strip width can hug its content ----
        fp = fader_param(fx)
        eq = is_eq(fx)
        # decay is a stepper, not a knob; the fader param is not duplicated as a knob
        knob_ps = [] if eq else [p for p in M.active_params(fx)
                                 if p != fp and M.param_name(fx, p) != "decay"]
        decay_ps = [] if eq else [p for p in M.active_params(fx)
                                  if M.param_name(fx, p) == "decay"]
        has_knobs = bool(knob_ps or decay_ps)
        self.fill = (fp is not None) and not eq          # fader grows to fill
        fader_only = self.fill and not has_knobs         # no knobs -> fader is the strip
        # Narrow strips stack their few params in one vertical column so the strip
        # can hug its content; busy effects keep the wider two-column knob grid.
        narrow = (not eq) and (not self.master) and len(knob_ps) <= 4
        single_col = narrow and len(knob_ps) >= 3        # gate; chorus/delay keep a hero
        use_hero = (len(knob_ps) >= 2) and not decay_ps and not single_col

        # Width is set dynamically: build at a provisional width, then
        # _autofit_strips() measures each strip's REAL rendered content
        # (title + readouts + controls) and sizes it to fit — so nothing clips
        # regardless of label text, and we never hand-tune widths again.
        self._fit_frames = []                 # content frames measured during autofit
        if self.master:
            self.min_width = sc(146)
        elif eq:
            self.min_width = sc(120)
        elif fader_only:
            self.min_width = sc(84)           # holds a sensible floor for gain stages
        elif narrow:
            self.min_width = sc(72)           # gate / chorus / delay
        else:
            self.min_width = sc(110)          # compressor / distortion / reverb
        width = max(self.min_width, sc(130))  # provisional; autofit corrects it
        bg = "#272620" if self.master else PANEL
        outer = tk.Frame(parent, bg=bg, width=width, height=STRIP_H,
                         highlightthickness=1,
                         highlightbackground=("#4a401f" if self.master else "#303138"))
        outer.pack(side="left", fill="y", padx=(sc(14) if self.master else 0, 0))
        outer.pack_propagate(False)   # lock strip width (and pin the height floor)
        self.frame = outer

        # ---- header name plate ----
        # No wraplength: the title stays one line and reports its true required
        # width, which autofit uses to size the strip so the name never clips.
        hdr = tk.Frame(outer, bg=accent, height=sc(46))
        hdr.pack(fill="x")
        hdr.pack_propagate(False)
        self.hdr_label = tk.Label(hdr, text=M.fx_name(fx), font=gui.f_head,
                                  fg=HEADER_INK, bg=accent, anchor="w", justify="left")
        self.hdr_label.pack(fill="x", padx=8, pady=(5, 0))
        self.hdr_row = tk.Frame(hdr, bg=accent)
        self.hdr_row.pack(fill="x", padx=8)
        tk.Label(self.hdr_row, text=CAT_LABEL[self.cat].upper(), font=gui.f_cat,
                 fg=HEADER_INK, bg=accent).pack(side="left")
        tk.Label(self.hdr_row, text="F%d" % fx, font=gui.f_cat, fg=HEADER_INK,
                 bg=accent).pack(side="right")

        # ---- body: EQ bands, or knobs/stepper hugging the header ----
        if eq or has_knobs:
            body = tk.Frame(outer, bg=PANEL)
            self.body = body
            if eq:
                # no fader; one shared grid (axis + four bands) centered in the body.
                # Grid rows give every column one uniform height, so the GAIN/(dB)
                # captions line up with the value readouts and band names.
                body.pack(side="top", fill="both", expand=True)
                body.pack_propagate(False)
                grid = tk.Frame(body, bg=PANEL)
                grid.place(relx=0.5, rely=0.5, anchor="center")
                # dB axis column (col 0): GAIN caption / scale / (dB) caption
                tk.Label(grid, text="GAIN", font=gui.f_val, fg=FAINT,
                         bg=PANEL).grid(row=0, column=0, padx=(0, 2), sticky="s")
                acv = tk.Canvas(grid, width=EQ_AXIS_W, height=EQ_SLIDER_H, bg=PANEL,
                                highlightthickness=0)
                acv.grid(row=1, column=0, padx=(0, 2))
                draw_eq_axis(acv)
                tk.Label(grid, text="(dB)", font=gui.f_label, fg=FAINT,
                         bg=PANEL).grid(row=2, column=0, padx=(0, 2), pady=(2, 0),
                                        sticky="n")
                self._eq_axis = acv
                self._eq_bands = [EqBand(grid, gui, fx, p, accent, col=i + 1)
                                  for i, p in enumerate(M.active_params(fx))]
                self._fit_frames.append(grid)
                self._collect()
                # grow the bands + axis to fill the strip height, like the faders
                body.bind("<Configure>", self._resize_eq)
            else:
                # knobs sit just under the header (natural height); the growing fader
                # below fills what used to be dead space at the top.
                body.pack(side="top", fill="x")
                inner = tk.Frame(body, bg=PANEL)
                inner.pack(pady=(6, 2))
                if single_col:
                    # all params in one vertical column (thin strip, aligned knobs)
                    for p in knob_ps:
                        Knob(inner, gui, fx, p, accent, size=sc(40)).frame.pack(pady=2)
                else:
                    if use_hero:
                        Knob(inner, gui, fx, knob_ps[0], accent, size=sc(56)).frame.pack(pady=(0, 2))
                        rest = knob_ps[1:]
                    else:
                        rest = knob_ps
                    if rest:
                        grid = tk.Frame(inner, bg=PANEL)
                        grid.pack()
                        # equal-width columns so paired knobs sit symmetric/centered
                        grid.columnconfigure(0, weight=1, uniform="kn")
                        grid.columnconfigure(1, weight=1, uniform="kn")
                        odd = len(rest) % 2 == 1
                        for i, p in enumerate(rest):
                            kf = Knob(grid, gui, fx, p, accent, size=sc(38)).frame
                            if odd and i == len(rest) - 1:
                                # lone last knob spans both columns -> centered
                                kf.grid(row=i // 2, column=0, columnspan=2, pady=1)
                            else:
                                kf.grid(row=i // 2, column=i % 2, padx=1, pady=1)
                for p in decay_ps:
                    Stepper(inner, gui, fx, p, accent).frame.pack(pady=2)
                self._fit_frames.append(inner)
                self._collect()

        # ---- fader zone (fills the rest of the strip below the header/knobs) ----
        if fp is not None:
            fz = tk.Frame(outer, bg=PANEL, highlightthickness=0)
            fz.pack(side="top", fill="both", expand=True)
            if not fader_only:
                tk.Frame(fz, bg=SEP, height=1).pack(fill="x")   # divide knobs / fader
            if self.readonly:
                # driven by the physical expression pedal — display only
                tk.Label(fz, text=" PEDAL ", font=gui.f_cat, fg="#6fd0c6",
                         bg="#1c2b29", bd=1, relief="solid").pack(pady=(8, 0))
            self.fader = Fader(fz, gui, fx, fp, accent, master=self.master,
                               fill=self.fill, wide=fader_only)
            self.fader.frame.pack(pady=(8, 6), expand=True)
            self._fit_frames.append(self.fader.frame)
            if self.master:
                tk.Label(fz, text="MAIN BUS", font=gui.f_cat, fg="#e7c463",
                         bg="#2a281f", bd=1, relief="solid").pack(pady=(0, 8))
            # the fader grows to fill its zone whenever there is one
            fz.bind("<Configure>", self._resize_fill)

    def _resize_fill(self, e):
        if hasattr(self, "fader"):
            self.fader.set_height(max(200, e.height - 96))

    def _resize_eq(self, e):
        # value row + name row + padding take ~64 px; the sliders fill the rest
        h = max(150, e.height - 64)
        for eb in self._eq_bands:
            eb.set_height(h)
        self._eq_axis.config(height=h)
        draw_eq_axis(self._eq_axis, h=h)

    def fit_width(self):
        # Size the strip to its REAL rendered content: the title row plus the
        # widest body/fader frame. Uses winfo_reqwidth (true requested size), so
        # it adapts to any label text or readout width without hand-tuned numbers.
        need = self.min_width
        title = max(self.hdr_label.winfo_reqwidth(),
                    self.hdr_row.winfo_reqwidth()) + sc(22)   # + header padx & slack
        need = max(need, title)
        for fr in self._fit_frames:
            rw = fr.winfo_reqwidth()
            if rw > 1:
                need = max(need, rw + sc(14))                 # + breathing room
        self.frame.config(width=need)

    def _collect(self):
        # Strip.controls mirrors gui.controls for this strip.
        for c in self.gui.controls:
            if getattr(c, "fx", None) == self.fx and c not in self.controls:
                self.controls.append(c)

    def redraw(self):
        for c in self.controls:
            c.redraw()


# ============================================================================
# Main application
# ============================================================================
class KfxGui(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("KFX Engine GUI — Param Editor")
        self.geometry("1400x820")   # tall enough that the densest strips fit unclipped
        self.configure(bg=BG)
        self.minsize(1040, 700)

        self.client = None
        self.enabled = False
        self.bank = 0               # bank currently viewed/edited in the GUI
        self.hw_bank = 0            # last known live (hardware) bank
        self.follow = True          # auto-follow the live bank as it changes on the pedal
        self.hw_bank_supported = True  # cleared if firmware predates the GBNK opcode
        self.values = {}            # (fx, p) -> int
        self.controls = []          # all _Control instances
        self.strips = []
        self.tool_btns = []
        self.tab_widgets = []

        base = self._pick_font(["Segoe UI", "Helvetica Neue", "Helvetica", "DejaVu Sans"])
        mono = self._pick_font(["Consolas", "SF Mono", "DejaVu Sans Mono", "Courier"])
        self.f_head = tkfont.Font(family=base, size=fsz(11), weight="bold")
        self.f_cat = tkfont.Font(family=base, size=fsz(7), weight="bold")
        self.f_label = tkfont.Font(family=base, size=fsz(7), weight="bold")
        self.f_val = tkfont.Font(family=mono, size=fsz(9), weight="bold")
        self.f_fval = tkfont.Font(family=mono, size=fsz(12), weight="bold")
        self.f_master = tkfont.Font(family=mono, size=fsz(15), weight="bold")
        self.f_btn = tkfont.Font(family=base, size=fsz(9), weight="bold")
        self.f_brand = tkfont.Font(family=base, size=fsz(12), weight="bold")
        self.f_status = tkfont.Font(family=mono, size=fsz(9))

        # board-op plumbing: one worker thread + a result queue drained on the UI thread
        self.jobs = queue.Queue()
        self.results = queue.Queue()
        threading.Thread(target=self._worker, daemon=True).start()
        self.after(40, self._drain)

        self._build_toolbar()
        self._build_banks()
        self._build_console()
        self._build_status()
        self._build_overlay()
        self._autofit_strips()      # size every strip to its real content width

        self.set_connected(False)
        self.after(180, self._poll_state)

    # ---------------------------------------------------------------- fonts
    def _pick_font(self, prefs):
        avail = set(tkfont.families())
        for f in prefs:
            if f in avail:
                return f
        return prefs[-1]

    def _load_logo(self, path, size):
        """Load logo.png scaled to size x size. Prefer Pillow for a clean resize;
        fall back to Tk's native PNG loader with integer subsampling; return None
        if the file is missing/unreadable so the caller can use the lettermark."""
        if not os.path.exists(path):
            return None
        try:
            from PIL import Image, ImageTk
            img = Image.open(path).convert("RGBA").resize((size, size), Image.LANCZOS)
            return ImageTk.PhotoImage(img)
        except Exception:
            try:
                img = tk.PhotoImage(file=path)
                factor = max(1, img.width() // size)
                return img.subsample(factor, factor)
            except Exception:
                return None

    # ---------------------------------------------------------------- toolbar
    def _tbtn(self, parent, text, cmd, danger=False, primary=False):
        bg = "#2f63a8" if primary else "#34353e"
        fg = "#ffffff" if primary else INK
        b = tk.Button(parent, text=text, command=cmd, font=self.f_btn,
                      fg=fg, bg=bg, activebackground="#3b3c46", activeforeground=INK,
                      relief="flat", bd=0, padx=11, pady=6, cursor="hand2",
                      highlightthickness=0)
        if danger:
            b.config(activeforeground="#ffb3a3")
        return b

    def _build_toolbar(self):
        bar = tk.Frame(self, bg="#26272e")
        bar.pack(fill="x")
        tk.Frame(self, bg="#15161a", height=1).pack(fill="x")

        self._logo_img = self._load_logo(os.path.join(HERE, "logo.png"), 30)
        if self._logo_img is not None:
            logo = tk.Label(bar, image=self._logo_img, bg="#26272e")
        else:  # fall back to the lettermark if the image can't be loaded
            logo = tk.Label(bar, text=" K ", font=self.f_brand, fg="#2a1d05", bg="#d4a843")
        logo.pack(side="left", padx=(12, 8), pady=8)
        bw = tk.Frame(bar, bg="#26272e")
        bw.pack(side="left")
        tk.Label(bw, text="KFX Engine GUI", font=self.f_brand, fg=INK, bg="#26272e").pack(anchor="w")
        tk.Label(bw, text="PARAM EDITOR", font=self.f_cat, fg=FAINT, bg="#26272e").pack(anchor="w")

        self.conn_dot = tk.Canvas(bar, width=12, height=12, bg="#26272e",
                                  highlightthickness=0)
        self.conn_dot.pack(side="left", padx=(18, 6))
        self.conn_lbl = tk.Label(bar, text="Not connected", font=self.f_btn,
                                 fg=DIM, bg="#26272e")
        self.conn_lbl.pack(side="left")
        self.connect_btn = self._tbtn(bar, "Connect", self.do_connect)
        self.connect_btn.pack(side="left", padx=12, pady=8)

        right = tk.Frame(bar, bg="#26272e")
        right.pack(side="right", padx=10)
        clusters = [
            [("Read", self.refresh, False), ("Reset Bank", self.reset_bank, False),
             ("Reset All", self.reset_all, True)],
            [("Save Flash", self.save_flash, False), ("Load Flash", self.load_flash, False),
             ("Export", self.export_preset, False), ("Import", self.import_preset, False)],
        ]
        for ci, cl in enumerate(clusters):
            if ci:
                tk.Frame(right, bg="#14151a", width=1).pack(side="left", fill="y",
                                                            padx=8, pady=10)
            grp = tk.Frame(right, bg="#26272e")
            grp.pack(side="left")
            for text, cmd, danger in cl:
                b = self._tbtn(grp, text, cmd, danger=danger)
                b.pack(side="left", padx=2, pady=8)
                self.tool_btns.append(b)

    # ---------------------------------------------------------------- banks
    def _build_banks(self):
        bar = tk.Frame(self, bg="#1b1c21")
        bar.pack(fill="x")
        tk.Frame(self, bg="#131419", height=1).pack(fill="x")
        tk.Label(bar, text="PRESET BANK", font=self.f_cat, fg=FAINT,
                 bg="#1b1c21").pack(side="left", padx=(14, 12), pady=(7, 5))
        for b in range(P.BANK_COUNT):
            lbl = tk.Label(bar, text=self._tab_text(b),
                           font=self.f_btn, fg=DIM, bg="#212228", bd=0,
                           padx=10, pady=6, cursor="hand2")
            lbl.pack(side="left", padx=(0, 3), pady=(6, 0))
            lbl.bind("<Button-1>", lambda e, bb=b: self.select_bank(bb))
            self.tab_widgets.append(lbl)
        # Follow toggle: when ON the highlighted tab tracks the live (pedal) bank.
        self.follow_btn = tk.Label(bar, text="", font=self.f_btn, bd=0,
                                   padx=11, pady=6, cursor="hand2")
        self.follow_btn.pack(side="right", padx=(0, 12), pady=(6, 0))
        self.follow_btn.bind("<Button-1>", lambda e: self.toggle_follow())
        self._paint_tabs()
        self._paint_follow()

    def _tab_text(self, b):
        # A "●" marks the live (hardware) bank so it stays visible even when pinned.
        live = "●" if b == self.hw_bank else "  "
        return " %d · %s %s " % (b, M.bank_name(b), live)

    def _paint_tabs(self):
        for b, w in enumerate(self.tab_widgets):
            w.config(text=self._tab_text(b))
            if b == self.bank:
                w.config(bg=PANEL, fg=INK)
            else:
                w.config(bg="#212228", fg=DIM)

    def _paint_follow(self):
        on = self.follow
        self.follow_btn.config(
            text="⟳ FOLLOW: ON" if on else "⟳ FOLLOW: OFF",
            fg=(HEADER_INK if on else DIM),
            bg=("#5fae6b" if on else "#212228"))

    # ---------------------------------------------------------------- console
    def _build_console(self):
        wrap = tk.Frame(self, bg=BG)
        wrap.pack(fill="both", expand=True)
        hsb = tk.Scrollbar(wrap, orient="horizontal")
        hsb.pack(side="bottom", fill="x")
        canvas = tk.Canvas(wrap, bg=BG, highlightthickness=0,
                           xscrollcommand=hsb.set)
        canvas.pack(side="top", fill="both", expand=True)
        hsb.config(command=canvas.xview)
        inner = tk.Frame(canvas, bg=BG)
        win = canvas.create_window((0, 0), window=inner, anchor="nw")
        inner.bind("<Configure>",
                   lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
        # stretch the inner frame to the viewport height (but never below one
        # strip's height) so the knob-less gain/master strips' fill-faders run
        # the full height; the strips' own fill="y" then grows them to match.
        canvas.bind("<Configure>",
                    lambda e: canvas.itemconfigure(win, height=max(e.height, STRIP_H + 24)))
        pad = tk.Frame(inner, bg=BG)
        pad.pack(padx=sc(12), pady=sc(12), fill="both", expand=True)

        # iterate M.active_fx() in order; globals become the MASTER strip on the right
        channels = [fx for fx in M.active_fx() if not M.is_global(fx)]
        masters = [fx for fx in M.active_fx() if M.is_global(fx)]
        for fx in channels + masters:
            self.strips.append(Strip(pad, self, fx))

    def _autofit_strips(self):
        # After layout, size each strip to its real rendered content so titles and
        # readouts never clip. Dynamic — no per-strip widths to hand-tune.
        self.update_idletasks()
        for s in self.strips:
            s.fit_width()
        self.update_idletasks()

    # ---------------------------------------------------------------- status
    def _build_status(self):
        tk.Frame(self, bg="#0e0f12", height=1).pack(fill="x")
        bar = tk.Frame(self, bg="#17181c")
        bar.pack(fill="x")
        self.sdot = tk.Canvas(bar, width=8, height=8, bg="#17181c",
                              highlightthickness=0)
        self.sdot.pack(side="left", padx=(14, 8), pady=6)
        self.status = tk.Label(bar, text="Ready — click Connect.", font=self.f_status,
                               fg=DIM, bg="#17181c", anchor="w")
        self.status.pack(side="left")
        n_ch = sum(1 for fx in M.active_fx() if not M.is_global(fx))
        n_m = sum(1 for fx in M.active_fx() if M.is_global(fx))
        tk.Label(bar, text="%d channels · %d master · %d–%d params"
                 % (n_ch, n_m, M.PARAM_MIN, M.PARAM_MAX), font=self.f_status,
                 fg=FAINT, bg="#17181c").pack(side="right", padx=14)
        self.set_status("Ready — click Connect.", "warn")

    def set_status(self, msg, kind="ok"):
        self.status.config(text=msg)
        col = {"ok": "#5fae6b", "warn": "#d9a441", "bad": "#d8624a"}.get(kind, "#5fae6b")
        self.sdot.delete("all")
        self.sdot.create_oval(0, 0, 8, 8, fill=col, outline="")

    # ---------------------------------------------------------------- overlay
    def _build_overlay(self):
        self.overlay = tk.Frame(self, bg="#0c0d10")
        card = tk.Frame(self.overlay, bg="#2a2b33", highlightthickness=1,
                        highlightbackground="#14151a")
        card.place(relx=0.5, rely=0.5, anchor="center")
        self.ov_title = tk.Label(card, text="Working…", font=self.f_head,
                                 fg=INK, bg="#2a2b33")
        self.ov_title.pack(padx=40, pady=(24, 6))
        self.ov_sub = tk.Label(card, text="", font=self.f_btn, fg=DIM, bg="#2a2b33")
        self.ov_sub.pack(padx=40, pady=(0, 16))
        self.ov_bar = tk.Canvas(card, width=240, height=6, bg="#15161b",
                                highlightthickness=0)
        self.ov_bar.pack(padx=40, pady=(0, 24))
        self._ov_x = 0
        self._ov_mute = False

    def show_busy(self, title, sub, mute=False):
        self.ov_title.config(text=title, fg=("#d8624a" if mute else INK))
        self.ov_sub.config(text=sub)
        self._ov_mute = mute
        self.overlay.place(relx=0, rely=0, relwidth=1, relheight=1)
        self.overlay.lift()
        self._animate_busy()

    def hide_busy(self):
        self.overlay.place_forget()

    def _animate_busy(self):
        if not self.overlay.winfo_ismapped():
            return
        self.ov_bar.delete("all")
        self._ov_x = (self._ov_x + 8) % 312
        col = "#d8624a" if self._ov_mute else "#e0b54a"
        self.ov_bar.create_rectangle(self._ov_x - 72, 0, self._ov_x, 6, fill=col, outline="")
        self.after(40, self._animate_busy)

    # ---------------------------------------------------------------- values
    def get_value(self, fx, p):
        return self.values.get((fx, p), 0)

    def set_value(self, fx, p, v):
        self.values[(fx, p)] = clamp(v)

    # ---------------------------------------------------------------- worker
    def _worker(self):
        while True:
            fn, on_done, busy = self.jobs.get()
            try:
                ok, res = True, fn()
            except Exception as e:               # ProtocolError and friends
                ok, res = False, e
            self.results.put((on_done, ok, res, busy))

    def submit(self, fn, on_done=None, busy=None):
        if busy:
            self.show_busy(*busy)
        self.jobs.put((fn, on_done, busy))

    def _drain(self):
        try:
            while True:
                on_done, ok, res, busy = self.results.get_nowait()
                if busy:
                    self.hide_busy()
                if ok:
                    if on_done:
                        on_done(res)
                else:
                    if isinstance(res, P.ProtocolError):
                        self._error(str(res))
                    else:
                        self._error("%s" % res)
        except queue.Empty:
            pass
        self.after(40, self._drain)

    # ---------------------------------------------------------------- connect
    def set_connected(self, ok):
        self.enabled = ok
        st = "normal" if ok else "disabled"
        for b in self.tool_btns:
            b.config(state=st)
        for w in self.tab_widgets:
            w.config(cursor="hand2" if ok else "arrow")
        self.follow_btn.config(cursor="hand2" if ok else "arrow")
        self.connect_btn.config(text="Reconnect" if ok else "Connect")
        self.conn_dot.delete("all")
        self.conn_dot.create_oval(1, 1, 11, 11,
                                  fill=("#5fae6b" if ok else "#555"), outline="")
        self.conn_lbl.config(fg=INK if ok else DIM)
        for c in self.controls:
            c.redraw()

    def do_connect(self):
        def work():
            client = P.Client(P.JtagTransport())
            ver = client.ping()
            return client, ver
        self.submit(work, self._on_connected, busy=("Connecting…", "Opening JTAG-UART"))

    def _on_connected(self, payload):
        try:
            self.client, (vmaj, vmin) = payload
        except Exception:
            self.client = None
        if not self.client:
            self.set_connected(False)
            self.conn_lbl.config(text="Not connected")
            return
        self.conn_lbl.config(text="Connected — firmware v%d.%d" % (vmaj, vmin))
        self.set_connected(True)
        self.refresh()

    # ---------------------------------------------------------------- board ops
    def refresh(self):
        if not self.client:
            return
        self.submit(lambda: self.client.dump(), self._apply_dump)

    def _apply_dump(self, data):
        for c in self.controls:
            b = 0 if M.is_global(c.fx) else self.bank
            try:
                self.values[(c.fx, c.p)] = data[P.dump_index(b, c.fx, c.p)]
            except Exception:
                pass
        for c in self.controls:
            c.redraw()
        self.set_status("Read bank %d (%s)." % (self.bank, M.bank_name(self.bank)), "ok")

    def commit(self, fx, p):
        if not self.client or M.is_read_only(fx, p):
            return
        value = clamp(self.get_value(fx, p))
        bank = 0 if M.is_global(fx) else self.bank   # global writes go to bank 0 (mirrored)
        name = "%s / %s" % (M.fx_name(fx), M.param_name(fx, p))
        shown = M.fmt_value(fx, p, value)
        self.submit(lambda: self.client.write_param(bank, fx, p, value),
                    lambda r: self.set_status("Wrote %s = %s" % (name, shown), "ok"))

    def select_bank(self, b):
        if not self.enabled:
            return
        # Viewing a bank that isn't live means the user wants to edit it without
        # being yanked back by the poll — pin the view by disabling follow.
        if b != self.hw_bank and self.follow:
            self.follow = False
            self._paint_follow()
        self.bank = b
        self._paint_tabs()
        self.refresh()   # re-read repopulates non-global strips; master stays put

    def toggle_follow(self):
        if not self.enabled:
            return
        self.follow = not self.follow
        self._paint_follow()
        if self.follow and self.hw_bank != self.bank:
            self.select_bank(self.hw_bank)   # resume: snap the view to the live bank

    def reset_bank(self):
        if not self.client:
            return
        self.submit(lambda: self.client.reset(P.SCOPE_BANK, bank=self.bank),
                    lambda r: (self.set_status("Reset bank %d to defaults." % self.bank, "warn"),
                               self.refresh()))

    def reset_all(self):
        if not self.client:
            return
        if not messagebox.askyesno("Reset All", "Reset ALL banks to factory defaults?"):
            return
        self.submit(lambda: self.client.reset(P.SCOPE_ALL),
                    lambda r: (self.set_status("Reset all banks to defaults.", "warn"),
                               self.refresh()))

    def save_flash(self):
        if not self.client:
            return
        self.submit(lambda: self.client.save_flash(),
                    lambda r: self.set_status("Save complete — all banks written to flash.", "ok"),
                    busy=("Saving to flash — audio muted",
                          "Erasing sector & writing all banks · ~3 s", True))

    def load_flash(self):
        if not self.client:
            return
        self.submit(lambda: self.client.load_flash(),
                    lambda r: (self.set_status("Loaded banks from flash.", "ok"),
                               self.refresh()),
                    busy=("Loading from flash", "Reading banks from EPCQ flash"))

    def export_preset(self):
        if not self.client:
            return
        path = filedialog.asksaveasfilename(
            title="Export preset", defaultextension=".json",
            initialfile="kfx_preset.json", filetypes=[("JSON", "*.json")])
        if not path:
            return
        self.submit(lambda: presets.export_preset(self.client, path),
                    lambda r: self.set_status("Exported to %s" % path, "ok"))

    def import_preset(self):
        if not self.client:
            return
        path = filedialog.askopenfilename(title="Import preset",
                                          filetypes=[("JSON", "*.json")])
        if not path:
            return
        self.submit(lambda: presets.import_preset(self.client, path), self._on_import)

    def _on_import(self, payload):
        try:
            written, warnings = payload
        except Exception:
            written, warnings = payload, []
        self.refresh()
        msg = "Imported %s parameters." % written
        if warnings:
            messagebox.showinfo("Import", msg + "\n\nWarnings:\n" + "\n".join(warnings))
        self.set_status(msg, "ok")

    # ---------------------------------------------------------------- idle poll
    def _poll_state(self):
        # While idle, follow the live bank and (when stable) keep the read-only
        # expression-pedal fader fresh. Only fires when no other job is queued so
        # it never floods JTAG or competes with edits. Checking the bank first is
        # cheap (4-byte reply) and avoids two pollers racing on different banks.
        if self.client and self.enabled and self.jobs.empty():
            if self.hw_bank_supported:
                self.submit(self._safe_get_bank, self._apply_hw_bank)
            elif any(c.ro for c in self.controls):
                self.submit(lambda: self.client.dump(), self._apply_pedal)
        self.after(180, self._poll_state)

    def _safe_get_bank(self):
        # Swallow protocol errors so an un-reflashed board (no GBNK opcode) or a
        # transient timeout never spawns a popup every 180 ms.
        try:
            return self.client.get_bank()
        except P.ProtocolError:
            return None

    def _apply_hw_bank(self, hw):
        if hw is None:                       # firmware lacks GBNK — fall back to pedal-only poll
            self.hw_bank_supported = False
            return
        moved = (hw != self.hw_bank)
        self.hw_bank = hw
        if self.follow and hw != self.bank:
            self.bank = hw
            self._paint_tabs()
            self.refresh()                   # reload this bank's params (and pedal) via dump
            self.set_status("Following live bank %d (%s)." % (hw, M.bank_name(hw)), "ok")
            return
        if moved:
            self._paint_tabs()               # refresh the ● LIVE marker even when pinned
        if any(c.ro for c in self.controls) and self.jobs.empty():
            self.submit(lambda: self.client.dump(), self._apply_pedal)

    def _apply_pedal(self, data):
        changed = False
        for c in self.controls:
            if not c.ro:
                continue
            b = 0 if M.is_global(c.fx) else self.bank
            try:
                nv = data[P.dump_index(b, c.fx, c.p)]
            except Exception:
                continue
            if nv != self.values.get((c.fx, c.p)):
                self.values[(c.fx, c.p)] = nv
                c.redraw()
                changed = True
        if changed:
            self.set_status("Expression pedal moved.", "ok")

    # ---------------------------------------------------------------- error
    def _error(self, msg):
        self.set_status(msg.replace("\n", " "), "bad")
        messagebox.showwarning("KFX Engine", msg)


def main():
    KfxGui().mainloop()


if __name__ == "__main__":
    main()
