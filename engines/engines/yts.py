# VERSION: 1.3
# AUTHORS: ZigZag

import json
import urllib.parse
import urllib.request
import datetime

from novaprinter import prettyPrinter

class yts:
    url = 'https://yts.mx'
    name = 'YTS (Movies)'
    supported_categories = {
        'all': '',
        'movies': '',
    }

    trackers_list = [
        'udp://open.demonii.com:1337/announce',
        'udp://tracker.openbittorrent.com:80',
        'udp://tracker.coppersurfer.tk:6969',
        'udp://glotorrents.pw:6969/announce',
        'udp://tracker.opentrackr.org:1337/announce',
        'udp://torrent.gresille.org:80/announce',
        'udp://p4p.arenabg.com:1337',
        'udp://tracker.leechers-paradise.org:6969',
    ]
    trackers = '&'.join(urllib.parse.urlencode({'tr': t}) for t in trackers_list)

    def _get_ua(self):
        base = datetime.date(2024, 4, 16)
        ver = 125 + ((datetime.date.today() - base).days // 30)
        return f"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:{ver}.0) Gecko/20100101 Firefox/{ver}.0"

    def search(self, what, cat='all'):
        query = urllib.parse.unquote(what)

        for page in range(1, 4):
            params = urllib.parse.urlencode({
                'query_term': query,
                'page': page,
                'limit': 50,
                'sort_by': 'seeds',
                'order_by': 'desc',
            })
            api_url = f'https://yts.mx/api/v2/list_movies.json?{params}'

            try:
                req = urllib.request.Request(api_url, headers={'User-Agent': self._get_ua()})
                resp = urllib.request.urlopen(req, timeout=10)
                data = json.loads(resp.read().decode('utf-8'))
            except Exception:
                break

            movies = data.get('data', {}).get('movies', [])
            if not movies:
                break

            for movie in movies:
                title = movie.get('title_long', movie.get('title', ''))
                torrents = movie.get('torrents', [])

                for t in torrents:
                    quality = t.get('quality', '')
                    codec = t.get('video_codec', '')
                    torrent_type = t.get('type', '')
                    size_bytes = t.get('size_bytes', 0)
                    seeds = t.get('seeds', 0)
                    peers = t.get('peers', 0)
                    info_hash = t.get('hash', '')

                    if not info_hash:
                        continue

                    name = f"{title} [{quality}] [{codec}] [{torrent_type}]"
                    dn = urllib.parse.urlencode({'dn': name})
                    magnet = f"magnet:?xt=urn:btih:{info_hash}&{dn}&{self.trackers}"

                    prettyPrinter({
                        'link': magnet,
                        'name': name,
                        'size': str(size_bytes),
                        'seeds': str(seeds),
                        'leech': str(peers),
                        'engine_url': self.url,
                        'desc_link': movie.get('url', self.url),
                    })
