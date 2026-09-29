#!/usr/bin/env python3
"""Locate the pinned SDK installed by setup-zig for a Docker named context."""
from pathlib import Path
import shutil
import subprocess


def sdk_root(executable):
    zig = Path(executable).resolve()
    if subprocess.check_output([str(zig), 'version'], text=True).strip() != '0.16.0':
        raise ValueError('compatibility build requires Zig 0.16.0')
    root = zig.parent
    if not (root / 'lib/std/std.zig').is_file():
        raise ValueError('Zig SDK standard library missing')
    return root


if __name__ == '__main__':
    zig = shutil.which('zig')
    if not zig:
        raise SystemExit('Zig is not installed')
    print(sdk_root(zig))
