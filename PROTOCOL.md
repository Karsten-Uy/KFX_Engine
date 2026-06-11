# KFX Engine — JTAG Message Protocol

This document is the authoritative specification of the byte-level message
protocol the PC host and the FPGA speak over the **JTAG-UART**. It is the
contract shared by two implementations that must stay in lock-step:

| Side | File | Role |
| ---- | ---- | ---- |
| FPGA (parser/responder) | [`src/control/host_if.sv`](./src/control/host_if.sv) | Decodes requests, drives the controller, serializes responses |
| PC (client) | [`kfx_gui/protocol.py`](./kfx_gui/protocol.py) | Builds requests, parses responses; ships a `Client` + CLI |

If you change a frame format, an opcode, or an error code, change **both** files
and this document together.

---

## 1. Transport stack

There are **no extra top-level pins** for the host link — it rides the same
on-board USB-Blaster cable used to program the board. On the FPGA the bytes pass
through three layers before reaching the command parser:

```
 PC (kfx_gui)                          DE1-SoC FPGA
 ┌───────────────┐   USB-Blaster   ┌──────────────────────────────────────────────┐
 │ protocol.py   │  (JTAG cable)   │  JtagUart IP ──Avalon-MM──► jtag_uart_adapter │
 │  Client       │ ◄──────────────►│   (Qsys)                    (byte stream)      │
 │  JtagTransport│                 │                                   │            │
 └───────────────┘                 │                                   ▼            │
   intel_jtag_uart                 │                                host_if         │
   (wraps jtag_atlantic)           │                          (command parser/FSM)  │
                                   │                                   │            │
                                   │                                   ▼            │
                                   │                       controller all_params    │
                                   └──────────────────────────────────────────────┘
```

- **`JtagUart` (Qsys IP)** — the Altera JTAG UART. Register map (word-addressed,
  32-bit), used by the adapter:
  - `data` (address 0): read → `[7:0]`=RX byte, `[15]`=RVALID, `[31:16]`=RAVAIL;
    write → `[7:0]`=TX byte.
  - `control` (address 1): read → `[31:16]`=WSPACE (free space in the TX FIFO).
- **[`jtag_uart_adapter.sv`](./src/control/jtag_uart_adapter.sv)** — an Avalon-MM
  master that turns that register interface into a simple byte stream
  (`rx_data/rx_valid/rx_ready`, `tx_data/tx_valid/tx_ready`). A single master
  serializes RX and TX; **TX has priority** so responses (including the 512-byte
  DUMP) flush out, and RX is polled whenever the host has nothing queued.
- **[`host_if.sv`](./src/control/host_if.sv)** — the protocol FSM described by
  the rest of this document. It is transport-agnostic: it only sees the byte
  stream, so swapping the JTAG-UART for a plain UART would not touch it.

On the PC, `protocol.py` is likewise transport-agnostic. The default
`JtagTransport` wraps the `intel_jtag_uart` package (which itself wraps
Quartus's `jtag_atlantic`); a `MockTransport` drives the same `Client` against a
behavioral FPGA model for offline tests. Any object implementing
`write` / `read` / `flush_input` can be dropped in (e.g. a future
`SerialTransport`).

> **JTAG is single-owner.** Only one tool may hold the JTAG-UART at a time. Close
> `nios2-terminal`, the Programmer's auto-detect, and any SignalTap session
> before connecting, and close the host tool before re-programming the FPGA.

---

## 2. Data model

Every parameter is addressed by a `(bank, fx, param)` triple and is a single
**unsigned byte (0–255)**. Dimensions mirror `src/lab_pkg.sv` /
`kfx_gui/params.py`:

| Field | Count | Width sent on wire | Notes |
| ----- | ----: | ------------------ | ----- |
| `bank`  | 4  | 1 byte (low 2 bits used) | preset bank 0–3 |
| `fx`    | 16 | 1 byte (low 4 bits used) | effect slot F0–F15 |
| `param` | 8  | 1 byte (low 3 bits used) | parameter P0–P7 |
| `value` | —  | 1 byte | parameter value 0–255 |

The FPGA **bit-masks** `bank`/`fx`/`param` to their field widths, so
out-of-range indices wrap rather than error — send valid indices. The full
parameter space is `4 × 16 × 8 = 512` bytes.

**Linear DUMP index.** When all parameters are serialized (DUMP), the order is
param-fastest, then fx, then bank:

```
index = ((bank * 16) + fx) * 8 + param        # 0 .. 511
```

(`protocol.dump_index(bank, fx, param)` computes this.)

**Special slots.**
- **F7 P0 (Expression Gain)** is **read-only** — it is driven by the hardware
  expression pedal. A `WRITE` to `fx=7, param=0` returns `NACK 0x04`.
- **F15 (Global Gain)** is **global**: the controller mirrors writes to F15
  across all four banks, and one `SAVE` persists the same value to every bank.
  (This mirroring happens in the controller, not in `host_if`.)

---

## 3. Request frame (PC → FPGA)

Every request is a **fixed 7 bytes**, even for commands that take no arguments
(unused args are sent as `0x00`):

```
 ┌──────┬────────┬──────┬──────┬──────┬──────┬──────┐
 │ 0x5A │ OPCODE │ ARG0 │ ARG1 │ ARG2 │ ARG3 │ CHK  │
 └──────┴────────┴──────┴──────┴──────┴──────┴──────┘
   sync                                          checksum

 CHK = OPCODE ^ ARG0 ^ ARG1 ^ ARG2 ^ ARG3
```

- `0x5A` is the **request sync** byte. The FPGA discards bytes until it sees it,
  which lets a fresh frame resynchronize after any garbage or partial frame.
- `CHK` is a simple XOR of the five body bytes (sync excluded). A mismatch yields
  `NACK 0x01`.

### Opcode reference

| Opcode | Name  | ARG0 | ARG1 | ARG2 | ARG3 | Response | Busy-gated? |
| ------ | ----- | ---- | ---- | ---- | ---- | -------- | ----------- |
| `0x01` | WRITE | bank | fx | param | value | ACK / NACK | yes |
| `0x10` | READ  | bank | fx | param | — | READ | no |
| `0x11` | GBNK  | — | — | — | — | BANK | no |
| `0x20` | DUMP  | — | — | — | — | DUMP | no |
| `0x30` | RESET | scope | bank | fx | param | ACK / NACK | yes |
| `0x40` | RDEF  | bank | fx | param | — | READ (factory default) | no |
| `0x50` | SAVE  | — | — | — | — | ACK / NACK | yes |
| `0x51` | LOAD  | — | — | — | — | ACK / NACK | yes |
| `0xF0` | PING  | — | — | — | — | PONG | no |

**RESET scope** (ARG0): `0`=single param, `1`=whole fx, `2`=whole bank,
`3`=everything. The `bank`/`fx`/`param` args select the target for the chosen
scope; unused fields are ignored.

**RDEF** reads the **factory default** for a parameter without changing the live
value; its reply uses the same `READ` frame format (type `0x10`) carrying the
default value.

---

## 4. Response frames (FPGA → PC)

Every response is prefixed with the **response sync** byte `0xA5`. The **second
byte disambiguates** the frame type — note it deliberately reuses the request
opcode values for the data-bearing replies:

| 2nd byte | Frame | Total layout |
| -------- | ----- | ------------ |
| `0x00` | **ACK** | `[0xA5][0x00]` |
| `0x01`–`0x04` | **NACK** | `[0xA5][err]` |
| `0x10` | **READ** | `[0xA5][0x10][bank][fx][param][value][chk]` |
| `0x11` | **BANK** | `[0xA5][0x11][bank][chk]` |
| `0x20` | **DUMP** | `[0xA5][0x20][0x02][0x00] + <512 value bytes> + [chk]` |
| `0xF0` | **PONG** | `[0xA5][0xF0][VER_MAJ][VER_MIN][chk]` |

Checksums on response frames (where present) are an XOR **over the type byte and
payload** (sync excluded), matching the request convention:

- **READ** `chk = 0x10 ^ bank ^ fx ^ param ^ value`
- **BANK** `chk = 0x11 ^ bank`
- **PONG** `chk = 0xF0 ^ VER_MAJ ^ VER_MIN`
- **DUMP** `chk = XOR of the 512 payload bytes only` (the 4-byte header is *not*
  included). The header advertises the length big-endian: `0x02 0x00` = `0x0200`
  = 512.

The host reads bytes until it sees `0xA5`, then reads the type byte and the exact
remaining length for that frame type. ACK and NACK have no checksum.

### Firmware version

`PING` returns the firmware protocol version. The current firmware reports
**`VER_MAJ=1`, `VER_MIN=0`** (`v1.0`).

---

## 5. Error codes (NACK)

A NACK is `[0xA5][err]` where `err` is one of:

| Code | Name | Meaning |
| ---- | ---- | ------- |
| `0x01` | CHECKSUM | request `CHK` did not match — frame corrupt |
| `0x02` | OPCODE | unknown/unsupported opcode |
| `0x03` | BUSY | a flash operation is in progress (see below) |
| `0x04` | READONLY | wrote a read-only parameter (F7 P0, the pedal slot) |

**Busy.** `WRITE`, `RESET`, `SAVE`, and `LOAD` are rejected with `NACK 0x03`
while `fsm_busy` is asserted — i.e. while a `SAVE`/`LOAD` flash cycle is running.
`READ`, `RDEF`, `DUMP`, `GBNK`, and `PING` are **never** busy-gated, so the host
can keep polling state during a save.

**SAVE timing.** A `SAVE` is acknowledged (`ACK`) when it is *accepted*, then the
device erases and rewrites a full flash sector — **up to ~3 seconds**, during
which it reports busy. Poll with a cheap, non-gated command (or simply retry the
next `WRITE`) until it stops returning `NACK 0x03`. See the "Saving and Loading
Presets" section of the main [README](./README.md) for the flash sequence.

---

## 6. Worked examples

All bytes hex; `··· ` denotes the 512-byte DUMP payload.

```
PING            → 5A F0 00 00 00 00 F0
  PONG          ← A5 F0 01 00 F1                 # firmware v1.0

GBNK            → 5A 11 00 00 00 00 11
  BANK (bank 2) ← A5 11 02 13

READ b0 f3 p0   → 5A 10 00 03 00 00 13
  READ (val 67) ← A5 10 00 03 00 43 50           # 0x43 = 67

WRITE b2 f9 p7 = 90   → 5A 01 02 09 07 5A 57      # 0x5A = 90
  ACK                 ← A5 00

WRITE b0 f7 p0 = 10   → 5A 01 00 07 00 0A 0C      # pedal slot
  NACK readonly       ← A5 04

RESET all (scope 3)   → 5A 30 03 00 00 00 33
  ACK                 ← A5 00

DUMP            → 5A 20 00 00 00 00 20
  DUMP          ← A5 20 02 00 ··· <512 bytes> ··· <chk>

SAVE            → 5A 50 00 00 00 00 50
  ACK           ← A5 00                           # then busy ~3 s
```

---

## 7. Host-side usage

The `Client` in [`kfx_gui/protocol.py`](./kfx_gui/protocol.py) wraps all of the
above; the same module is runnable as a CLI:

```
uv run python protocol.py ping
uv run python protocol.py read  <bank> <fx> <param>
uv run python protocol.py rdef  <bank> <fx> <param>      # factory default
uv run python protocol.py write <bank> <fx> <param> <value>
uv run python protocol.py reset <scope> [bank] [fx] [param]
uv run python protocol.py dump
uv run python protocol.py save
uv run python protocol.py load
```

The Tkinter GUI ([`gui.py`](./kfx_gui/gui.py)) drives the same `Client`. See
[`kfx_gui/README.md`](./kfx_gui/README.md) for setup, the CLI, and the GUI.

**Resync strategy.** Before query commands (`PING`, `GBNK`, `DUMP`) the client
flushes stale input and the FPGA parser drops bytes until the next `0x5A`, so a
dropped or partial frame self-corrects on the following command rather than
desyncing the link permanently.

**Adding a non-JTAG transport.** Because both ends are transport-agnostic, a
plain USB-serial link only needs a new `Transport` on the PC side (implement
`write` / `read` / `flush_input` and hand it to `Client`); the FPGA `host_if`
and the frame formats above are unchanged.
