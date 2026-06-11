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

When the window is PORTRAIT (taller than wide) the console swaps to the
"FX Rack" view from the fx-rack-layout design handoff: the same chain stacked
vertically as collapsible rack units (rack ears + screws, flat fills) that fill
the window width and height, with squared copper patch-cable brackets down the left side —
each one linking a single effect to the next — and the gold MASTER bar pinned
above the status bar while the rack scrolls behind it. The gain-stage and master
faders stretch laterally to fill their units. Both views share the same value
cache and board plumbing; resizing across the square aspect swaps them live.

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

# ----------------------------------------------------------------------------
# Signal-flow connectors — thin gaps between strips carry a horizontal line and a
# right-pointing chevron so the row reads as a chain (IN -> FX -> FX -> ... -> OUT).
# The line sits at the header-band center so it ties the colored name plates
# together; the rest of the gap is plain window background.
# ----------------------------------------------------------------------------
FLOW_LINE = "#3f4049"   # the signal-flow connector line
FLOW_MARK = "#8b929b"   # chevrons / port nodes / IN-OUT labels (steel gray)
CONN_W    = sc(12)      # width of an inter-FX connector gap (thin, to fit small screens)
PORT_W    = sc(30)      # width of the IN / OUT end caps
CONN_H    = sc(46)      # connector canvas height
GAP_EXTRA_MAX = sc(14)  # cap on how much a gap may widen past its base on a big screen
                        # (once gaps hit this, leftover width goes to the strips instead)

# ----------------------------------------------------------------------------
# Rack view (portrait) — constants from the fx-rack-layout design handoff,
# "cozy" density / "hardware" skeuomorphism / "cable" signal flow / horizontal
# slider faders (the tweak settings the design landed on).
# ----------------------------------------------------------------------------
CABLE     = "#c5683a"   # copper patch-cable spine
CABLE_HI  = "#e0834f"   # cable arrowheads / solder nodes / TO MASTER label
RK_CONN_W = sc(30)      # left connector column — narrow so the squared cable
                        # brackets sit close to the FX (mirrored by a right spacer)
RK_PAD    = sc(4)       # unit body padding (tight, to fit the whole rack on screen)
RK_GAP    = sc(7)       # min gap between controls inside a unit body
RK_MAXGAP = sc(72)      # max gap a knob row spreads to before it stops spreading
                        # and just centres — caps how far apart few-knob units drift
RK_CELL_MIN = sc(56)    # approx width of a knob cell (label is usually wider than
                        # the knob); used to budget the row gap in _grow_knobs
RK_ROWGAP = sc(10)      # vertical space between rack units (clear gap when the
                        # rack expands to fill a tall window)
RK_KNOB   = sc(30)      # regular knob size in the rack (base / cramped-window size)
RK_HERO   = sc(40)      # hero knob size — the ex-fader signature param
RK_GROW_MAX = 1.7       # how far rack knobs grow when a big portrait window leaves
                        # surplus room: 1.0 = base size (cramped), 1.7 = roomy.
                        # They also spread to fill the unit width (see _grow_knobs).
RK_KNOB_CHROME = sc(38) # label + value rows stacked around a knob (≈32 px); the
                        # height budget subtracts it so a grown knob's whole cell fits
RK_EQ_H   = sc(128)     # EQ band slider height (console only; rack EQ uses knobs)
RK_HDR_H  = sc(24)      # rack unit header (name plate) height
RK_EAR_W  = sc(20)      # rack ear width (portrait: vertical flange, screws top+bottom)
RK_FLANGE_H = sc(16)    # console strip flange height (landscape: horizontal flange
                        # across the top + bottom, screws left+right — same rack look)
RK_NODE_Y = sc(14)      # header center, where the cable taps into a unit
RK_KNOB_COLS = 8        # all of an FX's knobs sit in one row (keeps units short)
RK_MASTER_BG = "#272620"   # gold-tinted master bar face
RK_MASTER_BD = "#4a401f"   # master bar border

def _fit_fader(fader, height):
    """Grow a strip's fill-fader to its zone height (per-buffer Configure)."""
    fader.set_height(max(200, height - 96))


def _fit_eq(axis, bands, height):
    """Grow an EQ buffer's axis + band sliders to fill the strip height."""
    h = max(150, height - 64)   # value row + name row + padding take ~64 px
    for eb in bands:
        eb.set_height(h)
    axis.config(height=h)
    draw_eq_axis(axis, h=h)

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


def draw_connector(cv, kind, w, h):
    """Draw the signal-flow link in an inter-FX gap or an IN/OUT end cap.

    kind: "mid"  — plain connecting line, no arrow (intermediate FX -> FX)
          "feed" — line + chevron at the center (Output Gain -> Master)
          "in"   — source node on the left, line + chevron flowing right
          "out"  — line + chevron flowing right into a sink node on the right
    """
    cv.delete("all")
    yc = h // 2
    c = sc(3)

    def chevron(cx):
        cv.create_line(cx - c, yc - c - 1, cx + c, yc,
                       fill=FLOW_MARK, width=2, capstyle="round")
        cv.create_line(cx - c, yc + c + 1, cx + c, yc,
                       fill=FLOW_MARK, width=2, capstyle="round")

    def node(nx):
        r = sc(3)
        cv.create_oval(nx - r, yc - r, nx + r, yc + r, fill=FLOW_MARK, outline="")

    if kind == "in":
        nx = sc(7)
        cv.create_line(nx, yc, w, yc, fill=FLOW_LINE, width=2)
        node(nx)
        chevron(w - sc(8))
    elif kind == "out":
        nx = w - sc(7)
        cv.create_line(0, yc, nx, yc, fill=FLOW_LINE, width=2)
        node(nx)
        chevron(sc(9))
    elif kind == "feed":  # Output Gain -> Master: directional arrow
        cv.create_line(0, yc, w, yc, fill=FLOW_LINE, width=2)
        chevron(w // 2)
    else:  # mid — plain connecting line, no arrow
        cv.create_line(0, yc, w, yc, fill=FLOW_LINE, width=2)


# ----------------------------------------------------------------------------
# Rack-view drawing primitives (all flat fills, per the design handoff)
# ----------------------------------------------------------------------------
def draw_hfader(cv, value, accent, enabled, unity=None, w=190, h=34):
    """Horizontal rack fader: tick marks above/below a recessed track, optional
    unity line, and a cap with an accent center line (the HFader prototype)."""
    cv.delete("all")
    left, right = sc(12), w - sc(12)
    span = right - left
    yc = h / 2
    cap_x = left + span * (value / 255.0)
    for tk_ in (0, .12, .25, .4, .55, .7, .85, 1):
        x = left + span * tk_
        cv.create_line(x, yc - sc(9), x, yc - sc(5), fill="#34353d")
        cv.create_line(x, yc + sc(5), x, yc + sc(9), fill="#34353d")
    cv.create_rectangle(left, yc - 3.5, right, yc + 3.5, fill=WELL, outline="#0a0b0d")
    if unity is not None:
        ux = left + span * (unity / 255.0)
        cv.create_line(ux, yc - sc(11), ux, yc + sc(11), fill=accent, width=2)
    cap_w, cap_h = sc(22), sc(26)
    cv.create_rectangle(cap_x - cap_w / 2, yc - cap_h / 2,
                        cap_x + cap_w / 2, yc + cap_h / 2,
                        fill=("#3a3b45" if enabled else "#2a2b32"), outline="#121317")
    cv.create_line(cap_x, yc - sc(9), cap_x, yc + sc(9),
                   fill=(accent if enabled else FAINT), width=3, capstyle="round")


def _draw_screw(cv, cx, cy, size, angle):
    r = size / 2.0
    cv.create_oval(cx - r, cy - r, cx + r, cy + r, fill="#191a1f", outline="#3a3b45")
    dx, dy = math.cos(angle) * (r - 2), math.sin(angle) * (r - 2)
    cv.create_line(cx - dx, cy - dy, cx + dx, cy + dy, fill="#55565f", width=1)


def draw_rack_ear(cv, w, h, side, collapsed):
    """A rack ear / flange with mounting screws. Left/right ears (portrait rack)
    are a vertical flange with a screw at the top and bottom; top/bottom flanges
    (landscape console strips) are a horizontal flange with a screw at the left and
    right. A short flange — or a collapsed unit — gets a single centered screw."""
    cv.delete("all")
    if side in ("left", "right"):
        edge_x = (w - 1) if side == "left" else 0
        cv.create_line(edge_x, 0, edge_x, h, fill="#1a1b1f")
        cx = w / 2
        if collapsed or h < sc(56):
            _draw_screw(cv, cx, h / 2, sc(9), 0.6)
        else:
            _draw_screw(cv, cx, sc(12), sc(9), 0.6)
            _draw_screw(cv, cx, h - sc(12), sc(9), 2.2)
    else:   # "top" / "bottom" — horizontal flange, screws at the left + right ends
        edge_y = (h - 1) if side == "top" else 0
        cv.create_line(0, edge_y, w, edge_y, fill="#1a1b1f")
        cy = h / 2
        if collapsed or w < sc(56):
            _draw_screw(cv, w / 2, cy, sc(9), 0.6)
        else:
            _draw_screw(cv, sc(12), cy, sc(9), 0.6)
            _draw_screw(cv, w - sc(12), cy, sc(9), 2.2)


# ============================================================================
# Control widgets — each reads/writes value through the gui value cache. During
# a drag they stream the value to the board live (gui.live_commit, coalesced so
# JTAG isn't flooded) and fire the authoritative gui.commit on RELEASE; wheel /
# type / double-click commit immediately.
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

    def make_value_entry(self, parent, font, fg=READOUT, compact=False, bg=PANEL):
        """Build the editable numeric readout wired to this control.

        compact=True uses the suffix-less dB form (for the dense EQ band sliders).
        """
        fx, p = self.fx, self.p
        return ValueEntry(parent, font=font, fg=fg, bg=bg,
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
    def __init__(self, parent, gui, fx, p, accent, size=38, on_redraw=None):
        super().__init__(gui, fx, p)
        self.accent = accent
        self.size = size
        self.on_redraw = on_redraw   # optional hook (rack uses it for the mini readout)
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
        if self.on_redraw:
            self.on_redraw()

    def set_size(self, size):
        """Resize the knob in place and redraw. Used by the rack to grow knobs to
        fill a big portrait window. No-op when the size is unchanged so resize
        events don't churn redraws."""
        size = int(size)
        if size == self.size:
            return
        self.size = size
        self.cv.configure(width=size, height=size)
        self.redraw()

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
            self.gui.live_commit(self.fx, self.p)   # stream to the board mid-drag

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
            self.gui.live_commit(self.fx, self.p)   # stream to the board mid-drag

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
    def __init__(self, parent, gui, fx, p, accent, master=False, fill=False,
                 wide=False, bg=PANEL):
        super().__init__(gui, fx, p)
        self.accent = accent
        self.unity = fader_unity(fx, p)
        self.w = sc(58) if master else (sc(54) if wide else sc(46))
        self.h = sc(222) if (master or fill) else sc(200)
        f = tk.Frame(parent, bg=bg)
        self.frame = f
        lbl = plab(M.param_name(fx, p))
        if master:
            lbl = "MASTER"
        tk.Label(f, text=lbl, font=gui.f_label, fg=FAINT, bg=bg).pack(pady=(0, 4))
        self.cv = tk.Canvas(f, width=self.w, height=self.h, bg=bg,
                            highlightthickness=0)
        self.cv.pack()
        self.lbl = self.make_value_entry(
            f, font=(gui.f_fval if not master else gui.f_master),
            fg=(accent if master else READOUT), bg=bg)
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
            self.gui.live_commit(self.fx, self.p)   # stream to the board mid-drag

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


class RackFader(_Control):
    """Horizontal rack fader (the prototype's HFader): param label + editable
    readout above a horizontal track. Drag left/right, wheel steps, double-click
    resets — same gestures as the vertical console fader."""

    def __init__(self, parent, gui, fx, p, accent, w, bg=PANEL, master=False,
                 on_redraw=None, expand=False, show_top=True):
        super().__init__(gui, fx, p)
        self.accent, self.w, self.bg = accent, w, bg
        self.expand = expand            # stretch the track laterally to fill the unit
        self.h = sc(34)
        self.unity = fader_unity(fx, p)
        self.on_redraw = on_redraw
        self._extra_entries = []
        f = tk.Frame(parent, bg=bg)
        self.frame = f
        # The top row (param label + small readout) is optional: the gain stages
        # drop it since their big accent dB readout already shows the value.
        self.lbl = None
        if show_top:
            top = tk.Frame(f, bg=bg)
            top.pack(fill="x", padx=2)
            lbl = "MASTER" if master else plab(M.param_name(fx, p))
            tk.Label(top, text=lbl, font=gui.f_label, fg=FAINT, bg=bg).pack(side="left")
            self.lbl = self.make_value_entry(top, font=gui.f_val, compact=True, bg=bg)
            self.lbl.pack(side="right")
        self.cv = tk.Canvas(f, width=w, height=self.h, bg=bg, highlightthickness=0)
        if expand:
            # fill the strip laterally; <Configure> reports the real allocated
            # width so the track / ticks / cap span the whole unit, not a fixed w.
            self.cv.pack(fill="x")
            self.cv.bind("<Configure>", self._on_resize)
        else:
            self.cv.pack()
        if not self.ro:
            self.cv.configure(cursor="sb_h_double_arrow")
            self.cv.bind("<Button-1>", self._press)
            self.cv.bind("<B1-Motion>", self._motion)
            self.cv.bind("<ButtonRelease-1>", self._release)
            self.cv.bind("<Double-Button-1>", self._dbl)
            self.cv.bind("<MouseWheel>", self._wheel)
            self.cv.bind("<Button-4>", lambda e: self._step(1))
            self.cv.bind("<Button-5>", lambda e: self._step(-1))
        self.redraw()

    def attach_readout(self, parent, font, fg, bg):
        """Extra readout mirroring this fader (the master bar's big gold one)."""
        en = self.make_value_entry(parent, font=font, fg=fg, bg=bg)
        self._extra_entries.append(en)
        return en

    def redraw(self):
        draw_hfader(self.cv, self.value(), self.accent, self.active(),
                    unity=self.unity, w=self.w, h=self.h)
        if self.lbl is not None:
            self.lbl.set_display(self.value())
        for en in self._extra_entries:
            en.set_display(self.value())
        if self.on_redraw:
            self.on_redraw()

    def _on_resize(self, e):
        # the fill="x" track grew/shrank — redraw it to span the new width (which
        # also feeds drag sensitivity, since _motion scales by self.w)
        if abs(e.width - self.w) < 2:
            return
        self.w = e.width
        self.redraw()

    def _press(self, e):
        self._last = e.x

    def _motion(self, e):
        if not self.active():
            return
        dx = e.x - self._last
        self._last = e.x
        if dx:
            self.gui.set_value(self.fx, self.p,
                               self.value() + dx * (255.0 / (self.w - sc(24))))
            self.redraw()
            self.gui.live_commit(self.fx, self.p)   # stream to the board mid-drag

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
# Rack unit (portrait view) — one collapsible row of the vertical FX rack
# ============================================================================
class RackUnit:
    """One stacked rack unit: ears + name plate + body, with the FX-to-next-FX
    cable bracket drawn on the shared connector canvas to its left.

    Clicking the header folds the unit to a 1U strip that shows its signature
    value. The body renders every parameter as a Knob — the signature param as a
    larger hero knob, Reverb's decay as a Stepper — except the gain-only stages
    (Input / Output / Expression), which keep a horizontal RackFader slider.
    """

    def __init__(self, parent, gui, fx, first, last):
        self.gui, self.fx = gui, fx
        self.first, self.last = first, last
        self.collapsed = False
        self.cat = category(fx)
        accent = self._accent = ACCENT[self.cat]

        # The unit is just its framed body now; the signal cables live on a
        # single connector canvas to the right of the whole stack (drawn by
        # KfxGui._draw_rack_cables), so each FX links only to the next one.
        outer = tk.Frame(parent, bg=PANEL, highlightthickness=1,
                         highlightbackground="#303138")
        # fill + expand: when the window is taller than the rack needs, every unit
        # shares the surplus and grows taller (its controls centred); when the
        # rack overflows, units sit at natural height and the column scrolls.
        outer.pack(fill="both", expand=True, pady=(0, 0 if last else RK_ROWGAP))
        self.frame = outer

        self.ears = []
        for side in ("left", "right"):
            ear = tk.Canvas(outer, width=RK_EAR_W, height=1, bg="#232428",
                            highlightthickness=0)
            ear.pack(side=side, fill="y")
            ear.bind("<Configure>",
                     lambda e, c=ear, s=side: draw_rack_ear(c, e.width, e.height,
                                                            s, self.collapsed))
            self.ears.append(ear)

        mid = tk.Frame(outer, bg=PANEL)
        mid.pack(side="left", fill="both", expand=True)

        hdr = tk.Frame(mid, bg=accent, height=RK_HDR_H)
        hdr.pack(fill="x")
        hdr.pack_propagate(False)
        self.caret = tk.Label(hdr, text="▾", font=gui.f_btn, fg=HEADER_INK, bg=accent)
        self.caret.pack(side="left", padx=(sc(8), sc(6)))
        tk.Label(hdr, text=M.fx_name(fx), font=gui.f_btn, fg=HEADER_INK,
                 bg=accent).pack(side="left")
        tk.Label(hdr, text=CAT_LABEL[self.cat].upper(), font=gui.f_cat,
                 fg=HEADER_INK, bg=accent).pack(side="left", padx=(sc(8), 0))
        if any_readonly(fx):
            tk.Label(hdr, text=" PEDAL ", font=gui.f_cat, fg=HEADER_INK, bg=accent,
                     highlightthickness=1, highlightbackground=HEADER_INK
                     ).pack(side="left", padx=(sc(8), 0))
        tk.Label(hdr, text="F%d" % fx, font=gui.f_cat, fg=HEADER_INK,
                 bg=accent).pack(side="right", padx=(0, sc(10)))
        # collapsed-state mini readout (packed only while folded)
        self.mini = tk.Label(hdr, font=gui.f_val, fg=READOUT, bg=WELL,
                             padx=sc(7), highlightthickness=1,
                             highlightbackground="#0a0b0d")
        for wdg in (hdr,) + tuple(hdr.winfo_children()):
            wdg.bind("<Button-1>", lambda e: self.toggle())
            wdg.configure(cursor="hand2")

        self.body = tk.Frame(mid, bg=PANEL)
        self.body.pack(fill="both", expand=True)   # grows with the unit
        self._fader_ctl = None      # set after build; guards the first redraws
        self._fader_ctl = self._build_body(self.body)

    # ---- body layouts ----------------------------------------------------
    def _build_body(self, body):
        gui, fx, accent = self.gui, self.fx, self._accent
        fp = fader_param(fx)
        params = list(M.active_params(fx))

        # Gain-only stages (Input / Output / Expression) keep the horizontal
        # slider — it reads like a fader. Styled like the MASTER bar: the track
        # stretches laterally to fill the unit, with a big accent dB readout
        # pinned on the right.
        if fp is not None and len(params) == 1:
            wrap = tk.Frame(body, bg=PANEL)
            wrap.pack(fill="x", expand=True, pady=RK_PAD)   # centred vertically
            fctl = RackFader(wrap, gui, fx, fp, accent, w=sc(340),
                             on_redraw=self._update_mini, expand=True, show_top=False)
            big = fctl.attach_readout(wrap, font=gui.f_master, fg=accent, bg=PANEL)
            big.pack(side="right", padx=(sc(10), sc(16)))
            fctl.frame.pack(side="left", fill="x", expand=True, padx=(sc(16), 0))
            fctl.redraw()   # populate the big readout attached after the first draw
            return fctl

        # Everything else (Gate / Comp / Dist / Chorus / Delay / Reverb / EQ):
        # every param is a knob now. The signature (ex-fader) param becomes a
        # LARGER hero knob; Reverb's decay stays a 4-step tail stepper. All knobs
        # pack into one wrapping row so the unit stays short.
        decay_ps = [p for p in params if M.param_name(fx, p) == "decay"]
        hero = fp                                    # None for EQ (no signature)
        knob_ps = [p for p in params if p != hero and p not in decay_ps]
        cells = ([("hero", hero)] if hero is not None else []) \
            + [("knob", p) for p in knob_ps] \
            + [("step", p) for p in decay_ps]

        # Lay the controls out so they fill the unit: the row spreads its knobs
        # apart to use the width — but only up to RK_MAXGAP, past which it stops
        # spreading and the cluster just centres (each row's cells live in a
        # centred `inner` frame; _grow_knobs sets the gap). On a big portrait
        # window the knobs also grow so the surplus reads as "expanded".
        content = tk.Frame(body, bg=PANEL)
        content.pack(fill="x", expand=True, pady=RK_PAD)   # full width, centred vertically
        hero_ctl = None
        self._grow = []                              # (knob, base_size) to scale on resize
        self._grow_cells = []                        # every cell frame, for gap/centring
        self._grow_cols = min(len(cells), RK_KNOB_COLS)
        self._grow_rows = -(-len(cells) // RK_KNOB_COLS)   # ceil
        for r0 in range(0, len(cells), RK_KNOB_COLS):
            rowf = tk.Frame(content, bg=PANEL)
            rowf.pack(fill="x")
            inner = tk.Frame(rowf, bg=PANEL)
            inner.pack()                             # centred: holds the row as a group
            for kind, p in cells[r0:r0 + RK_KNOB_COLS]:
                base = None
                if kind == "hero":
                    hero_ctl = Knob(inner, gui, fx, p, accent, size=RK_HERO,
                                    on_redraw=self._update_mini)
                    ctl = hero_ctl
                    base = RK_HERO
                elif kind == "knob":
                    ctl = Knob(inner, gui, fx, p, accent, size=RK_KNOB)
                    base = RK_KNOB
                else:
                    ctl = Stepper(inner, gui, fx, p, accent)
                ctl.frame.pack(side="left", padx=RK_GAP, pady=1)
                self._grow_cells.append(ctl.frame)
                if base is not None:
                    self._grow.append((ctl, base))
        if self._grow:
            self._grow_base = max(b for _, b in self._grow)   # hero if present
            body.bind("<Configure>", self._grow_knobs)
        return hero_ctl   # signature knob drives the collapsed mini readout

    def _grow_knobs(self, e):
        """Size the rack knobs and space them so a big portrait window reads as
        roomy — knobs swell and spread — while a short/narrow one stays tight.

        Growth is bounded by the unit's WIDTH (e.width, so columns never collide)
        and by the vertical room a unit can claim. The height budget comes from the
        scroll VIEWPORT (canvas height / unit count), not this body's own height:
        the body height grows with the knobs, so feeding it back in would
        oscillate; the viewport is fixed w.r.t. knob size, so it settles in one pass.

        Spacing then spreads the row to fill the width, but no wider than RK_MAXGAP
        between cells — past that the cluster just centres (cells sit in a centred
        `inner` frame), so a few-knob unit never drifts edge-to-edge."""
        cv = getattr(self.gui, "rack_canvas", None)
        units = getattr(self.gui, "rack_units", None)
        vp = cv.winfo_height() if cv is not None else e.height
        n = max(1, len(units) if units else 1)
        # room one unit can claim from the viewport, then per knob row inside it
        per_unit = vp / n - RK_HDR_H - RK_ROWGAP
        by_h = per_unit / self._grow_rows - RK_KNOB_CHROME
        by_w = e.width / self._grow_cols - RK_GAP * 2
        k = max(1.0, min(by_w / self._grow_base, by_h / self._grow_base, RK_GROW_MAX))
        for ctl, base in self._grow:
            ctl.set_size(base * k)
        # cap the spread: fill the width with gap, clamped to [RK_GAP, RK_MAXGAP]
        cell_w = max(RK_KNOB * k, RK_CELL_MIN)
        gap = (e.width - self._grow_cols * cell_w) / self._grow_cols
        gap = int(max(RK_GAP, min(gap, RK_MAXGAP)))
        for f in self._grow_cells:
            f.pack_configure(padx=gap // 2)

    # ---- fold / unfold -----------------------------------------------------
    def _update_mini(self):
        if self._fader_ctl is None:
            return
        self.mini.config(
            text=M.fmt_value(self.fx, self._fader_ctl.p, self._fader_ctl.value()),
            fg=(READOUT if self.gui.enabled else FAINT))

    def toggle(self):
        self.set_collapsed(not self.collapsed)

    def set_collapsed(self, flag):
        if flag == self.collapsed:
            return
        self.collapsed = flag
        if flag:
            self.body.pack_forget()
            self.caret.config(text="▸")
            self.frame.pack_configure(expand=False)   # folded units stay a 1U strip
            if self._fader_ctl is not None:
                self._update_mini()
                self.mini.pack(side="right", padx=(0, sc(8)))
        else:
            self.mini.pack_forget()
            self.caret.config(text="▾")
            self.frame.pack_configure(expand=True)     # expanded units fill the surplus
            self.body.pack(fill="both", expand=True)
        # ears redraw via their own <Configure>; the right-side FX->FX cables
        # need an explicit redraw since folding changed the unit heights
        self.gui._schedule_cable_redraw()
        self.gui._paint_foldtoggle()   # keep the single fold/expand button in sync


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

        # stash the layout decisions so _populate() can build each body buffer
        self._accent = accent
        self._fp, self._eq = fp, eq
        self._knob_ps, self._decay_ps = knob_ps, decay_ps
        self._has_knobs = has_knobs
        self._fader_only, self._single_col, self._use_hero = fader_only, single_col, use_hero

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
        # the master strip wears the same gold-tinted face as the portrait rack's
        # MASTER bar; every other strip stays on the neutral PANEL background.
        self.bg = RK_MASTER_BG if self.master else PANEL
        outer = tk.Frame(parent, bg=self.bg, width=width, height=STRIP_H,
                         highlightthickness=1,
                         highlightbackground=(RK_MASTER_BD if self.master else "#303138"))
        # no extra left pad on the master: the "feed" connector sits flush against
        # it so its signal-flow line reaches the strip edge instead of leaving a gap.
        # expand+fill="both": the fitted width (set by fit_width, pinned by
        # pack_propagate False) is the MINIMUM; on a big screen the strips share
        # whatever width is left after the inter-FX gaps hit their cap.
        outer.pack(side="left", fill="both", expand=True)
        outer.pack_propagate(False)   # lock strip width (and pin the height floor)
        self.frame = outer

        # ---- rack-module styling: screw flanges across the top + bottom edges ----
        # The portrait rack units flank each unit with screwed ears on the left and
        # right; the landscape strips are tall, so the matching flanges run across
        # the top and bottom. Packed first so the body fills between them; each
        # redraws its screws on <Configure> as the strip width changes.
        self.ears = []
        for side in ("top", "bottom"):
            ear = tk.Canvas(outer, width=1, height=RK_FLANGE_H, bg="#232428",
                            highlightthickness=0)
            ear.pack(side=side, fill="x")
            ear.bind("<Configure>",
                     lambda e, c=ear, s=side: draw_rack_ear(c, e.width, e.height,
                                                            s, False))
            self.ears.append(ear)

        # ---- header name-plate + body, in one frame ----
        # _populate builds the colored name-plate (via _make_header) then the
        # body controls into a single frame that fills the strip. Bank switches
        # rewrite the live controls in place (no animation, no second buffer).
        self.hdr_label = self.hdr_row = None
        self.body = tk.Frame(outer, bg=self.bg)
        self.body.pack(side="top", fill="both", expand=True)
        self.body.pack_propagate(False)
        self.controls = self._populate(self.body, track_fit=True)

    def _make_header(self, container, track_fit):
        """Build the colored name-plate (FX title + category + F#) at the top of
        the strip body. track_fit -> stash refs for width autofit. No wraplength:
        the title stays one line and reports its true required width, which
        autofit uses to size the strip so the name never clips."""
        gui, fx, accent = self.gui, self.fx, self._accent
        hdr = tk.Frame(container, bg=accent, height=sc(46))
        hdr.pack(side="top", fill="x")
        hdr.pack_propagate(False)
        name = tk.Label(hdr, text=M.fx_name(fx), font=gui.f_head,
                        fg=HEADER_INK, bg=accent, anchor="w", justify="left")
        name.pack(fill="x", padx=8, pady=(5, 0))
        row = tk.Frame(hdr, bg=accent)
        row.pack(fill="x", padx=8)
        tk.Label(row, text=CAT_LABEL[self.cat].upper(), font=gui.f_cat,
                 fg=HEADER_INK, bg=accent).pack(side="left")
        tk.Label(row, text="F%d" % fx, font=gui.f_cat, fg=HEADER_INK,
                 bg=accent).pack(side="right")
        if track_fit:
            self.hdr_label, self.hdr_row = name, row

    def _populate(self, container, track_fit):
        """Build the header name-plate + body (EQ bands or knobs/stepper) + fader
        zone into container, and return the list of _Control instances created.
        Resize-to-fill is wired via Configure closures on the body/fader frames."""
        gui, fx, accent = self.gui, self.fx, self._accent
        fp, eq = self._fp, self._eq
        before = len(gui.controls)
        self._make_header(container, track_fit)

        if eq or self._has_knobs:
            body = tk.Frame(container, bg=PANEL)
            if eq:
                # no fader; one shared grid (axis + four bands) centered in the body.
                body.pack(side="top", fill="both", expand=True)
                body.pack_propagate(False)
                grid = tk.Frame(body, bg=PANEL)
                grid.place(relx=0.5, rely=0.5, anchor="center")
                tk.Label(grid, text="GAIN", font=gui.f_val, fg=FAINT,
                         bg=PANEL).grid(row=0, column=0, padx=(0, 2), sticky="s")
                acv = tk.Canvas(grid, width=EQ_AXIS_W, height=EQ_SLIDER_H, bg=PANEL,
                                highlightthickness=0)
                acv.grid(row=1, column=0, padx=(0, 2))
                draw_eq_axis(acv)
                tk.Label(grid, text="(dB)", font=gui.f_label, fg=FAINT,
                         bg=PANEL).grid(row=2, column=0, padx=(0, 2), pady=(2, 0),
                                        sticky="n")
                bands = [EqBand(grid, gui, fx, p, accent, col=i + 1)
                         for i, p in enumerate(M.active_params(fx))]
                if track_fit:
                    self._fit_frames.append(grid)
                # grow the bands + axis to fill the strip height, like the faders
                body.bind("<Configure>",
                          lambda e, ax=acv, bb=bands: _fit_eq(ax, bb, e.height))
            else:
                body.pack(side="top", fill="x")
                inner = tk.Frame(body, bg=PANEL)
                inner.pack(pady=(6, 2))
                if self._single_col:
                    for p in self._knob_ps:
                        Knob(inner, gui, fx, p, accent, size=sc(40)).frame.pack(pady=2)
                else:
                    if self._use_hero:
                        Knob(inner, gui, fx, self._knob_ps[0], accent,
                             size=sc(56)).frame.pack(pady=(0, 2))
                        rest = self._knob_ps[1:]
                    else:
                        rest = self._knob_ps
                    if rest:
                        grid = tk.Frame(inner, bg=PANEL)
                        grid.pack()
                        grid.columnconfigure(0, weight=1, uniform="kn")
                        grid.columnconfigure(1, weight=1, uniform="kn")
                        odd = len(rest) % 2 == 1
                        for i, p in enumerate(rest):
                            kf = Knob(grid, gui, fx, p, accent, size=sc(38)).frame
                            if odd and i == len(rest) - 1:
                                kf.grid(row=i // 2, column=0, columnspan=2, pady=1)
                            else:
                                kf.grid(row=i // 2, column=i % 2, padx=1, pady=1)
                for p in self._decay_ps:
                    Stepper(inner, gui, fx, p, accent).frame.pack(pady=2)
                if track_fit:
                    self._fit_frames.append(inner)

        if fp is not None:
            fz = tk.Frame(container, bg=self.bg, highlightthickness=0)
            fz.pack(side="top", fill="both", expand=True)
            if not self._fader_only:
                tk.Frame(fz, bg=SEP, height=1).pack(fill="x")   # divide knobs / fader
            if self.readonly:
                tk.Label(fz, text=" PEDAL ", font=gui.f_cat, fg="#6fd0c6",
                         bg="#1c2b29", bd=1, relief="solid").pack(pady=(8, 0))
            fader = Fader(fz, gui, fx, fp, accent, master=self.master,
                          fill=self.fill, wide=self._fader_only, bg=self.bg)
            fader.frame.pack(pady=(8, 6), expand=True)
            if track_fit:
                self._fit_frames.append(fader.frame)
            if self.master:
                tk.Label(fz, text="MAIN BUS", font=gui.f_cat, fg="#e7c463",
                         bg="#2a281f", bd=1, relief="solid").pack(pady=(0, 8))
            fz.bind("<Configure>", lambda e, fd=fader: _fit_fader(fd, e.height))

        return gui.controls[before:]

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

    def redraw(self):
        for c in self.controls:
            c.redraw()


# ============================================================================
# Main application
# ============================================================================
def _set_app_user_model_id(app_id):
    """Windows: give this process its own taskbar identity.

    Without this, Windows groups the window under the python.exe interpreter and
    the taskbar shows Python's icon instead of ours. Setting an explicit
    AppUserModelID *before* any window is created detaches us, so the taskbar
    button picks up the window icon set via iconphoto(). No-op off Windows.
    """
    if sys.platform != "win32":
        return
    try:
        import ctypes
        ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(app_id)
    except Exception:
        pass


class KfxGui(tk.Tk):
    def __init__(self):
        _set_app_user_model_id("kfx.engine.gui")
        super().__init__()
        self.title("KFX Engine GUI — Param Editor")
        self._apply_window_icon()
        self.geometry("1400x820")   # tall enough that the densest strips fit unclipped
        self.configure(bg=BG)
        # min width low enough that the window can go portrait (taller than
        # wide), which swaps the console for the vertical rack view; the
        # landscape console falls back to its horizontal scrollbar when narrow.
        self.minsize(sc(700), sc(700))

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
        self._grow_gaps = []        # (frame, base_w) inter-FX gaps, widened by _relayout

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
        # live-drag streaming: latest pending value per (fx, p) and a one-in-flight
        # gate so mid-drag writes track the board in real time without flooding JTAG
        self._live_pending = {}     # (fx, p) -> newest value awaiting a live write
        self._live_busy = False     # True while a live write is in the worker
        threading.Thread(target=self._worker, daemon=True).start()
        self.after(40, self._drain)

        self._build_toolbar()
        self._build_banks()
        # both views live inside one center container between the bank bar and
        # the status bar; _set_view packs whichever matches the window aspect
        self.center = tk.Frame(self, bg=BG)
        self.center.pack(fill="both", expand=True)
        self._build_console()
        self._build_rack()
        self._build_status()
        self._build_overlay()
        self._autofit_strips()      # size every strip to its real content width

        self._view = None
        self._set_view("console")   # initial geometry is landscape
        self.bind("<Configure>", self._on_root_configure)

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

    def _apply_window_icon(self):
        """Set the OS window icon (title-bar top-left + Windows taskbar button).

        Hands Tk several sizes of logo.png so it can pick a crisp one for the
        ~16px title bar and ~32px taskbar render. References are kept on self so
        Tk doesn't garbage-collect the images out from under the window. Paired
        with the AppUserModelID set in _set_app_user_model_id(), the taskbar
        shows this icon instead of the generic python.exe icon. Silently leaves
        the default icon if logo.png is missing/unreadable.
        """
        path = os.path.join(HERE, "logo.png")
        imgs = [self._load_logo(path, s) for s in (64, 48, 32, 16)]
        self._icon_imgs = [im for im in imgs if im is not None]
        if not self._icon_imgs:
            return
        try:
            self.iconphoto(True, *self._icon_imgs)
        except Exception:
            pass

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
        # rack-only fold/expand toggle — packed/unpacked by _set_view. One button:
        # its label tracks the rack state (EXPAND when everything is folded, else
        # FOLD) and clicking flips the whole rack to the other state.
        self.foldtoggle_btn = tk.Label(bar, text="▸ FOLD", font=self.f_btn,
                                       fg=DIM, bg="#1b1c21", padx=6, pady=6,
                                       cursor="hand2")
        self.foldtoggle_btn.bind("<Button-1>", lambda e: self.toggle_fold_all())
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
        wrap = self.console_frame = tk.Frame(self.center, bg=BG)
        hsb = self._console_hsb = tk.Scrollbar(wrap, orient="horizontal")
        hsb.pack(side="bottom", fill="x")
        canvas = tk.Canvas(wrap, bg=BG, highlightthickness=0,
                           xscrollcommand=self._console_xscroll)
        canvas.pack(side="top", fill="both", expand=True)
        hsb.config(command=canvas.xview)
        inner = tk.Frame(canvas, bg=BG)
        win = canvas.create_window((0, 0), window=inner, anchor="nw")
        self._console_canvas = canvas
        inner.bind("<Configure>",
                   lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
        # Stretch the inner frame to the viewport so the chain fills the window:
        #  - height (but never below one strip) lets the fill-faders run full height;
        #  - width (but never below the natural content) gives _relayout room to
        #    spread the chain across a wide screen. When the content is wider than
        #    the viewport, the window keeps its natural width and the horizontal
        #    scrollbar takes over instead.
        def _on_canvas_configure(e):
            canvas.itemconfigure(
                win,
                width=max(e.width, inner.winfo_reqwidth()),
                height=max(e.height, STRIP_H + 24))
            self._relayout(e.width)
        canvas.bind("<Configure>", _on_canvas_configure)
        pad = tk.Frame(inner, bg=BG)
        pad.pack(padx=sc(12), pady=sc(12), fill="both", expand=True)

        # iterate M.active_fx() in order; globals become the MASTER strip on the right.
        # Strips are interleaved with signal-flow connectors and bookended by IN/OUT
        # caps, so the row reads as a chain:  IN > FX > FX > ... > MASTER > OUT.
        channels = [fx for fx in M.active_fx() if not M.is_global(fx)]
        masters = [fx for fx in M.active_fx() if M.is_global(fx)]
        chain = channels + masters
        self._connector(pad, "in")
        for i, fx in enumerate(chain):
            self.strips.append(Strip(pad, self, fx))
            if i < len(chain) - 1:
                # arrow only where it feeds the Master (Output Gain -> Master);
                # the rest are plain connecting lines
                self._connector(pad, "feed" if M.is_global(chain[i + 1]) else "mid")
        self._connector(pad, "out")

    def _console_xscroll(self, first, last):
        """Drive the console's horizontal scrollbar — but hide it whenever the whole
        chain already fits the window (nothing to scroll), showing it again only when
        the row overflows. Mirrors the rack view's vertical-scrollbar behavior.

        Toggling a bottom-packed scrollbar changes only the canvas height, not its
        width, so the horizontal fit it depends on never changes — no oscillation."""
        hsb = self._console_hsb
        hsb.set(first, last)
        fits = float(first) <= 0.001 and float(last) >= 0.999
        if fits and hsb.winfo_ismapped():
            hsb.pack_forget()
        elif not fits and not hsb.winfo_ismapped():
            hsb.pack(side="bottom", fill="x", before=self._console_canvas)

    def _connector(self, parent, kind):
        """A thin full-height gap carrying the signal-flow line. 'in'/'out' caps
        add a labelled port node; 'mid'/'feed' link neighbouring strips and, on a
        wide screen, stretch (expand) so the chain spreads evenly across the width.
        The line is redrawn to the gap's live width so it always reaches both
        strips no matter how wide the gap grows."""
        w = PORT_W if kind in ("in", "out") else (CONN_W * 2 if kind == "feed" else CONN_W)
        grow = kind in ("mid", "feed")          # inter-FX gaps widen on big screens
        fr = tk.Frame(parent, bg=BG, width=w)
        # Fixed width (no expand): _relayout sets each grow gap's width directly,
        # capped at base + GAP_EXTRA_MAX; the strips' expand soaks up the rest.
        fr.pack(side="left", fill="y")
        fr.pack_propagate(False)
        # span the gap's full width at its vertical middle, so the flow line
        # connects the strips even after the gap stretches.
        cv = tk.Canvas(fr, width=w, height=CONN_H, bg=BG, highlightthickness=0)
        cv.place(relx=0, rely=0.5, anchor="w", relwidth=1.0)

        def _redraw(_=None):
            cw = max(fr.winfo_width(), w)
            draw_connector(cv, kind, cw, CONN_H)
            if kind in ("in", "out"):
                cv.create_text(cw / 2, CONN_H // 2 - sc(12), text=kind.upper(),
                               fill=FLOW_MARK, font=self.f_cat)

        fr.bind("<Configure>", _redraw)
        _redraw()
        if grow:
            self._grow_gaps.append((fr, w))     # (frame, base width) for _relayout

    # ---------------------------------------------------------------- rack view
    def _build_rack(self):
        """Vertical FX rack (portrait): the chain stacked as collapsible rack
        units in a scrolling column, the patch cable down the left, and the
        gold MASTER bar pinned at the bottom, above the status bar."""
        rv = self.rack_frame = tk.Frame(self.center, bg=BG)
        area = tk.Frame(rv, bg=BG)
        area.pack(fill="both", expand=True)
        vsb = self._rack_vsb = tk.Scrollbar(area, orient="vertical")
        vsb.pack(side="right", fill="y")
        cv = tk.Canvas(area, bg=BG, highlightthickness=0,
                       yscrollcommand=vsb.set, yscrollincrement=sc(40))
        cv.pack(side="left", fill="both", expand=True)
        vsb.config(command=cv.yview)
        self.rack_canvas = cv
        inner = self._rack_inner = tk.Frame(cv, bg=BG)
        self._rack_win = cv.create_window((0, 0), window=inner, anchor="n")
        # Re-centre on any size change. We DON'T use scrollregion=bbox("all"):
        # the window item's bbox starts at its (centred) x offset, which made the
        # canvas shift the column horizontally. Pinning the scrollregion to the
        # canvas width (x: 0..w) keeps X fixed so the centred coords actually hold.
        inner.bind("<Configure>", lambda e: self._center_rack())
        cv.bind("<Configure>", lambda e: self._center_rack())

        content = tk.Frame(inner, bg=BG)
        content.pack(fill="both", expand=True, padx=sc(16), pady=(sc(14), sc(6)))
        # connector canvas on the LEFT carries the squared bracket cables; a
        # matching spacer on the right keeps the unit stack centred in the column
        # (height=1 so it doesn't inflate the column — fill="y" stretches it).
        self.conn_canvas = tk.Canvas(content, width=RK_CONN_W, height=1, bg=BG,
                                     highlightthickness=0)
        self.conn_canvas.pack(side="left", fill="y")
        self.conn_canvas.bind("<Configure>", lambda e: self._draw_rack_cables())
        # Canvas (not Frame) holds its width reliably so the unit stack stays centred
        self._rack_spacer = tk.Canvas(content, width=RK_CONN_W, height=1, bg=BG,
                                      highlightthickness=0)
        self._rack_spacer.pack(side="right", fill="y")
        row_area = tk.Frame(content, bg=BG)
        row_area.pack(side="left", fill="both", expand=True)

        self.rack_units = []
        channels = [fx for fx in M.active_fx() if not M.is_global(fx)]
        for i, fx in enumerate(channels):
            self.rack_units.append(
                RackUnit(row_area, self, fx, first=(i == 0),
                         last=(i == len(channels) - 1)))

        self._build_rack_master(rv)
        self._schedule_cable_redraw()

        # wheel-scroll the rack from anywhere inside it — except over controls
        # that step themselves (they bind their own wheel handlers)
        self.bind_class("kfxrackscroll", "<MouseWheel>", self._rack_wheel)
        self.bind_class("kfxrackscroll", "<Button-4>",
                        lambda e: self._rack_scroll(-1, e))
        self.bind_class("kfxrackscroll", "<Button-5>",
                        lambda e: self._rack_scroll(1, e))
        self._bind_rack_scroll(rv)

    def _build_rack_master(self, rv):
        """The sticky gold MASTER bar: name plate, a horizontal fader that
        stretches across the bar, big readout and MAIN BUS badge — always visible
        while the rack scrolls behind it."""
        masters = [fx for fx in M.active_fx() if M.is_global(fx)]
        if not masters:
            return
        fx = masters[0]
        fp = fader_param(fx)
        accent = ACCENT["master"]
        mbg = RK_MASTER_BG

        tk.Frame(rv, bg="#0e0f12", height=1).pack(fill="x")
        wrap = tk.Frame(rv, bg=BG)
        wrap.pack(fill="x")
        bar = tk.Frame(wrap, bg=mbg, highlightthickness=1,
                       highlightbackground=RK_MASTER_BD)
        # spans the full width, like the rack column above it
        bar.pack(fill="x", padx=sc(42), pady=sc(8))

        for side in ("left", "right"):
            ear = tk.Canvas(bar, width=RK_EAR_W, height=1, bg="#232428",
                            highlightthickness=0)
            ear.pack(side=side, fill="y")
            ear.bind("<Configure>",
                     lambda e, c=ear, s=side: draw_rack_ear(c, e.width,
                                                            e.height, s, True))
        body = tk.Frame(bar, bg=mbg)
        body.pack(side="left", fill="x", expand=True, padx=sc(12), pady=sc(8))
        plate = tk.Frame(body, bg=accent, padx=sc(10), pady=sc(4))
        plate.pack(side="left", padx=(0, sc(12)))
        tk.Label(plate, text=M.fx_name(fx), font=self.f_btn, fg=HEADER_INK,
                 bg=accent).pack(anchor="w")
        tk.Label(plate, text="MASTER · F%d" % fx, font=self.f_cat,
                 fg=HEADER_INK, bg=accent).pack(anchor="w")
        badge = tk.Label(body, text="MAIN BUS", font=self.f_cat, fg="#e7c463",
                         bg="#2a281f", highlightthickness=1,
                         highlightbackground=RK_MASTER_BD, padx=sc(7), pady=sc(3))
        badge.pack(side="right")
        fctl = RackFader(body, self, fx, fp, accent, w=sc(260), bg=mbg,
                         master=True, expand=True)
        big = fctl.attach_readout(body, font=self.f_master, fg=accent, bg=mbg)
        big.pack(side="right", padx=(sc(10), sc(12)))
        fctl.frame.pack(side="left", fill="x", expand=True, padx=(0, sc(10)))
        fctl.redraw()   # refresh the big readout attached after the first draw

    def _center_rack(self):
        """Size the rack column to fill the scroll canvas (width and, when there's
        surplus, height). Pins the scrollregion's x-extent to the canvas width so
        X never shifts."""
        cv = getattr(self, "rack_canvas", None)
        if cv is None:
            return
        w = cv.winfo_width()
        if w <= 1:
            return
        # Width: fill the whole canvas so the FX panels stretch across the window
        # instead of leaving big empty side margins.
        # Height: match the viewport when the rack is shorter (units share the
        # surplus → taller FX + the row gaps); keep natural height when it's taller
        # so it scrolls.
        natural = self._rack_inner.winfo_reqheight()
        vp = cv.winfo_height()
        h = max(natural, vp)
        cv.itemconfigure(self._rack_win, width=w, height=h)
        cv.coords(self._rack_win, w / 2, 0)
        cv.configure(scrollregion=(0, 0, w, h))
        # Hide the scrollbar when the whole rack fits (it's expanded to fill);
        # show it only when the content overflows and really needs scrolling.
        # Toggling it changes the canvas width, not height, so there's no loop.
        need = natural > vp
        vsb = self._rack_vsb
        if need and not vsb.winfo_ismapped():
            vsb.pack(side="right", fill="y", before=cv)
        elif not need and vsb.winfo_ismapped():
            vsb.pack_forget()

    def fold_all(self, fold):
        for u in self.rack_units:
            u.set_collapsed(fold)
        self._paint_foldtoggle()

    def toggle_fold_all(self):
        # fold everything, unless it's already all folded — then expand everything
        self.fold_all(not all(u.collapsed for u in self.rack_units))

    def _paint_foldtoggle(self):
        """Sync the single fold/expand button's label to the rack state, so it shows
        the action it will perform (FOLD while anything is open, EXPAND once all are
        folded). Also keeps it in step with per-unit header clicks."""
        btn = getattr(self, "foldtoggle_btn", None)
        if btn is None:
            return
        folded = bool(self.rack_units) and all(u.collapsed for u in self.rack_units)
        btn.config(text="▾ EXPAND" if folded else "▸ FOLD")

    def _schedule_cable_redraw(self):
        # widget positions are only valid once layout settles; coalesce the many
        # callers (build, fold, view-swap, resize) into a single idle redraw
        if getattr(self, "_cable_pending", False):
            return
        self._cable_pending = True

        def go():
            self._cable_pending = False
            # force pending geometry (fold/unfold height changes) to settle so
            # winfo_height() is current before we measure unit positions
            self.update_idletasks()
            self._center_rack()
            self._draw_rack_cables()
        self.after_idle(go)

    def _draw_rack_cables(self):
        """Left-side signal cables: one separate squared bracket per adjacent
        pair of FX — straight out to a vertical spine, straight down, then back
        in with an arrowhead pointing INTO the next effect (a right-angled `[`).
        Each bracket links exactly one FX to the one below it; nothing runs as a
        continuous line from input to the end."""
        cv = getattr(self, "conn_canvas", None)
        if cv is None:
            return
        cv.delete("all")
        w = cv.winfo_width()
        if w <= 1:
            return
        base = cv.winfo_rooty()
        units = self.rack_units
        x_in = w - sc(2)        # cable foot / arrow tip, at the units' left edge
        x_out = sc(4)           # vertical spine of the bracket, near the far left
        for i in range(len(units) - 1):
            u, v = units[i].frame, units[i + 1].frame
            if not (u.winfo_ismapped() and v.winfo_ismapped()):
                continue
            # taller bracket: tap the middle of FX i, run down, into FX i+1's head
            y0 = u.winfo_rooty() - base + int(u.winfo_height() * 0.5)  # mid of FX i
            y1 = v.winfo_rooty() - base + RK_NODE_Y                    # into FX i+1
            # square corners: out-left, down the spine, in-right into the unit
            cv.create_line(x_in, y0, x_out, y0, x_out, y1, x_in, y1,
                           fill=CABLE, width=sc(3), capstyle="projecting",
                           joinstyle="miter", arrow="last",
                           arrowshape=(sc(8), sc(10), sc(5)))
            r = sc(3)           # solder node where the cable leaves FX i
            cv.create_oval(x_in - r, y0 - r, x_in + r, y0 + r,
                           fill=CABLE_HI, outline="#2a1207")

    def _bind_rack_scroll(self, w):
        w.bindtags(w.bindtags() + ("kfxrackscroll",))
        for ch in w.winfo_children():
            self._bind_rack_scroll(ch)

    def _rack_wheel(self, e):
        self._rack_scroll(-1 if e.delta > 0 else 1, e)

    def _rack_scroll(self, d, e):
        try:
            # controls that handle the wheel themselves win over rack scrolling
            if e.widget.bind("<MouseWheel>") or e.widget.bind("<Button-4>"):
                return
        except Exception:
            pass
        self.rack_canvas.yview_scroll(d, "units")

    # ---------------------------------------------------------------- view swap
    def _set_view(self, mode):
        """Swap between the landscape mixer console and the portrait rack."""
        if mode == self._view:
            return
        self._view = mode
        if mode == "rack":
            self.console_frame.pack_forget()
            self.rack_frame.pack(fill="both", expand=True)
            # to the left of the follow toggle (which is rightmost)
            self.foldtoggle_btn.pack(side="right", pady=(6, 0))
            self._paint_foldtoggle()
            self._schedule_cable_redraw()   # positions are valid once shown
        else:
            self.rack_frame.pack_forget()
            self.console_frame.pack(fill="both", expand=True)
            self.foldtoggle_btn.pack_forget()
        for c in self.controls:    # sync the freshly shown view's readouts
            c.redraw()

    def _on_root_configure(self, e):
        if e.widget is not self:
            return
        if e.width <= 1 or e.height <= 1:
            return
        self._set_view("rack" if e.height > e.width else "console")

    def _autofit_strips(self):
        # After layout, size each strip to its real rendered content so titles and
        # readouts never clip. Dynamic — no per-strip widths to hand-tune.
        self.update_idletasks()
        for s in self.strips:
            s.fit_width()
        self.update_idletasks()
        self._relayout()

    def _relayout(self, vw=None):
        # Spread the chain across a wide screen: widen each inter-FX gap by an
        # equal share of the spare width, but only up to GAP_EXTRA_MAX. Anything
        # left after the gaps are capped is absorbed by the strips (which expand),
        # so on a big screen the FX themselves grow too. On a narrow screen the
        # spare width is negative, gaps stay at their base, and the row scrolls.
        if not self._grow_gaps:
            return
        if vw is None:
            vw = self._console_canvas.winfo_width()
        if vw <= 1:
            return
        used = sum(s.frame.winfo_reqwidth() for s in self.strips)
        used += 2 * PORT_W                       # IN / OUT end caps
        used += sum(base for _fr, base in self._grow_gaps)
        spare = vw - used - 2 * sc(12)           # minus pad's left+right padding
        share = 0 if spare <= 0 else min(spare // len(self._grow_gaps), GAP_EXTRA_MAX)
        for fr, base in self._grow_gaps:
            fr.config(width=base + share)

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
                    if isinstance(res, P.TimeoutError_):
                        # board went silent mid-command (almost always a reset /
                        # re-program that kills the JTAG-UART). Tell the user and
                        # close the app; the window is gone after this, so stop.
                        self._connection_lost(str(res))
                        return
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

    def _write_values_from_dump(self, data):
        for c in self.controls:
            b = 0 if M.is_global(c.fx) else self.bank
            try:
                self.values[(c.fx, c.p)] = data[P.dump_index(b, c.fx, c.p)]
            except Exception:
                pass

    def _apply_dump(self, data):
        # Bank switches (and every other read) apply instantly: write the new
        # values, redraw every control, then flush once. The single explicit
        # update_idletasks() repaints all canvases in one batch instead of
        # letting the event loop dribble their idle redraws out over several
        # frames, which is what made the values appear to update left-to-right.
        self._write_values_from_dump(data)
        for c in self.controls:
            c.redraw()
        self.update_idletasks()
        self.set_status("Read bank %d (%s)." % (self.bank, M.bank_name(self.bank)), "ok")

    def commit(self, fx, p):
        if not self.client or M.is_read_only(fx, p):
            return
        # this is the authoritative write (mouse release / wheel / type / reset):
        # supersede any value still queued from the live drag of this same param.
        self._live_pending.pop((fx, p), None)
        value = clamp(self.get_value(fx, p))
        bank = 0 if M.is_global(fx) else self.bank   # global writes go to bank 0 (mirrored)
        name = "%s / %s" % (M.fx_name(fx), M.param_name(fx, p))
        shown = M.fmt_value(fx, p, value)
        self.submit(lambda: self.client.write_param(bank, fx, p, value),
                    lambda r: self.set_status("Wrote %s = %s" % (name, shown), "ok"))

    def live_commit(self, fx, p):
        """Stream a parameter to the board mid-drag so it tracks the control in
        real time instead of waiting for the mouse release.

        Writes are coalesced so the JTAG link is never flooded: at most one live
        write is in flight at a time and only the newest value per (fx, p) is
        sent — intermediate drag positions are dropped. The drag's end still
        calls commit() for the final, authoritative write (and the status line).
        """
        if not self.client or M.is_read_only(fx, p):
            return
        self._live_pending[(fx, p)] = clamp(self.get_value(fx, p))
        self._pump_live()

    def _pump_live(self):
        # send one coalesced live value if the link is free; chains via _live_done
        if self._live_busy or not self._live_pending:
            return
        (fx, p), value = next(iter(self._live_pending.items()))
        del self._live_pending[(fx, p)]
        bank = 0 if M.is_global(fx) else self.bank
        self._live_busy = True
        # no status update per write — the live readout already shows the value,
        # and spamming the status bar dozens of times a second is just noise.
        self.submit(lambda: self.client.write_param(bank, fx, p, value),
                    self._live_done)

    def _live_done(self, _r):
        self._live_busy = False
        self._pump_live()   # flush whatever the drag queued while this write ran

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
        self.refresh()       # re-read repopulates non-global strips; master stays put

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
        # Parse the file on the UI thread and reflect it on the controls RIGHT
        # AWAY, so the values change the instant you pick the file instead of only
        # after all ~180 per-parameter writes have trickled out over JTAG (which
        # takes a couple of seconds and otherwise looks like nothing happened).
        try:
            entries, warnings = presets.parse_preset(path)
        except Exception as e:
            self._error("Could not read preset:\n%s" % e)
            return
        self._show_entries(entries)
        # Hold a "writing to the board" popup up the whole time the import runs —
        # it is ~180 serial JTAG writes and takes a couple of seconds (same idea
        # as the Save/Load Flash overlay). The controls were updated just above,
        # underneath the overlay, so they already show the imported values the
        # moment it closes; the final refresh in _on_import re-syncs with the board.
        self.submit(lambda: presets.write_entries(self.client, entries),
                    lambda written: self._on_import((written, warnings)),
                    busy=("Importing preset",
                          "Writing %d parameters to the board over JTAG…" % len(entries)))

    def _show_entries(self, entries):
        """Apply parsed preset entries to the displayed value cache (for the bank
        currently in view) and repaint every control. No forced flush: the repaint
        lands under the import overlay (which is lifted on top), so the values are
        ready when it closes without flashing on screen before it appears."""
        for (bank, fx, p, val) in entries:
            b = 0 if M.is_global(fx) else self.bank
            if bank == b:
                self.values[(fx, p)] = clamp(val)
        for c in self.controls:
            c.redraw()

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
            self.refresh()       # reload this bank's params (and pedal) via dump
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
        # a failed job (possibly a live drag write) clears the one-in-flight gate
        # so live streaming can resume; drop stale pending so we don't retry-storm.
        self._live_busy = False
        self._live_pending.clear()
        self.set_status(msg.replace("\n", " "), "bad")
        messagebox.showwarning("KFX Engine", msg)

    def _connection_lost(self, msg):
        """A read timed out — the board stopped responding. There's no way to
        re-handshake the dead JTAG-UART in place, so warn the user (it was most
        likely a board reset) and close the app on OK; a fresh launch reconnects.
        """
        # disable board ops first so the idle poller doesn't fire doomed jobs
        # behind the modal dialog, then clear any in-flight live-drag state.
        self.enabled = False
        self.client = None
        self._live_busy = False
        self._live_pending.clear()
        self.set_status(msg.replace("\n", " ") + " — board reset? Restart to reconnect.",
                        "bad")
        messagebox.showwarning(
            "KFX Engine — connection lost",
            msg + "\n\nThe board stopped responding. The RESET button may have "
            "been pressed (or the board was re-programmed or unplugged), which "
            "closes the JTAG-UART link.\n\n"
            "Restart the application to reconnect.")
        self.destroy()   # close the window once the user clicks OK


def main():
    KfxGui().mainloop()


if __name__ == "__main__":
    main()
