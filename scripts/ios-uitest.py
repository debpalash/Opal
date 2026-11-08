#!/usr/bin/env python3
"""Headless iOS Simulator UI/feature walk.

Launches the installed Simulator build with `--ui-test` (no Simulator.app
window), screenshots each page the in-app driver (src/ui/ios_uitest.zig)
announces, and writes zig-out/ios-uitest/report.json. Exit 1 on any failure.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import os
import select
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ios_device', ROOT / 'scripts/ios-device.py')
ios = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ios)


def parse(line):
    """`OPAL_UITEST <name> <pass|fail> <detail…>` → dict, else None."""
    marker = line.find('OPAL_UITEST ')
    if marker < 0:
        return None
    parts = line[marker:].strip().split(' ', 3)
    if len(parts) < 3 or parts[2] not in ('pass', 'fail'):
        return None
    return {'name': parts[1], 'status': parts[2], 'detail': parts[3] if len(parts) > 3 else ''}


DEDICATED = 'Opal UI Test'


def dedicated_simulator():
    """A private headless device: other tools driving the shared booted
    Simulator must not land in our screenshots."""
    data = json.loads(ios.capture(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
    for rows in data.get('devices', {}).values():
        for row in rows:
            if row.get('name') == DEDICATED and row.get('isAvailable'):
                return row
    base = ios.simulator_device()
    kind = base.get('deviceTypeIdentifier') or 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'
    udid = ios.capture(['xcrun', 'simctl', 'create', DEDICATED, kind]).strip()
    return {'udid': udid, 'name': DEDICATED, 'state': 'Shutdown'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', help='Simulator name or UDID')
    parser.add_argument('--timeout', type=int, default=360)
    parser.add_argument('--out', default=str(ROOT / 'zig-out/ios-uitest'))
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    device = ios.simulator_device(args.device) if args.device else dedicated_simulator()
    udid = device['udid']
    if device.get('state') != 'Booted':
        ios.run(['xcrun', 'simctl', 'boot', udid])
        ios.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'])
    app = ROOT / '.zig-cache/ios-simulator-xcode/Build/Products/Release-iphonesimulator/Opal.app'
    # Fresh container per run: restored torrents/config must not mask failures.
    subprocess.run(['xcrun', 'simctl', 'uninstall', udid, ios.BUNDLE], capture_output=True)
    ios.run(['xcrun', 'simctl', 'install', udid, app])
    command = ['xcrun', 'simctl', 'launch', '--console-pty', '--terminate-running-process', udid, ios.BUNDLE, '--ui-test']
    process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    results, transcript, done = [], [], False
    deadline = time.monotonic() + args.timeout
    def lines():
        # A wedged app prints nothing; never block past the deadline on it.
        fd, pending = process.stdout.fileno(), b''
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], min(max(deadline - time.monotonic(), 0), 5))
            if not ready:
                continue
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            pending += chunk
            while b'\n' in pending:
                raw, pending = pending.split(b'\n', 1)
                yield raw.decode('utf-8', 'replace') + '\n'

    try:
        for line in lines():
            transcript.append(line)
            row = parse(line)
            if row:
                results.append(row)
                print(f"{row['status']:4} {row['name']:16} {row['detail']}", flush=True)
            if 'OPAL_UITEST_SHOT ' in line:
                name = line.split('OPAL_UITEST_SHOT ', 1)[1].split()[0]
                subprocess.run(['xcrun', 'simctl', 'io', udid, 'screenshot', str(out / f'{name}.png')], capture_output=True, timeout=20)
            if 'OPAL_UITEST_DONE' in line:
                done = True
                break
            if time.monotonic() > deadline:
                break
    finally:
        try:
            subprocess.run(['xcrun', 'simctl', 'terminate', udid, ios.BUNDLE], capture_output=True, timeout=30)
        except subprocess.TimeoutExpired:
            print('warning: simctl terminate timed out', file=sys.stderr)
        if process.poll() is None:
            process.terminate()
    (out / 'console.log').write_text(''.join(transcript))
    failed = [r for r in results if r['status'] == 'fail']
    (out / 'report.json').write_text(json.dumps({'complete': done, 'results': results}, indent=2))
    print(f"{len(results) - len(failed)} pass, {len(failed)} fail, complete={done}; screenshots in {out}")
    return 0 if done and not failed else 1


if __name__ == '__main__':
    sys.exit(main())
