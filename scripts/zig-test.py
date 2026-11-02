#!/usr/bin/env python3
"""Run a standalone Zig test with Opal's shared compatibility modules."""
import os
from pathlib import Path
import subprocess
import sys


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: zig-test.py SOURCE [zig test options]")
    root = Path(__file__).resolve().parent.parent
    command = [os.environ.get("ZIG", "zig"), "test", *sys.argv[2:]]
    modules = {"opal-repeat": "repeat_pure.zig", "opal-fmt": "fmt_compat.zig", "opal-reflect": "enum_compat.zig"}
    for name in modules:
        command.extend(["--dep", name])
    command.append("-Mroot=" + sys.argv[1])
    command.extend(f"-M{name}={root / 'src' / 'core' / filename}" for name, filename in modules.items())
    return subprocess.call(command)


if __name__ == "__main__":
    raise SystemExit(main())
