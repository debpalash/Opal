# VERSION: 1.0
# AUTHORS: Opal
"""Internet Archive items with downloadable BitTorrent bundles.

One bounded search request, no per-result detail requests. Unknown swarm counts
stay unknown; download counts must never be reported as seeders.
API: https://archive.org/advancedsearch.php
"""
import html
import json
from urllib.parse import quote, unquote, urlencode

from helpers import retrieve_url
from novaprinter import prettyPrinter


class internetarchive:
    url = 'https://archive.org'
    name = 'Internet Archive'
    supported_categories = {
        'all': '', 'movies': 'movies', 'tv': 'movies',
        'music': 'audio', 'books': 'texts', 'software': 'software',
    }

    def search(self, what, cat='all'):
        # nova2 passes percent-encoded keywords, not raw text.
        words = unquote(what).strip()
        if not words:
            return
        phrase = words.replace('\\', '\\\\').replace('"', '\\"')
        query = f'title:"{phrase}" AND format:"Archive BitTorrent"'
        media = self.supported_categories.get(cat, '')
        if media:
            query += f' AND mediatype:{media}'
        params = urlencode({
            'q': query, 'fl[]': ['identifier', 'title', 'item_size'],
            'rows': 50, 'page': 1, 'output': 'json',
        }, doseq=True)
        body = json.loads(retrieve_url(f'{self.url}/advancedsearch.php?{params}', unescape_html_entities=False))
        for item in body.get('response', {}).get('docs', []):
            identifier = item.get('identifier')
            title = item.get('title')
            if not isinstance(identifier, str) or not identifier or not isinstance(title, str):
                continue
            item_path = quote(identifier, safe='')
            # Do not let remote text introduce extra nova2 protocol lines.
            title = ' '.join(html.unescape(title).splitlines())
            prettyPrinter({
                'link': f'{self.url}/download/{item_path}/{item_path}_archive.torrent',
                'name': title,
                'size': str(item.get('item_size', -1)),
                'seeds': -1, 'leech': -1,
                'engine_url': self.url,
                'desc_link': f'{self.url}/details/{item_path}',
            })
