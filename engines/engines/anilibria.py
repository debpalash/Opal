# VERSION: 1.0
# AUTHORS: Opal
"""AniLibria (AniLiberty) public JSON API: Russian-dub anime releases with
provider magnets, sizes and swarm counts. One title search, then the torrent
list of each of the first few matching releases.
"""
import calendar
import json
import re
from urllib.parse import quote, unquote, urlencode

from helpers import retrieve_url
from novaprinter import prettyPrinter
from opal_release_feed import MAX_BODY, canonical_magnet, clean_title, count
from opal_torrent_util import fetch_many

MAX_RELEASES = 6


def _epoch(value):
    m = re.match(r'(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})', value if isinstance(value, str) else '')
    if not m:
        return -1
    try:
        return calendar.timegm(tuple(int(g) for g in m.groups()))
    except (ValueError, OverflowError):
        return -1


def _key(text):
    return re.sub(r'[\W_]+', '', text.lower())


def _json(body):
    try:
        return json.loads(body)
    except (TypeError, ValueError):
        return None


class anilibria:
    url = 'https://anilibria.top'
    name = 'AniLibria (Anime, Russian dub)'
    supported_categories = {'all': '', 'anime': '', 'tv': '', 'movies': ''}

    def search(self, what, cat='all'):
        query = unquote(what).strip()
        if not query or cat not in self.supported_categories:
            return
        base = self.url.rstrip('/')

        def fetch(url):
            return retrieve_url(url, {'Accept': 'application/json'},
                                unescape_html_entities=False, attempts=1, max_bytes=MAX_BODY)

        releases = _json(retrieve_url(
            base + '/api/v1/app/search/releases?' + urlencode({'query': query}),
            {'Accept': 'application/json'}, unescape_html_entities=False, max_bytes=MAX_BODY))
        if not isinstance(releases, list):
            return
        picked = []
        for release in releases:
            if isinstance(release, dict) and count(release.get('id')) > 0:
                picked.append(release)
            if len(picked) >= MAX_RELEASES:
                break
        bodies = fetch_many(fetch, [base + '/api/v1/anime/torrents/release/' + str(count(r['id']))
                                    for r in picked])
        seen = set()
        for release, body in zip(picked, bodies):
            torrents = _json(body)
            if not isinstance(torrents, list):
                continue
            names = release.get('name') if isinstance(release.get('name'), dict) else {}
            english = clean_title(names.get('english') or '')
            alias = release.get('alias') if isinstance(release.get('alias'), str) else ''
            for item in torrents[:20]:
                if not isinstance(item, dict):
                    continue
                label = clean_title(item.get('label') or '')
                magnet = canonical_magnet(item.get('magnet'), label)
                if not label or not magnet or magnet[1] in seen:
                    continue
                seen.add(magnet[1])
                # Labels are usually romanized already; add the English title
                # when the label does not mention it, so the row is findable.
                if english and _key(english)[:10] not in _key(label):
                    label = english + ' - ' + label
                prettyPrinter({
                    'link': magnet[0], 'name': label, 'size': count(item.get('size')),
                    'seeds': count(item.get('seeders')), 'leech': count(item.get('leechers')),
                    'engine_url': self.url,
                    'desc_link': base + '/anime/releases/release/' + quote(alias, safe='') if alias else base,
                    'pub_date': _epoch(item.get('created_at')),
                })
