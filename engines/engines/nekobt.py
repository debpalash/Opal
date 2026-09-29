# VERSION: 1.0
# AUTHORS: Opal
"""NekoBT public anime releases, using its JSON search endpoint."""
import html
import json
from urllib.parse import quote, unquote, urlencode

from helpers import retrieve_url
from novaprinter import prettyPrinter


class nekobt:
    url = 'https://nekobt.to'
    name = 'NekoBT (Anime)'
    supported_categories = {'all': '', 'movies': '', 'tv': ''}

    def search(self, what, cat='all'):
        words = unquote(what).strip()
        if not words or cat not in self.supported_categories:
            return
        params = urlencode({'query': words, 'sort_by': 'seeders'})
        body = json.loads(retrieve_url(
            f'{self.url}/api/v1/torrents/search?{params}',
            unescape_html_entities=False))
        seen = set()
        for item in body.get('data', {}).get('results', [])[:100]:
            if not isinstance(item, dict):
                continue
            magnet, title = item.get('magnet'), item.get('title')
            if (not isinstance(magnet, str) or not magnet.startswith('magnet:?xt=urn:btih:')
                    or len(magnet) > 4096 or '\n' in magnet or '\r' in magnet
                    or not isinstance(title, str) or item.get('deleted') or item.get('hidden')):
                continue
            if magnet in seen:
                continue
            seen.add(magnet)
            def count(field):
                try:
                    return max(-1, int(item.get(field, -1)))
                except (TypeError, ValueError):
                    return -1
            prettyPrinter({
                'link': magnet, 'name': ' '.join(html.unescape(title).split()),
                'size': count('filesize'), 'seeds': count('seeders'),
                'leech': count('leechers'), 'engine_url': self.url,
                'desc_link': f'{self.url}/torrents/{quote(str(item.get("id", "")), safe="")}',
            })
