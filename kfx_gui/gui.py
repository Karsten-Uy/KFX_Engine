"""
gui.py — KFX Engine parameter editor (Tkinter; no heavy desktop-toolkit deps).

Connects to the pedalboard over the JTAG-UART, displays all FX parameters with
sliders/spin-boxes, and supports live edits, scoped reset-to-default, flash
save/load, and JSON preset export/import.

Run:  uv run python gui.py
Prereqs: `uv sync` (installs intel-jtag-uart); Quartus installed so the
jtag_atlantic library is available; release any other JTAG session first.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import protocol as P  # noqa: E402
import params as M    # noqa: E402
import presets        # noqa: E402

import tkinter as tk                       # noqa: E402
from tkinter import ttk, filedialog, messagebox  # noqa: E402


class KfxGui(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("KFX Engine — Parameter Editor (kfx_gui)")
        self.geometry("580x780")
        self.client = None
        self.vars = {}      # (fx, param) -> IntVar
        self.widgets = {}   # (fx, param) -> (scale, spin)

        # ---- top bar ----
        top = ttk.Frame(self)
        top.pack(fill="x", padx=8, pady=6)
        self.connect_btn = ttk.Button(top, text="Connect", command=self.do_connect)
        self.connect_btn.pack(side="left")
        self.conn_lbl = ttk.Label(top, text="Not connected")
        self.conn_lbl.pack(side="left", padx=8)
        ttk.Label(top, text="Bank:").pack(side="left", padx=(16, 2))
        self.bank_cb = ttk.Combobox(
            top, state="readonly", width=14,
            values=[f"{b} — {M.bank_name(b)}" for b in range(P.BANK_COUNT)])
        self.bank_cb.current(0)
        self.bank_cb.bind("<<ComboboxSelected>>", lambda e: self.refresh())
        self.bank_cb.pack(side="left")

        # ---- scrollable FX area ----
        mid = ttk.Frame(self)
        mid.pack(fill="both", expand=True, padx=8)
        canvas = tk.Canvas(mid, highlightthickness=0)
        vsb = ttk.Scrollbar(mid, orient="vertical", command=canvas.yview)
        canvas.configure(yscrollcommand=vsb.set)
        vsb.pack(side="right", fill="y")
        canvas.pack(side="left", fill="both", expand=True)
        inner = ttk.Frame(canvas)
        win = canvas.create_window((0, 0), window=inner, anchor="nw")
        inner.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.bind("<Configure>", lambda e: canvas.itemconfig(win, width=e.width))
        canvas.bind_all("<MouseWheel>", lambda e: canvas.yview_scroll(int(-e.delta / 120), "units"))
        for fx in M.active_fx():
            self._build_fx(inner, fx)

        # ---- action buttons ----
        act = ttk.Frame(self)
        act.pack(fill="x", padx=8, pady=6)
        self.btns = []
        for text, cmd in [
            ("Read", self.refresh), ("Reset Bank", self.reset_bank),
            ("Reset All", self.reset_all), ("Save Flash", self.save_flash),
            ("Load Flash", self.load_flash), ("Export…", self.export_preset),
            ("Import…", self.import_preset),
        ]:
            b = ttk.Button(act, text=text, command=cmd)
            b.pack(side="left", padx=2)
            self.btns.append(b)

        self.status = tk.StringVar(value="Ready — click Connect.")
        ttk.Label(self, textvariable=self.status, relief="sunken", anchor="w").pack(
            fill="x", side="bottom")

        self.set_connected(False)

    # ---- widget construction ----
    def _build_fx(self, parent, fx):
        title = f"FX{fx} — {M.fx_name(fx)}" + ("  (global)" if M.is_global(fx) else "")
        lf = ttk.LabelFrame(parent, text=title)
        lf.pack(fill="x", expand=True, pady=3, padx=2)
        lf.columnconfigure(1, weight=1)
        for row, p in enumerate(M.active_params(fx)):
            ro = M.is_read_only(fx, p)
            name = M.param_name(fx, p) + ("  (pedal)" if ro else "")
            ttk.Label(lf, text=name, width=12).grid(row=row, column=0, sticky="w", padx=4, pady=1)
            var = tk.IntVar(value=0)
            scale = tk.Scale(lf, from_=M.PARAM_MIN, to=M.PARAM_MAX, orient="horizontal",
                             variable=var, showvalue=False)
            scale.grid(row=row, column=1, sticky="ew", padx=4)
            spin = ttk.Spinbox(lf, from_=M.PARAM_MIN, to=M.PARAM_MAX, width=5, textvariable=var)
            spin.grid(row=row, column=2, padx=4)
            self.vars[(fx, p)] = var
            self.widgets[(fx, p)] = (scale, spin)
            if ro:
                scale.configure(state="disabled")
                spin.configure(state="disabled")
            else:
                scale.bind("<ButtonRelease-1>", lambda e, f=fx, pp=p: self.commit(f, pp))
                spin.bind("<Return>", lambda e, f=fx, pp=p: self.commit(f, pp))
                spin.bind("<FocusOut>", lambda e, f=fx, pp=p: self.commit(f, pp))

    # ---- connection / state ----
    def set_connected(self, ok: bool):
        state = "normal" if ok else "disabled"
        self.bank_cb.configure(state="readonly" if ok else "disabled")
        for b in self.btns:
            b.configure(state=state)
        for (fx, p), (scale, spin) in self.widgets.items():
            if M.is_read_only(fx, p):
                continue
            scale.configure(state=state)
            spin.configure(state=state)
        self.connect_btn.configure(text="Reconnect" if ok else "Connect")

    def do_connect(self):
        try:
            self.client = P.Client(P.JtagTransport())
            vmaj, vmin = self.client.ping()
        except Exception as e:  # import error, no device, busy JTAG, etc.
            self.client = None
            self.set_connected(False)
            self.conn_lbl.config(text="Not connected")
            self._error(f"Connect failed:\n{e}")
            return
        self.conn_lbl.config(text=f"Connected — firmware v{vmaj}.{vmin}")
        self.set_connected(True)
        self.refresh()

    # ---- board operations ----
    def refresh(self):
        if not self.client:
            return
        try:
            data = self.client.dump()
        except P.ProtocolError as e:
            self._error(f"Read failed:\n{e}")
            return
        bank = self.bank_cb.current()
        for (fx, p), var in self.vars.items():
            b = 0 if M.is_global(fx) else bank
            var.set(data[P.dump_index(b, fx, p)])
        self.status.set(f"Read bank {bank} ({M.bank_name(bank)}).")

    def commit(self, fx, param):
        if not self.client or M.is_read_only(fx, param):
            return
        try:
            value = int(self.vars[(fx, param)].get())
        except tk.TclError:
            return  # invalid entry in the spinbox
        value = max(M.PARAM_MIN, min(M.PARAM_MAX, value))
        bank = 0 if M.is_global(fx) else self.bank_cb.current()
        try:
            self.client.write_param(bank, fx, param, value)
            self.status.set(f"Wrote {M.fx_name(fx)} / {M.param_name(fx, param)} = {value}")
        except P.ProtocolError as e:
            self._error(str(e))

    def reset_bank(self):
        if not self.client:
            return
        bank = self.bank_cb.current()
        self._guard(lambda: self.client.reset(P.SCOPE_BANK, bank=bank),
                    f"Reset bank {bank} to defaults.")
        self.refresh()

    def reset_all(self):
        if not self.client:
            return
        if not messagebox.askyesno("Reset All", "Reset ALL banks to factory defaults?"):
            return
        self._guard(lambda: self.client.reset(P.SCOPE_ALL), "Reset all banks to defaults.")
        self.refresh()

    def save_flash(self):
        self._guard(lambda: self.client.save_flash(),
                    "Save started — takes ~3 s, audio mutes during the write.")

    def load_flash(self):
        self._guard(lambda: self.client.load_flash(), "Loaded banks from flash.")
        self.refresh()

    def export_preset(self):
        if not self.client:
            return
        path = filedialog.asksaveasfilename(
            title="Export preset", defaultextension=".json",
            initialfile="kfx_preset.json", filetypes=[("JSON", "*.json")])
        if not path:
            return
        try:
            presets.export_preset(self.client, path)
            self.status.set(f"Exported to {path}")
        except Exception as e:
            self._error(f"Export failed:\n{e}")

    def import_preset(self):
        if not self.client:
            return
        path = filedialog.askopenfilename(title="Import preset", filetypes=[("JSON", "*.json")])
        if not path:
            return
        try:
            written, warnings = presets.import_preset(self.client, path)
        except Exception as e:
            self._error(f"Import failed:\n{e}")
            return
        self.refresh()
        msg = f"Imported {written} parameters."
        if warnings:
            msg += "\n\nWarnings:\n" + "\n".join(warnings)
        messagebox.showinfo("Import", msg)

    # ---- helpers ----
    def _guard(self, fn, ok_msg):
        if not self.client:
            return
        try:
            fn()
            self.status.set(ok_msg)
        except P.ProtocolError as e:
            self._error(str(e))

    def _error(self, msg):
        self.status.set(msg.replace("\n", " "))
        messagebox.showwarning("kfx_gui", msg)


def main():
    KfxGui().mainloop()


if __name__ == "__main__":
    main()
