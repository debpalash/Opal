# VERSION: 1.0
# AUTHORS: Opal
# Knaben — a torrent metasearch aggregator (JSON POST API, no scraping needed)

import json
import urllib.parse
import urllib.request

from novaprinter import prettyPrinter


class knaben:
    url = 'https://api.knaben.org/v1'
    name = 'Knaben'
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

    def search(self, what, cat='all'):
        query = urllib.parse.unquote(what)

        body = json.dumps({
            'search_type': 'score',
            'query': query,
            'order_by': 'seeders',
            'order_direction': 'desc',
            'hide_unsafe': True,
            'size': 50,
        }).encode('utf-8')

        try:
            req = urllib.request.Request(
                self.url,
                data=body,
                headers={
                    'Content-Type': 'application/json',
                    'Accept': 'application/json',
                    'User-Agent': 'Opal',
                },
                method='POST',
            )
            resp = urllib.request.urlopen(req, timeout=12)
            data = json.loads(resp.read().decode('utf-8'))
        except Exception:
            return

        if not isinstance(data, dict):
            return

        hits = data.get('hits', [])
        if not isinstance(hits, list):
            return

        for item in hits:
            if not isinstance(item, dict):
                continue

            name = item.get('title', '')
            if not name:
                continue

            magnet = item.get('magnetUrl', '')
            if not magnet:
                info_hash = item.get('hash', '')
                if not info_hash:
                    continue
                dn = urllib.parse.urlencode({'dn': name})
                magnet = f"magnet:?xt=urn:btih:{info_hash}&{dn}&{self.trackers}"

            size = item.get('bytes', 0)
            seeds = str(item.get('seeders', 0))
            leech = str(item.get('peers', 0))

            prettyPrinter({
                'link': magnet,
                'name': name,
                'size': str(size),
                'seeds': seeds,
                'leech': leech,
                'engine_url': self.url,
                'desc_link': item.get('details', ''),
            })
