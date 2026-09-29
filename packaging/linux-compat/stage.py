#!/usr/bin/env python3
"""Stage only our private runtime; use Focal packages for system libraries."""
from pathlib import Path
import re
import shutil
import subprocess
from elf import has_dynamic_segment, relocate_private_libraries

ROOT = Path('/compat-root')
LIB = ROOT / 'usr/lib/opal'
LIB.mkdir(parents=True)
for name in ['engines', 'web']:
    shutil.copytree(name, LIB / name, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
(LIB / 'scripts').mkdir()
shutil.copy2('scripts/camoufox_bridge.py', LIB / 'scripts')
for name in ['plugins-manifest.json', 'manga-sources-sfw.json']:
    shutil.copy2(Path('data') / name, LIB / name)
shutil.copy2('assets/logo.svg', LIB / 'web/icon.svg')
for source, dest in [('zig-out/bin/opal', 'opal-bin'),
                     ('zig-out/bin/zig-bypassdpi', 'zig-bypassdpi'),
                     ('libtorrent_wrapper.so', 'libtorrent_wrapper.so'),
                     ('/opt/opal-runtime/bin/ffmpeg', 'ffmpeg'),
                     ('/opt/opal-runtime/bin/ffprobe', 'ffprobe')]:
    shutil.copy2(source, LIB / dest)
for source in Path('/opt/opal-runtime/lib').glob('*.so*'):
    if source.is_file():
        shutil.copy2(source, LIB / source.name)
for binary in LIB.iterdir():
    if not binary.is_file() or binary.read_bytes()[:4] != b'\x7fELF':
        continue
    if has_dynamic_segment(binary):
        relocate_private_libraries(binary, LIB)
    versions = subprocess.check_output(['readelf', '--version-info', str(binary)], text=True)
    required = [tuple(map(int, x.split('.'))) for x in re.findall(r'\bGLIBC_(\d+\.\d+(?:\.\d+)?)', versions)]
    if any(version > (2, 31) for version in required):
        raise SystemExit(f'{binary}: requires glibc newer than 2.31')
# A relocatable launcher also works after user-local .deb extraction. RPATH
# handles private libraries without exporting them to curl/other subprocesses.
(LIB / 'opal').write_text('''#!/bin/sh
OPAL_RUNTIME=$(CDPATH= cd "$(dirname "$0")" && pwd)
PATH="$OPAL_RUNTIME:$PATH"
export PATH
exec "$OPAL_RUNTIME/opal-bin" "$@"
''')
(LIB / 'opal').chmod(0o755)
(ROOT / 'usr/bin').mkdir(parents=True)
(ROOT / 'usr/bin/opal').write_text('#!/bin/sh\nexec /usr/lib/opal/opal "$@"\n')
(ROOT / 'usr/bin/opal').chmod(0o755)
for source, dest in [('packaging/opal.desktop', 'usr/share/applications/opal.desktop'),
                     ('assets/logo.svg', 'usr/share/icons/hicolor/scalable/apps/opal.svg'),
                     ('LICENSE', 'usr/share/doc/opal/LICENSE'),
                     ('packaging/linux-compat/README.md', 'usr/share/doc/opal/COMPATIBILITY.md')]:
    path = ROOT / dest
    path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, path)
