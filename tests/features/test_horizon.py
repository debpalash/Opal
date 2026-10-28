"""Executable Horizon browser behavior regressions."""
import subprocess
from .harness import *

@test('Horizon: Recall, streaming lifecycle and profile PIN browser behavior', 'Horizon')
def test_horizon_browser():
    import shutil
    if not shutil.which('node'):
        return 'skip', 'node unavailable'
    result = subprocess.run(['node', '--test', 'tests/test_horizon_web.mjs'], cwd=PROJECT_DIR, capture_output=True, text=True, timeout=30)
    return ('pass', '6 browser behavior regressions') if result.returncode == 0 else ('fail', result.stdout[-2500:] + result.stderr[-1000:])


def _pure_modules(modules):
    for module in modules:
        result = subprocess.run(['zig', 'test', 'src/services/' + module + '.zig'], cwd=PROJECT_DIR, capture_output=True, text=True, timeout=90)
        if result.returncode:
            return 'fail', module + ': ' + result.stderr[-2000:]
    return 'pass', 'Executed production pure modules: ' + ', '.join(modules)

@test('Recall: constraint parsing, ranking and moment rules execute', 'Recall')
def test_recall_rules():
    return _pure_modules(['recall_pure'])

@test('Perception: chapter, fingerprint and skip decision rules execute', 'Perception')
def test_perception_rules():
    return _pure_modules(['skip_policy_pure', 'fingerprint_pure'])

@test('Babel: caption overlap, translation fallback and recap lifecycle execute', 'Babel')
def test_babel_rules():
    return _pure_modules(['live_captions_pure', 'recap_pure'])

@test('Continuum: browser capabilities, signed tokens and slot lifecycle execute', 'Continuum')
def test_continuum_rules():
    return _pure_modules(['stream_pure'])
