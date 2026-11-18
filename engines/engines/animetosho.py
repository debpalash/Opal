# VERSION: 1.1
# AUTHORS: Opal
"""AnimeTosho's documented JSON feed; actual torrent metadata, no DDL scraping.

Contract: https://animetosho.org/about#feeds
Search uses q; swarm counts and total_size are provider fields, never guesses.

The feed host can vanish while the site stays up (2026-11: feed.animetosho.org
is NXDOMAIN at the authoritative servers and animetosho.org/feed/json answers
"Feed disabled"). When the feed gives no JSON, the same search is read from the
site's own listing page, which carries the same provider fields.
"""
import base64
import calendar
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
        base = self.url.rstrip('/')
        site = base.replace('://feed.', '://', 1)
        if site != base:
            try:
                data = json.loads(retrieve_url(
                    base + '/json?' + urlencode({'q': words}),
                    unescape_html_entities=False))
            except ValueError:
                data = None  # feed host gone / not JSON: read the site instead
            if data is not None:
                self._emit_feed(data)
                return
        self._emit_listing(site, retrieve_url(
            site + '/search?' + urlencode({'q': words}),
            unescape_html_entities=False))

    _ENTRY = re.compile(r'<div class="home_list_entry\b.*?(?=<div class="home_list_(?:entry|datesep)\b|\Z)', re.S)
    _TITLE = re.compile(r'<div class="link"><a href="(https://animetosho\.org/view/[^"\s]+)"[^>]*>(.*?)</a>', re.S)
    _MAGNET = re.compile(r'href="(magnet:\?[^"]+)"')
    _SIZE = re.compile(r'Total file size: ([0-9,]+) bytes')
    _SWARM = re.compile(r'Seeders: (\d+) / Leechers: (\d+)')
    _DATE = re.compile(r'Date/time submitted: (\d{2})/(\d{2})/(\d{4}) (\d{2}):(\d{2})')

    @staticmethod
    def _hex_btih(magnet):
        """Canonical lowercase-hex BTIH from a magnet's hex or base32 xt, or ''."""
        for key, value in parse_qsl(urlsplit(magnet).query):
            if key == 'xt' and value.lower().startswith('urn:btih:'):
                digest = value[9:]
                if re.fullmatch(r'[a-fA-F0-9]{40}', digest):
                    return digest.lower()
                if re.fullmatch(r'[A-Za-z2-7]{32}', digest):
                    return base64.b32decode(digest.upper()).hex()
        return ''

    def _emit_listing(self, site, page):
        seen = set()
        for entry in self._ENTRY.findall(page)[:100]:
            title_m, magnet_m = self._TITLE.search(entry), self._MAGNET.search(entry)
            if not title_m or not magnet_m:
                continue  # DDL-only entry: no torrent to hand over
            magnet = html.unescape(magnet_m.group(1))
            digest = self._hex_btih(magnet) if len(magnet) <= 4096 else ''
            title = ' '.join(html.unescape(re.sub(r'<[^>]+>', '', title_m.group(2))).split()).replace('|', ' ')
            if not digest or digest in seen or not title:
                continue
            seen.add(digest)
            params = [('dn', title)]
            for key, value in parse_qsl(urlsplit(magnet).query):
                if key == 'tr' and value.startswith(('https://', 'http://', 'udp://')):
                    params.append((key, value))
            size_m, swarm_m, date_m = (self._SIZE.search(entry), self._SWARM.search(entry),
                                       self._DATE.search(entry))
            pub_date = -1
            if date_m:
                day, month, year, hour, minute = (int(g) for g in date_m.groups())
                try:
                    pub_date = calendar.timegm((year, month, day, hour, minute, 0))
                except (ValueError, OverflowError):
                    pass
            prettyPrinter({'link': 'magnet:?xt=urn:btih:' + digest + '&' + urlencode(params),
                           'name': title,
                           'size': int(size_m.group(1).replace(',', '')) if size_m else -1,
                           'seeds': int(swarm_m.group(1)) if swarm_m else -1,
                           'leech': int(swarm_m.group(2)) if swarm_m else -1,
                           'pub_date': pub_date,
                           'engine_url': self.url, 'desc_link': title_m.group(1)})

    def _emit_feed(self, data):
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
