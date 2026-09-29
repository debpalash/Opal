#!/usr/bin/env python3
"""Opt-in checks for the eleven installed sources on an isolated local Opal.

Install their manifest definitions in the throwaway config first. This changes
browse selections and loads text/page images, but never starts media playback.
"""
import argparse
import json
from pathlib import Path
import time
from urllib.parse import quote, urlparse
from urllib.error import HTTPError
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
        with urlopen(request, timeout=15) as response:
            return json.load(response)

    def until(path, predicate, timeout=100):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            view = api(path)
            if predicate(view):
                return view
            time.sleep(.5)
        raise AssertionError(f'{path}: did not reach expected state')

    def first_image(label):
        deadline = time.monotonic() + 100
        while time.monotonic() < deadline:
            request = Request(base + '/api/comics/page?i=0', headers={'Authorization': 'Bearer ' + token})
            try:
                with urlopen(request, timeout=15) as response:
                    content_type = response.headers.get_content_type()
                    image = response.read()
                assert content_type.startswith('image/') and len(image) > 100, f'{label}: invalid page image'
                return len(image)
            except HTTPError as error:
                if error.code != 404:
                    raise
            time.sleep(.5)
        raise AssertionError(f'{label}: first page image was not downloaded')

    for query, source, label in [('mother', 6, 'Royal Road'), ('dragon', 7, 'NovelFire')]:
        api('novels/search?q=' + quote(query))
        view = until('novels', lambda d: not d['loading'])
        matches = [(i, r) for i, r in enumerate(view['results']) if r['source'] == source]
        assert matches, f'{label}: no search results'
        api(f'novels/open?idx={matches[0][0]}')
        view = until('novels', lambda d: not d['chapters_loading'])
        assert view['chapters'], f'{label}: no chapters'
        chapter_count = len(view['chapters'])
        api('novels/chapter?idx=0')
        view = until('novels', lambda d: not d['text_loading'])
        assert len(view['text']) > 100 and not view['error'], f'{label}: no reading text'
        print(f'{label}: {len(matches)} results, {chapter_count} chapters, {len(view["text"])} text characters', flush=True)

    api('comics/search?q=One%20Piece')
    view = until('comics/results', lambda d: not d['loading'])
    weeb = next((r for r in view['results'] if r['url'].startswith('weebcentral:')), None)
    assert weeb, 'Weeb Central: no search result'
    api('comics/load?url=' + quote(weeb['url'], safe=''))
    view = until('comics', lambda d: not d['loading'] and d['pages'] > 0)
    print(f'Weeb Central: {view["pages"]} reader pages, {first_image("Weeb Central")} first-page image bytes', flush=True)
    api('comics/close')
    until('comics', lambda d: d['pages'] == 0)
    api('comics/search?q=')
    view = until('comics/results', lambda d: not d['loading'])
    comic = next((r for r in view['results'] if r['url'].startswith('comicbookplus:')), None)
    assert comic, 'ComicBookPlus: no browse result'
    api('comics/load?url=' + quote(comic['url'], safe=''))
    view = until('comics', lambda d: not d['loading'] and d['pages'] > 0)
    print(f'ComicBookPlus: {view["pages"]} reader pages (reader cap: 128), {first_image("ComicBookPlus")} first-page image bytes', flush=True)
    api('comics/close')

    api('music/source?id=4')
    api('music/search?q=electronic')
    view = until('music', lambda d: not d['loading'])
    assert view['source'] == 4 and view['songs'], 'Audius: no music results'
    assert all('/v1/tracks/' in r['url'] and '/stream?' in r['url'] for r in view['songs'])
    print(f'Audius: {len(view["songs"])} public stream entries', flush=True)

    view = until('podcasts', lambda d: not d['loading'])
    names = ' '.join(r['name'] for r in view['results'])
    for name in ['Houston We Have a Podcast', 'Global News Podcast', 'Up First']:
        assert name in names, f'Installed podcast absent: {name}'
    print('NASA, BBC and NPR: installed shows appear in podcast browse', flush=True)


if __name__ == '__main__':
    main()
