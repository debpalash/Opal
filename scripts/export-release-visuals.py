#!/usr/bin/env python3
"""Export native fixture captures for a release. Needs ImageMagick and FFmpeg."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('tag')
parser.add_argument('captures', type=Path)
args = parser.parse_args()
if not re.fullmatch(r'v\d+\.\d+\.\d+', args.tag):
    parser.error('expected vX.Y.Z')
assets = ROOT / 'assets/releases' / args.tag
assets.mkdir(parents=True, exist_ok=True)
for name in ('browser', 'update-ready'):
    subprocess.run(['magick', str(args.captures / f'{name}-1280x800.png'), '-resize', '1280x800', '-strip', str(assets / f'{name}.png')], check=True)
with tempfile.TemporaryDirectory(prefix='opal-release-frames-') as raw:
    directory = Path(raw)
    for index, name in enumerate(('update-available', 'update-downloading', 'update-ready')):
        subprocess.run(['magick', str(args.captures / f'{name}-1280x800.png'), '-resize', '960x600', '-strip', str(directory / f'{index}.png')], check=True)
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-framerate', '1/2', '-i', str(directory / '%d.png'), '-filter_complex', '[0:v]split[a][b];[a]palettegen[p];[b][p]paletteuse', '-loop', '0', str(assets / 'update-flow.gif')], check=True)
manifest = ROOT / 'docs/releases' / args.tag / 'media.json'
manifest.parent.mkdir(parents=True, exist_ok=True)
manifest.write_text(json.dumps({'tag': args.tag, 'items': [
    {'path': f'assets/releases/{args.tag}/browser.png', 'alt': 'Opal’s native macOS browser with compact navigation, tabs and a themed new-tab page.', 'caption': 'Browse inside Opal on macOS. Tabs, extensions, recent pages and connection controls sit beside the player and reading library. Native UI capture with public demo recents.'},
    {'path': f'assets/releases/{args.tag}/update-flow.gif', 'alt': 'The corner update card offers Update, shows download progress, then offers Restart.', 'caption': 'Download in the background, then restart to install and reopen. Native UI preview with an illustrative next-version number; no live download is shown. Seamless restart installation is available for writable macOS app bundles.'}
]}, ensure_ascii=False, indent=2) + '\n')
print(manifest.relative_to(ROOT))
