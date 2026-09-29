"""Executable coverage for the added source adapters."""
import subprocess
import sys
from .harness import PROJECT_DIR, test


@test("New torrent adapters resolve actual links and reject unrelated rows", "Sources")
def test_expanded_torrent_sources():
    result = subprocess.run([sys.executable, 'tests/test_expanded_torrent_sources.py'],
                            cwd=PROJECT_DIR, capture_output=True, text=True, timeout=30)
    if result.returncode:
        return 'fail', (result.stderr or result.stdout)[-1200:]
    return 'pass', 'NekoBT, Shana Project and Public Domain Torrents request/parse paths'
