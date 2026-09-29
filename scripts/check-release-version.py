#!/usr/bin/env python3
"""Refuse artifacts whose release tag disagrees with their application version."""
from pathlib import Path
import re
import sys


def check(tag, version):
    return bool(re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(?:[+-][0-9A-Za-z.-]+)?', tag)) and tag == 'v' + version


if __name__ == '__main__':
    version = re.search(r'\.version\s*=\s*"([^"]+)"', Path('build.zig.zon').read_text()).group(1)
    if len(sys.argv) != 2 or not check(sys.argv[1], version):
        raise SystemExit(f'Release tag must match app version v{version}')
