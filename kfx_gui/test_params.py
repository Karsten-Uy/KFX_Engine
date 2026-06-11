"""
test_params.py — offline self-test of the params.py display conversions.

Verifies the raw-byte <-> human-unit helpers (fmt_value / edit_str /
parse_value) for the gain (dB), EQ-band (dB about 128), and mix (%) params,
plus round-trips and that untouched params stay raw.  No hardware required.

Run:  python kfx_gui/test_params.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import params as P  # noqa: E402

_fails = 0


def check(name, got, exp):
    global _fails
    if got != exp:
        print(f"  FAIL {name}: got {got!r} exp {exp!r}")
        _fails += 1


def main():
    print("[1] gain dB formatting (ref 32: in/out/master/expr)")
    check("in.unity", P.fmt_value(0, 0, 32), "0.0 dB")
    check("in.+6", P.fmt_value(0, 0, 64), "+6.0 dB")
    check("in.max", P.fmt_value(0, 0, 255), "+18.0 dB")
    check("in.-6", P.fmt_value(0, 0, 16), "-6.0 dB")
    check("in.mute", P.fmt_value(0, 0, 0), "-inf")
    check("master.default", P.fmt_value(15, 0, 14), "-7.2 dB")

    print("[2] gain dB formatting (ref 64 comp, ref 128 dist)")
    check("comp.in.unity", P.fmt_value(3, 4, 64), "0.0 dB")
    check("comp.makeup.+6", P.fmt_value(3, 5, 128), "+6.0 dB")
    check("dist.makeup.unity", P.fmt_value(4, 1, 128), "0.0 dB")
    check("dist.makeup.max", P.fmt_value(4, 1, 255), "+6.0 dB")

    print("[3] EQ band dB about flat detent 128")
    check("eq1.flat", P.fmt_value(2, 0, 128), "0.0 dB")
    check("eq1.-6", P.fmt_value(2, 0, 64), "-6.0 dB")
    check("eq2.high.flat", P.fmt_value(5, 3, 128), "0.0 dB")
    check("eq1.mute", P.fmt_value(2, 1, 0), "-inf")

    print("[3b] compact EQ dB (graphic-EQ band readout: no ' dB', no '+')")
    check("eq.compact.flat", P.fmt_value(2, 0, 128, compact=True), "0.0")
    check("eq.compact.+6", P.fmt_value(2, 0, 255, compact=True), "6.0")
    check("eq.compact.-6", P.fmt_value(2, 0, 64, compact=True), "-6.0")
    check("eq.compact.mute", P.fmt_value(2, 0, 0, compact=True), "-inf")
    check("eq.compact.width", P.display_width(2, 0, compact=True), 5)

    print("[4] mix percent (0..100 across full byte range)")
    check("mix.0", P.fmt_value(3, 7, 0), "0%")
    check("mix.50", P.fmt_value(6, 7, 128), "50%")
    check("mix.100", P.fmt_value(9, 7, 255), "100%")

    print("[5] untouched params stay raw")
    check("gate.thresh", P.fmt_value(1, 0, 200), "200")
    check("delay.time", P.fmt_value(8, 0, 90), "90")

    print("[6] parse_value dB -> byte")
    check("p.in.+6", P.parse_value(0, 0, "6"), 64)
    check("p.in.unity", P.parse_value(0, 0, "0"), 32)
    check("p.eq.-6", P.parse_value(2, 0, "-6"), 64)
    check("p.dist.unity", P.parse_value(4, 1, "0"), 128)
    check("p.with_suffix", P.parse_value(0, 0, "+6.0 dB"), 64)
    check("p.inf", P.parse_value(0, 0, "-inf"), 0)

    print("[7] parse_value mix/raw + clamping + invalid")
    check("p.mix.50", P.parse_value(3, 7, "50"), 128)
    check("p.mix.100", P.parse_value(9, 7, "100%"), 255)
    check("p.raw", P.parse_value(1, 0, "200"), 200)
    check("p.clamp.hi", P.parse_value(0, 0, "99"), 255)   # +99 dB clamps to max
    check("p.invalid", P.parse_value(0, 0, "abc"), None)
    check("p.empty", P.parse_value(0, 0, ""), None)

    print("[8] edit_str -> parse_value is display-stable (what you see round-trips)")
    # dB readouts have 0.1 dB resolution, coarser than single-byte steps near
    # unity, so the exact byte may shift by 1 on a round-trip; the *displayed*
    # value must not. Raw/mute cases still round-trip exactly.
    for fx, p in list(P.DB_REF.keys()) + list(P.MIX) + [(1, 0), (8, 0)]:
        for byte in (0, 1, 32, 64, 128, 200, 255):
            rt = P.parse_value(fx, p, P.edit_str(fx, p, byte))
            check(f"rt.fx{fx}.p{p}.b{byte}",
                  P.fmt_value(fx, p, rt), P.fmt_value(fx, p, byte))

    if _fails == 0:
        print("\n=== ALL PARAMS TESTS PASSED ===")
        return 0
    print(f"\n=== {_fails} FAILURE(S) ===")
    return 1


if __name__ == "__main__":
    sys.exit(main())
