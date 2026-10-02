# VERSION: 1.0
# AUTHORS: Opal
"""AnimeTosho's documented JSON feed; actual torrent metadata, no DDL scraping.

Contract: https://animetosho.org/about#feeds
Search uses q; swarm counts and total_size are provider fields, never guesses.
"""
import html
import json
import re
from urllib.parse import parse_qsl, unquote, urlencode, urlsplit

from helpers import retrieve_url
from novaprinter import prettyPrinter


class animetosho:
    url = 'https://feed.animetosho.org'
    name = 'AnimeTosho'
    supported_categories = {'all': '', 'movies': '', 'tv': ''}

    def search(self, what, cat='all'):
        words = unquote(what).strip()
        if not words or cat not in self.supported_categories:
            return
        data = json.loads(retrieve_url(
            self.url.rstrip('/') + '/json?' + urlencode({'q': words}),
            unescape_html_entities=False))
        if not isinstance(data, list):
            return
        seen = set()
        for row in data[:100]:
            if not isinstance(row, dict) or row.get('status') in ('deleted', 'hidden'):
                continue
            digest, title = row.get('info_hash'), row.get('title')
            if (not isinstance(digest, str) or not re.fullmatch(r'[a-fA-F0-9]{40}', digest)
                    or not isinstance(title, str) or not title.strip()):
                continue
            digest = digest.lower()
            if digest in seen:
                continue
            seen.add(digest)
            title = ' '.join(html.unescape(title).split()).replace('|', ' ')
            # Canonical hex BTIH deduplicates Nyaa and other indexes of the same
            # release. Preserve the feed's tracker URLs without its base32 xt.
            params = [('dn', title)]
            magnet = row.get('magnet_uri', '')
            if isinstance(magnet, str) and len(magnet) <= 4096 and magnet.startswith('magnet:?'):
                for key, value in parse_qsl(urlsplit(magnet).query):
                    if key == 'tr' and value.startswith(('https://', 'http://', 'udp://')):
                        params.append((key, value))
            link = 'magnet:?xt=urn:btih:' + digest + '&' + urlencode(params)
            detail = row.get('link', '')
            if not isinstance(detail, str) or '\n' in detail or '\r' in detail:
                detail = ''
            host = urlsplit(detail).hostname or ''
            if urlsplit(detail).scheme != 'https' or not (host == 'animetosho.org' or host.endswith('.animetosho.org')):
                detail = ''

            def count(key):
                try:
                    return max(-1, int(row.get(key, -1)))
                except (TypeError, ValueError):
                    return -1

            prettyPrinter({'link': link, 'name': title,
                           'size': count('total_size'), 'seeds': count('seeders'),
                           'leech': count('leechers'), 'pub_date': count('timestamp'),
                           'engine_url': self.url, 'desc_link': detail})
