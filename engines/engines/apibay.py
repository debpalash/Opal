# VERSION: 1.0
# AUTHORS: ZigZag
# Apibay — the public PirateBay API mirror (JSON, no scraping needed)

import json
import urllib.parse
import urllib.request
import datetime

from novaprinter import prettyPrinter


class apibay:
    url = 'https://apibay.org'
    name = 'APIBay (TPB)'
    supported_categories = {
        'all': '0',
        'movies': '200',
        'tv': '200',
        'music': '100',
        'games': '400',
        'software': '300',
    }

    trackers_list = [
        'udp://tracker.opentrackr.org:1337/announce',
        'udp://open.stealth.si:80/announce',
        'udp://tracker.openbittorrent.com:6969/announce',
        'udp://exodus.desync.com:6969/announce',
        'udp://tracker.torrent.eu.org:451/announce',
        'udp://tracker.tiny-vps.com:6969/announce',
        'udp://tracker.moeking.me:6969/announce',
        'udp://p4p.arenabg.com:1337/announce',
    ]
    trackers = '&'.join(urllib.parse.urlencode({'tr': t}) for t in trackers_list)

    def _get_ua(self):
        base = datetime.date(2024, 4, 16)
        ver = 125 + ((datetime.date.today() - base).days // 30)
        return f"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:{ver}.0) Gecko/20100101 Firefox/{ver}.0"

    def search(self, what, cat='all'):
        query = urllib.parse.unquote(what)
        cat_id = self.supported_categories.get(cat, '0')

        api_url = f'{self.url}/q.php?q={urllib.parse.quote(query)}&cat={cat_id}'

        try:
            req = urllib.request.Request(api_url, headers={'User-Agent': self._get_ua()})
            resp = urllib.request.urlopen(req, timeout=12)
            data = json.loads(resp.read().decode('utf-8'))
        except Exception:
            return

        if not isinstance(data, list):
            return

        for item in data:
            name = item.get('name', '')
            if not name or name == 'No results returned':
                continue

            info_hash = item.get('info_hash', '')
            if not info_hash:
                continue

            size = item.get('size', '0')
            seeds = str(item.get('seeders', 0))
            leech = str(item.get('leechers', 0))
            added = item.get('added', '')

            dn = urllib.parse.urlencode({'dn': name})
            magnet = f"magnet:?xt=urn:btih:{info_hash}&{dn}&{self.trackers}"

            prettyPrinter({
                'link': magnet,
                'name': name,
                'size': str(size),
                'seeds': seeds,
                'leech': leech,
                'engine_url': self.url,
                'desc_link': f'{self.url}/description.php?id={item.get("id", "")}',
            })
