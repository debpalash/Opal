#!/usr/bin/env python3
"""Enforce presentation-import boundaries with an explicit migration backlog."""
import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def presentation_edges(sources):
    edges = set()
    for path, source in sources.items():
        # Scan the whole file: Zig permits production declarations after tests.
        production = '\n'.join(line for line in source.splitlines()
                               if not line.lstrip().startswith('//'))
        for target in re.findall(r'@import\("([^"]+)"\)', production):
            if target in ('dvui', 'icons') or '/ui/' in target:
                edges.add(f'{path} -> {target}')
    return edges


def violations(sources, allowed):
    actual = presentation_edges(sources)
    return ([f'new presentation dependency: {edge}' for edge in sorted(actual - allowed)]
            + [f'remove resolved exception: {edge}' for edge in sorted(allowed - actual)])


def check(root=ROOT):
    sources = {str(p.relative_to(root)): p.read_text(encoding='utf-8')
               for folder in ('core', 'services', 'application')
               for p in (root / 'src' / folder).rglob('*.zig')
               if not p.name.endswith('_test.zig')}
    exceptions = json.loads((root / 'docs/architecture-exceptions.json').read_text())
    return violations(sources, set(exceptions['presentation_imports']))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=ROOT)
    errors = check(parser.parse_args().root)
    print('\n'.join(errors) if errors else 'Architecture import boundaries pass')
    raise SystemExit(bool(errors))
