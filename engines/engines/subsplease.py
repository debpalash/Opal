# VERSION: 1.0
# AUTHORS: Opal
"""SubsPlease's public JSON release search, not a generic website detail link.

Adds Nova universal search to the existing installed SubsPlease source marker.
All quality/name/BTIH/size fields come from actual release downloads.
"""
import json
import re
from urllib.parse import quote, unquote, urlencode
from helpers import retrieve_url
from novaprinter import prettyPrinter
from opal_release_feed import MAX_BODY, MAX_ROWS, canonical_magnet, clean_title


class subsplease:
    url = 'https://subsplease.org'
    name = 'SubsPlease (Anime)'
    supported_categories = {'all': '', 'movies': '', 'tv': '', 'anime': ''}

    def search(self, what, cat='all'):
        query = unquote(what).strip()
        if not query or cat not in self.supported_categories:
            return
        body = retrieve_url(self.url.rstrip('/') + '/api/?' + urlencode({'f': 'search', 'tz': 'UTC', 's': query}),
                            unescape_html_entities=False, attempts=1, max_bytes=4 * 1024 * 1024)
        if not isinstance(body, str) or len(body) > MAX_BODY:
            return
        try:
            data = json.loads(body)
        except (ValueError, TypeError):
            return
        if not isinstance(data, dict):
            return
        seen, found = set(), 0
        for title, release in list(data.items())[:MAX_ROWS]:
            if not isinstance(release, dict) or not isinstance(release.get('downloads'), list):
                continue
            for download in release['downloads'][:8]:
                if not isinstance(download, dict):
                    continue
                magnet = canonical_magnet(download.get('magnet'), clean_title(title))
                if not magnet:
                    continue
                link, digest, name, size = magnet
                if digest in seen or not name:
                    continue
                seen.add(digest)
                slug = release.get('page', '')
                detail = self.url.rstrip('/') + '/shows/' + quote(slug, safe='') + '/' if isinstance(slug, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,128}', slug) else ''
                prettyPrinter({'link': link, 'name': name, 'size': size,
                               'seeds': -1, 'leech': -1, 'engine_url': self.url,
                               'desc_link': detail})
                found += 1
                if found >= MAX_ROWS:
                    return
