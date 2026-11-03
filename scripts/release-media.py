#!/usr/bin/env python3
"""Validate release visuals or emit their tag-pinned Markdown. Standard library only."""
import argparse
import json
from pathlib import Path
import re
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]

def load(tag, root=ROOT):
    if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise ValueError('expected a stable release tag, vX.Y.Z')
    manifest = root / 'docs' / 'releases' / tag / 'media.json'
    data = json.loads(manifest.read_text())
    if data.get('tag') != tag or not data.get('items'):
        raise ValueError('release visuals must match the tag and include at least one highlight')
    for item in data['items']:
        path = item.get('path', '')
        asset = (root / path).resolve()
        if not asset.is_relative_to(root.resolve()) or not path.startswith(f'assets/releases/{tag}/'):
            raise ValueError('visual must live in this release’s assets directory')
        if not item.get('alt', '').strip() or not item.get('caption', '').strip():
            raise ValueError('each visual needs descriptive alt text and a caption')
        raw = asset.read_bytes()
        if len(raw) > 8 * 1024 * 1024:
            raise ValueError('keep each visual below 8 MiB')
        if asset.suffix == '.png' and raw[:8] == b'\x89PNG\r\n\x1a\n' and len(raw) >= 24:
            width, height = struct.unpack('>II', raw[16:24])
        elif asset.suffix == '.gif' and raw[:6] in (b'GIF87a', b'GIF89a') and len(raw) >= 10:
            width, height = struct.unpack('<HH', raw[6:10])
        else:
            raise ValueError('use a valid PNG or GIF export')
        if width < 600 or height < 300:
            raise ValueError('visual is too small to show a feature clearly')
    return data

def markdown(data, repo='debpalash/Opal'):
    rows = ['### A look at this release', '']
    for item in data['items']:
        rows += [f"![{item['alt']}](https://raw.githubusercontent.com/{repo}/{data['tag']}/{item['path']})", '', item['caption'], '']
    return '\n'.join(rows)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tag')
    parser.add_argument('--markdown', action='store_true')
    parser.add_argument('--optional', action='store_true', help='older tags may have no manifest')
    parser.add_argument('--repo', default='debpalash/Opal')
    args = parser.parse_args()
    try:
        if args.optional and not (ROOT / 'docs/releases' / args.tag / 'media.json').exists():
            sys.exit(0)
        data = load(args.tag)
        print(markdown(data, args.repo) if args.markdown else f"{args.tag}: {len(data['items'])} release visual(s) verified")
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, f'Release visual check failed: {error}\n')
