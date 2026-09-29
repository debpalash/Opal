#!/usr/bin/env python3
"""Opt-in catalog smoke check against an isolated local Opal server.

Starts searches and changes browse selections; it never starts playback.
Use a throwaway XDG config and a separate port, not your everyday Opal session.
Example: python3 tests/test_browse_sources_live.py --base-url http://127.0.0.1:41697 --token-file /tmp/isolated/opal/api.token
"""
import argparse
import json
from pathlib import Path
import time
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--token-file', type=Path, required=True)
    args = parser.parse_args()
    base = args.base_url.rstrip('/')
    if urlparse(base).hostname not in ('127.0.0.1', 'localhost', '::1'):
        parser.error('use an isolated local server')
    token = args.token_file.read_text().strip()

    def api(path):
        request = Request(base + '/api/' + path, headers={'Authorization': 'Bearer ' + token})
        with urlopen(request, timeout=10) as response:
            return json.load(response)

    def settled(path, flag):
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            view = api(path)
            if not view.get(flag):
                return view
            time.sleep(0.5)
        raise AssertionError(f'{path}: loading did not finish')

    for name, path, key in [('Podcasts', 'podcasts', 'results'), ('Radio', 'radio', 'stations'), ('Comics', 'comics/results', 'results')]:
        view = settled(path, 'loading')
        assert view[key], f'{name}: empty catalog'
        print(f'{name}: {len(view[key])} rows', flush=True)

    for path, view_path, key in [('radio/more', 'radio', 'stations'), ('comics/more', 'comics/results', 'results')]:
        before = api(view_path)
        if not before.get('has_more'):
            continue
        api(path)
        after = settled(view_path, 'loading_more')
        assert len(after[key]) > len(before[key]), f'{path}: no additional rows'
        print(f'{path}: {len(before[key])} -> {len(after[key])}', flush=True)

    feed = 'https://www.nasa.gov/feeds/podcasts/houston-we-have-a-podcast'
    api('podcasts/search?q=' + quote(feed, safe=''))
    view = settled('podcasts', 'loading')
    assert len(view['results']) == 1, 'direct RSS did not produce a show'
    api('podcasts/episodes?idx=0')
    view = settled('podcasts', 'episodes_loading')
    assert view['episodes'], 'direct RSS did not produce playable episodes'
    assert all(row['url'].startswith(('https://', 'http://')) for row in view['episodes'])
    print(f'Direct RSS: {len(view["episodes"])} playable episode entries', flush=True)


if __name__ == '__main__':
    main()
