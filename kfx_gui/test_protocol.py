"""
test_protocol.py — offline self-test of protocol.py.

Uses a MockTransport whose embedded FpgaEmu mirrors the FPGA's host_if +
controller behavior (write/read/dump/reset/nack, FX15 mirroring, FX7[0]
read-only).  Verifies the Python client builds correct frames and parses
responses.  No hardware required.

Run:  python host_tool/test_protocol.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import protocol as P  # noqa: E402


def _idx(b, f, p):
    return ((b * 16) + f) * 8 + p


class FpgaEmu:
    """Cycle-free behavioral model of host_if + controller's all_params."""

    def __init__(self):
        self.defaults = bytearray((i * 7 + 3) & 0xFF for i in range(512))
        self.params = bytearray(self.defaults)
        self.busy = False

    def process(self, frame: bytes) -> bytes:
        if len(frame) < 7 or frame[0] != P.REQ_SYNC:
            return b""
        op, a0, a1, a2, a3, chk = frame[1], frame[2], frame[3], frame[4], frame[5], frame[6]
        if (op ^ a0 ^ a1 ^ a2 ^ a3) & 0xFF != chk:
            return bytes((P.RSP_SYNC, P.ERR_CHECKSUM))

        if op == P.OP_WRITE:
            b, f, p, v = a0, a1, a2, a3
            if f == 7 and p == 0:
                return bytes((P.RSP_SYNC, P.ERR_READONLY))
            if self.busy:
                return bytes((P.RSP_SYNC, P.ERR_BUSY))
            if f == 15:
                for bk in range(4):
                    self.params[_idx(bk, 15, p)] = v
            else:
                self.params[_idx(b, f, p)] = v
            return bytes((P.RSP_SYNC, P.ST_OK))

        if op in (P.OP_READ, P.OP_RDEF):
            b, f, p = a0, a1, a2
            src = self.defaults if op == P.OP_RDEF else self.params
            v = src[_idx(b, f, p)]
            return bytes((P.RSP_SYNC, P.OP_READ, b, f, p, v, (P.OP_READ ^ b ^ f ^ p ^ v) & 0xFF))

        if op == P.OP_DUMP:
            payload = bytes(self.params)
            chkv = 0
            for x in payload:
                chkv ^= x
            return bytes((P.RSP_SYNC, P.OP_DUMP, 0x02, 0x00)) + payload + bytes((chkv,))

        if op == P.OP_RESET:
            if self.busy:
                return bytes((P.RSP_SYNC, P.ERR_BUSY))
            self._reset(a0, a1, a2, a3)
            return bytes((P.RSP_SYNC, P.ST_OK))

        if op in (P.OP_SAVE, P.OP_LOAD):
            if self.busy:
                return bytes((P.RSP_SYNC, P.ERR_BUSY))
            return bytes((P.RSP_SYNC, P.ST_OK))

        if op == P.OP_PING:
            return bytes((P.RSP_SYNC, P.OP_PING, 0x01, 0x00, (P.OP_PING ^ 0x01 ^ 0x00) & 0xFF))

        return bytes((P.RSP_SYNC, P.ERR_OPCODE))

    def _reset(self, scope, b, f, p):
        def setdef(bk, fx, pp):
            self.params[_idx(bk, fx, pp)] = self.defaults[_idx(bk, fx, pp)]

        if scope == P.SCOPE_PARAM:
            banks = range(4) if f == 15 else [b]
            for bk in banks:
                setdef(bk, f, p)
        elif scope == P.SCOPE_FX:
            for pp in range(8):
                banks = range(4) if f == 15 else [b]
                for bk in banks:
                    setdef(bk, f, pp)
        elif scope == P.SCOPE_BANK:
            for fx in range(16):
                for pp in range(8):
                    setdef(b, fx, pp)
        else:  # SCOPE_ALL
            for bk in range(4):
                for fx in range(16):
                    for pp in range(8):
                        setdef(bk, fx, pp)


class MockTransport:
    def __init__(self, fpga: FpgaEmu):
        self.fpga = fpga
        self._wbuf = bytearray()
        self._rx = bytearray()

    def write(self, data: bytes) -> None:
        self._wbuf.extend(data)
        while len(self._wbuf) >= 7:
            frame = bytes(self._wbuf[:7])
            del self._wbuf[:7]
            self._rx.extend(self.fpga.process(frame))

    def read(self, n: int, timeout: float = 1.0) -> bytes:
        if len(self._rx) < n:
            raise P.TimeoutError_(f"mock: wanted {n}, have {len(self._rx)}")
        out = bytes(self._rx[:n])
        del self._rx[:n]
        return out

    def flush_input(self) -> None:
        self._rx.clear()


# ---- tests ----
_fails = 0


def check(name, got, exp):
    global _fails
    if got != exp:
        print(f"  FAIL {name}: got {got!r} exp {exp!r}")
        _fails += 1


def expect_nack(name, fn, code):
    global _fails
    try:
        fn()
        print(f"  FAIL {name}: expected NackError 0x{code:02x}, none raised")
        _fails += 1
    except P.NackError as e:
        if e.code != code:
            print(f"  FAIL {name}: got NACK 0x{e.code:02x} exp 0x{code:02x}")
            _fails += 1


def main():
    emu = FpgaEmu()
    c = P.Client(MockTransport(emu))

    print("[1] build_frame checksum")
    fr = P.build_frame(P.OP_WRITE, 2, 4, 0, 0x77)
    check("frame.len", len(fr), 7)
    check("frame.sync", fr[0], 0x5A)
    check("frame.chk", fr[6], (0x01 ^ 2 ^ 4 ^ 0 ^ 0x77) & 0xFF)

    print("[2] ping")
    check("ping", c.ping(), (1, 0))

    print("[3] write + read")
    c.write_param(2, 4, 0, 0x77)
    check("read", c.read_param(2, 4, 0), 0x77)
    check("emu", emu.params[_idx(2, 4, 0)], 0x77)

    print("[4] FX15 mirror")
    c.write_param(0, 15, 0, 0x2A)
    for bk in range(4):
        check(f"fx15.b{bk}", c.read_param(bk, 15, 0), 0x2A)

    print("[5] FX7[0] read-only -> NACK")
    before = emu.params[_idx(0, 7, 0)]
    expect_nack("ro", lambda: c.write_param(0, 7, 0, 0x99), P.ERR_READONLY)
    check("ro.unchanged", emu.params[_idx(0, 7, 0)], before)

    print("[6] read default (no write)")
    check("rdef", c.read_default(2, 4, 0), emu.defaults[_idx(2, 4, 0)])
    check("rdef.nowrite", emu.params[_idx(2, 4, 0)], 0x77)

    print("[7] reset bank scope")
    c.reset(P.SCOPE_BANK, bank=2)
    check("rst.b2f4p0", c.read_param(2, 4, 0), emu.defaults[_idx(2, 4, 0)])
    check("rst.b2f9p7", c.read_param(2, 9, 7), emu.defaults[_idx(2, 9, 7)])
    check("rst.other", c.read_param(0, 15, 0), 0x2A)  # bank0 fx15 untouched

    print("[8] dump")
    data = c.dump()
    check("dump.len", len(data), 512)
    check("dump.match", data, bytes(emu.params))

    print("[9] save / load ACK")
    c.save_flash()
    c.load_flash()

    print("[10] bad checksum -> NACK")
    t = c.t
    t.flush_input()
    t.write(bytes((0x5A, P.OP_WRITE, 0, 0, 0, 0, 0xFF)))  # wrong checksum
    expect_nack("badchk", c._recv, P.ERR_CHECKSUM)

    print("[11] busy -> NACK 0x03")
    emu.busy = True
    expect_nack("busy", lambda: c.write_param(1, 4, 0, 5), P.ERR_BUSY)
    emu.busy = False

    if _fails == 0:
        print("\n=== ALL PROTOCOL TESTS PASSED ===")
        return 0
    print(f"\n=== {_fails} FAILURE(S) ===")
    return 1


if __name__ == "__main__":
    sys.exit(main())
