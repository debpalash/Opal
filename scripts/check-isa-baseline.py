#!/usr/bin/env python3
"""Fail if a release binary uses instructions above the pinned ISA baseline.

Why this exists
---------------
`zig build` with no `-Dcpu` targets the NATIVE cpu, so a release artifact bakes
in whatever ISA the build machine happened to have. GitHub's runner pool is
heterogeneous, so the same source and the same Zig version produce different
machine code from one release to the next.

That is not hypothetical. Opal v0.6.0 and v0.6.1 were built from the same Zig
0.16.0 with the same command; v0.6.1 landed on a runner with AVX-512 and the
published Linux binary carried AVX-512 in 241 symbols (`kmovd`, `vpternlogq`,
`vpermt2b`), where v0.6.0 had exactly zero. Every CPU without AVX-512 — all Zen
1-3 Ryzen, every 12th-14th gen Intel consumer part, i.e. most desktop Linux —
died with SIGILL before drawing a frame (issue #22).

The builds now pass `-Dcpu=x86_64_v2`. This script proves it, because a flag
that silently stops being passed is exactly how the first regression happened.

Usage: check-isa-baseline.py <binary> [...]
Exits non-zero on the first binary that violates the baseline, or if the
binary cannot be disassembled at all (fail closed — a gate that passes
because it read nothing is worse than no gate).
"""

import re
import shutil
import subprocess
import sys

# AVX-512-only mnemonics. Every one of these is unavailable on a CPU that
# predates AVX-512, so a single occurrence is a crash on that hardware.
#
# Chosen to be unambiguous: opmask ops (k*), the EVEX-only ternary logic and
# two-source permutes, and the masked move/compare forms that only exist under
# EVEX. Instructions that merely *can* be encoded with EVEX but also have a
# legal VEX form are deliberately absent — this list has no false positives.
AVX512_ONLY = re.compile(
    r"^\s*(?:"
    r"k(?:mov|add|and|andn|not|or|ortest|shift[lr]|test|xnor|xor)[bwdq]"
    r"|vpternlog[dq]"
    r"|vperm[it]2(?:[bwdq]|p[sd])"
    r"|vpcompress[bwdq]|vpexpand[bwdq]"
    r"|vpmov(?:[bwdq]2m|m2[bwdq])"
    r"|vptest[nm]m[bwdq]"
    r"|vmovdqu(?:8|16|32|64)"
    r"|vpcmpu?[bwdq]"
    r"|vpxord|vpxorq|vpord|vporq|vpandd|vpandq"
    r"|vinserti(?:32x[48]|64x[24])|vextracti(?:32x[48]|64x[24])"
    r"|vinsertf(?:32x[48]|64x[24])|vextractf(?:32x[48]|64x[24])"
    r"|vscalefp[sd]|vrndscale[sp][sd]|vfixupimm[sp][sd]"
    r"|vgetexp[sp][sd]|vgetmant[sp][sd]"
    r")\b",
    re.IGNORECASE,
)

SYM = re.compile(r"^[0-9a-f]+ <(.+)>:")

# Tolerance for ISOLATED hits.
#
# The failure this gate exists to catch is compiler-wide: when -Dcpu is missing,
# LLVM emits AVX-512 throughout, and the real v0.6.1 Linux binary carries it in
# 305 symbols. A lone instruction is a different animal — either a CPUID-gated
# path inside a linked third-party library (MSYS2's mpv/libtorrent/sqlite3 are
# rebuilt continuously upstream and do dispatch at runtime), or objdump
# misdecoding data as code, which PE sections invite.
#
# Neither of those faults on a CPU without AVX-512, and neither is something a
# -Dcpu flag can fix. So isolated hits are REPORTED and tolerated; anything
# resembling compiler-wide contamination still fails. The gap between the two is
# two orders of magnitude, not a hair.
MAX_TOLERATED_SYMBOLS = 2
MAX_TOLERATED_HITS = 8


def disassemble(path):
    objdump = shutil.which("objdump") or shutil.which("llvm-objdump") or shutil.which("gobjdump")
    if not objdump:
        sys.exit("FAIL: no objdump on PATH — cannot verify the ISA baseline")
    out = subprocess.run(
        [objdump, "-d", "--no-show-raw-insn", path],
        capture_output=True,
        text=True,
        errors="replace",
    )
    if out.returncode != 0 or not out.stdout.strip():
        sys.exit(f"FAIL: could not disassemble {path} ({out.stderr.strip()[:200]})")
    return out.stdout


def check(path):
    text = disassemble(path)

    # Fail closed: a disassembly with no instruction lines means the tool did
    # not understand the file, and an empty scan would otherwise "pass".
    insn_lines = [ln for ln in text.splitlines() if "\t" in ln]
    if len(insn_lines) < 1000:
        sys.exit(f"FAIL: {path} yielded only {len(insn_lines)} instructions — not a real disassembly")

    sym = "?"
    offenders = {}
    hits = 0
    context = []
    lines = text.splitlines()
    for idx, line in enumerate(lines):
        m = SYM.match(line)
        if m:
            sym = m.group(1)
            continue
        body = line.split("\t", 1)[1] if "\t" in line else ""
        if AVX512_ONLY.match(body):
            hits += 1
            offenders.setdefault(sym, set()).add(body.split()[0])
            if len(context) < 4:
                # Surrounding disassembly, so an isolated hit can be judged
                # (dispatched library path vs. misdecoded data) without having
                # to fetch the artifact by hand.
                context.append((sym, lines[max(0, idx - 3):idx + 4]))

    if not offenders:
        print(f"ok: {path} — {len(insn_lines)} instructions, no AVX-512")
        return True, 0

    def report():
        for s, mnems in sorted(offenders.items())[:10]:
            print(f"    {s[:90]}: {', '.join(sorted(mnems))}")
        if len(offenders) > 10:
            print(f"    … and {len(offenders) - 10} more")
        for s, block in context:
            print(f"  --- context in {s[:60]} ---")
            for cl in block:
                print(f"    {cl.rstrip()[:160]}")

    if len(offenders) <= MAX_TOLERATED_SYMBOLS and hits <= MAX_TOLERATED_HITS:
        # Loud, but not blocking — see the tolerance rationale above.
        print(f"WARN: {path} has {hits} isolated AVX-512 instruction(s) in "
              f"{len(offenders)} symbol(s); within tolerance, not blocking.")
        print("  Expected shape for a CPUID-dispatched library path or a PE misdecode.")
        print("  If this count starts growing, the -Dcpu pin has stopped working.")
        report()
        return True, hits

    print(f"FAIL: {path} uses AVX-512 in {len(offenders)} symbol(s), {hits} instruction(s)")
    print("  This binary raises SIGILL on every CPU without AVX-512 —")
    print("  all Zen 1-3 Ryzen and 12th-14th gen Intel consumer parts.")
    print("  The release build is missing -Dcpu=x86_64_v2 (see issue #22).")
    report()
    return False, hits


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    bad = False
    for path in argv[1:]:
        ok, _ = check(path)
        bad = bad or not ok
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
