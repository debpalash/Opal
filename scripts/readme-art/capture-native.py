#!/usr/bin/env python3
"""Capture README previews from Opal's native widgets with licensed film frames."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    with tempfile.TemporaryDirectory(prefix='opal-readme-native-') as directory:
        env = os.environ.copy()
        env.update(OPAL_README_CAPTURE='1', OPAL_NATIVE_CAPTURE_DIR=directory)
        subprocess.run(
            ['zig', 'build', 'test-native-media', '-Doptimize=ReleaseFast'],
            cwd=ROOT, env=env, check=True,
        )
        for name in ('sintel-player', 'bunny-player', 'connections'):
            subprocess.run(
                ['magick', str(Path(directory) / f'{name}-1400x900.png'),
                 '-resize', '1400x900', '-strip', '-quality', '88',
                 str(ROOT / 'assets/readme' / f'{name}.webp')], check=True,
            )
    print('Updated three native README previews. See assets/readme/CREDITS.md.')


if __name__ == '__main__':
    main()
