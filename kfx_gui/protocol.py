"""
protocol.py — KFX Engine host <-> FPGA command protocol.

Transport-agnostic implementation of the byte protocol parsed by the FPGA's
`host_if` module.  The default transport is the JTAG-UART (over the on-board
USB-Blaster) via the `intel_jtag_uart` package; a `MockTransport` is provided
for offline self-tests.

Request frame (PC -> FPGA), fixed 7 bytes:
    [0x5A][OPCODE][ARG0][ARG1][ARG2][ARG3][CHK]
    CHK = OPCODE ^ ARG0 ^ ARG1 ^ ARG2 ^ ARG3

Response frames (FPGA -> PC), all prefixed 0xA5:
    ACK  : [0xA5][0x00]
    NACK : [0xA5][err]                 err 01=checksum 02=opcode 03=busy 04=read-only
    READ : [0xA5][0x10][bank][fx][param][value][chk]
    DUMP : [0xA5][0x20][0x02][0x00] + 512 value bytes + [chk]
    PONG : [0xA5][0xF0][VER_MAJ][VER_MIN][chk]
"""

from __future__ import annotations

import time
from typing import Optional, Protocol as _TypingProtocol

# ---- dimensions (mirror lab_pkg.sv) ----
BANK_COUNT = 4
FX_COUNT = 16
PARAM_COUNT = 8
DUMP_LEN = BANK_COUNT * FX_COUNT * PARAM_COUNT  # 512

# ---- protocol bytes ----
REQ_SYNC = 0x5A
RSP_SYNC = 0xA5

OP_WRITE = 0x01
OP_READ = 0x10
OP_DUMP = 0x20
OP_RESET = 0x30
OP_RDEF = 0x40
OP_SAVE = 0x50
OP_LOAD = 0x51
OP_PING = 0xF0

ST_OK = 0x00
ERR_CHECKSUM = 0x01
ERR_OPCODE = 0x02
ERR_BUSY = 0x03
ERR_READONLY = 0x04

# reset scopes
SCOPE_PARAM = 0
SCOPE_FX = 1
SCOPE_BANK = 2
SCOPE_ALL = 3

_NACK_TEXT = {
    ERR_CHECKSUM: "bad checksum",
    ERR_OPCODE: "unknown opcode",
    ERR_BUSY: "device busy (flash operation in progress)",
    ERR_READONLY: "parameter is read-only (FX7[0] is pot-driven)",
}


class ProtocolError(Exception):
    """Malformed or unexpected response."""


class TimeoutError_(ProtocolError):
    """Timed out waiting for response bytes."""


class NackError(ProtocolError):
    """FPGA returned a NACK."""

    def __init__(self, code: int):
        self.code = code
        super().__init__(f"NACK 0x{code:02x}: {_NACK_TEXT.get(code, 'unknown error')}")


def build_frame(op: int, a0: int = 0, a1: int = 0, a2: int = 0, a3: int = 0) -> bytes:
    """Build a 7-byte request frame with XOR checksum."""
    body = bytes((op & 0xFF, a0 & 0xFF, a1 & 0xFF, a2 & 0xFF, a3 & 0xFF))
    chk = 0
    for b in body:
        chk ^= b
    return bytes((REQ_SYNC,)) + body + bytes((chk,))


# ---------------------------------------------------------------------------
# Transports
# ---------------------------------------------------------------------------
class Transport(_TypingProtocol):
    def write(self, data: bytes) -> None: ...
    def read(self, n: int, timeout: float) -> bytes: ...
    def flush_input(self) -> None: ...


class JtagTransport:
    """Transport over the Intel JTAG-UART (on-board USB-Blaster).

    Requires the `intel_jtag_uart` package and Quartus installed (it wraps
    `jtag_atlantic`); the JTAG/jtag server must be reachable and no other tool
    (e.g. nios2-terminal, a Programmer auto-detect) may hold the JTAG UART.
    """

    def __init__(self, **kwargs):
        import intel_jtag_uart  # imported lazily so the GUI/mock work without it
        self.ju = intel_jtag_uart.intel_jtag_uart(**kwargs)
        self._buf = bytearray()

    def write(self, data: bytes) -> None:
        self.ju.write(bytes(data))

    def _pump(self) -> None:
        chunk = self.ju.read()
        if chunk:
            self._buf.extend(chunk)

    def read(self, n: int, timeout: float = 2.0) -> bytes:
        deadline = time.monotonic() + timeout
        while len(self._buf) < n:
            self._pump()
            if len(self._buf) >= n:
                break
            if time.monotonic() > deadline:
                raise TimeoutError_(
                    f"timed out waiting for {n} bytes (got {len(self._buf)})"
                )
            time.sleep(0.002)
        out = bytes(self._buf[:n])
        del self._buf[:n]
        return out

    def flush_input(self) -> None:
        # drain anything stale so a fresh command resyncs cleanly
        for _ in range(8):
            self._pump()
        self._buf.clear()


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------
class Client:
    """High-level command interface to the KFX Engine over a Transport."""

    def __init__(self, transport: Transport, timeout: float = 2.0):
        self.t = transport
        self.timeout = timeout

    # --- low-level send / receive ---
    def _send(self, op: int, a0=0, a1=0, a2=0, a3=0) -> None:
        self.t.write(build_frame(op, a0, a1, a2, a3))

    def _sync(self) -> None:
        """Read bytes until the 0xA5 response sync is found."""
        deadline = time.monotonic() + self.timeout
        while True:
            b = self.t.read(1, self.timeout)
            if b and b[0] == RSP_SYNC:
                return
            if time.monotonic() > deadline:
                raise TimeoutError_("no response sync (0xA5) seen")

    @staticmethod
    def _xor(data: bytes) -> int:
        c = 0
        for b in data:
            c ^= b
        return c

    def _recv(self):
        """Read and parse one response frame after its 0xA5 sync.

        Returns a tuple: ('ack',) | ('read', bank, fx, param, val)
                        | ('dump', bytes) | ('pong', vmaj, vmin)
        Raises NackError on a NACK type byte.
        """
        self._sync()
        t = self.t.read(1, self.timeout)[0]
        if t == ST_OK:
            return ("ack",)
        if t in _NACK_TEXT:
            raise NackError(t)
        if t == OP_READ:
            rest = self.t.read(5, self.timeout)  # bank, fx, param, val, chk
            if self._xor(bytes((OP_READ,)) + rest[:4]) != rest[4]:
                raise ProtocolError("READ checksum mismatch")
            return ("read", rest[0], rest[1], rest[2], rest[3])
        if t == OP_DUMP:
            hdr = self.t.read(2, self.timeout)  # len hi, lo
            length = (hdr[0] << 8) | hdr[1]
            payload = self.t.read(length, max(self.timeout, length * 0.01 + 1.0))
            chk = self.t.read(1, self.timeout)[0]
            if self._xor(payload) != chk:
                raise ProtocolError("DUMP checksum mismatch")
            return ("dump", payload)
        if t == OP_PING:
            rest = self.t.read(3, self.timeout)  # vmaj, vmin, chk
            if self._xor(bytes((OP_PING,)) + rest[:2]) != rest[2]:
                raise ProtocolError("PONG checksum mismatch")
            return ("pong", rest[0], rest[1])
        raise ProtocolError(f"unexpected response type 0x{t:02x}")

    # --- commands ---
    def ping(self) -> tuple[int, int]:
        """Return (version_major, version_minor); raises on no response."""
        self.t.flush_input()
        self._send(OP_PING)
        r = self._recv()
        if r[0] != "pong":
            raise ProtocolError(f"expected PONG, got {r[0]}")
        return (r[1], r[2])

    def read_param(self, bank: int, fx: int, param: int) -> int:
        self._send(OP_READ, bank, fx, param)
        r = self._recv()
        if r[0] != "read":
            raise ProtocolError(f"expected READ, got {r[0]}")
        return r[4]

    def read_default(self, bank: int, fx: int, param: int) -> int:
        self._send(OP_RDEF, bank, fx, param)
        r = self._recv()
        if r[0] != "read":
            raise ProtocolError(f"expected READ, got {r[0]}")
        return r[4]

    def write_param(self, bank: int, fx: int, param: int, value: int) -> None:
        self._send(OP_WRITE, bank, fx, param, value)
        self._recv()  # ACK or raises NackError

    def reset(self, scope: int, bank: int = 0, fx: int = 0, param: int = 0) -> None:
        self._send(OP_RESET, scope, bank, fx, param)
        self._recv()

    def dump(self) -> bytes:
        """Return all 512 parameter bytes (index = ((bank*16)+fx)*8 + param)."""
        self.t.flush_input()
        self._send(OP_DUMP)
        r = self._recv()
        if r[0] != "dump":
            raise ProtocolError(f"expected DUMP, got {r[0]}")
        if len(r[1]) != DUMP_LEN:
            raise ProtocolError(f"DUMP length {len(r[1])} != {DUMP_LEN}")
        return r[1]

    def save_flash(self) -> None:
        self._send(OP_SAVE)
        self._recv()

    def load_flash(self) -> None:
        self._send(OP_LOAD)
        self._recv()


def dump_index(bank: int, fx: int, param: int) -> int:
    return ((bank * FX_COUNT) + fx) * PARAM_COUNT + param


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _main(argv=None):
    import argparse

    ap = argparse.ArgumentParser(description="KFX Engine host CLI (JTAG-UART)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ping")
    sub.add_parser("dump")
    p = sub.add_parser("read"); p.add_argument("bank", type=int); p.add_argument("fx", type=int); p.add_argument("param", type=int)
    p = sub.add_parser("rdef"); p.add_argument("bank", type=int); p.add_argument("fx", type=int); p.add_argument("param", type=int)
    p = sub.add_parser("write"); p.add_argument("bank", type=int); p.add_argument("fx", type=int); p.add_argument("param", type=int); p.add_argument("value", type=int)
    p = sub.add_parser("reset"); p.add_argument("scope", type=int, help="0=param 1=fx 2=bank 3=all"); p.add_argument("bank", type=int, nargs="?", default=0); p.add_argument("fx", type=int, nargs="?", default=0); p.add_argument("param", type=int, nargs="?", default=0)
    sub.add_parser("save")
    sub.add_parser("load")
    args = ap.parse_args(argv)

    client = Client(JtagTransport())

    if args.cmd == "ping":
        vmaj, vmin = client.ping()
        print(f"PONG  firmware v{vmaj}.{vmin}")
    elif args.cmd == "dump":
        data = client.dump()
        for bank in range(BANK_COUNT):
            print(f"-- bank {bank} --")
            for fx in range(FX_COUNT):
                row = data[dump_index(bank, fx, 0):dump_index(bank, fx, 0) + PARAM_COUNT]
                print(f"  fx{fx:2d}: " + " ".join(f"{v:3d}" for v in row))
    elif args.cmd == "read":
        print(client.read_param(args.bank, args.fx, args.param))
    elif args.cmd == "rdef":
        print(client.read_default(args.bank, args.fx, args.param))
    elif args.cmd == "write":
        client.write_param(args.bank, args.fx, args.param, args.value)
        print("OK")
    elif args.cmd == "reset":
        client.reset(args.scope, args.bank, args.fx, args.param)
        print("OK")
    elif args.cmd == "save":
        client.save_flash(); print("OK (save started)")
    elif args.cmd == "load":
        client.load_flash(); print("OK")


if __name__ == "__main__":
    _main()
