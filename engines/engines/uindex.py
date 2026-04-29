# VERSION: 1.1
# AUTHORS: ZigZag
# UIndex — BitTorrent indexer (uindex.org)
# Uses class-based selectors: sr-magnet, sr-torrent-link

import re
import urllib.parse
import urllib.request
import html as html_mod
import datetime
import ssl

from novaprinter import prettyPrinter


class uindex:
    url = 'https://uindex.org'
    name = 'UIndex'
    supported_categories = {
        'all': '',
        'movies': 'movies',
        'tv': 'tv',
        'music': 'music',
        'games': 'games',
        'software': 'software',
        'anime': 'anime',
    }

    trackers_list = [
        'udp://tracker.opentrackr.org:1337/announce',
        'udp://open.stealth.si:80/announce',
        'udp://tracker.openbittorrent.com:6969/announce',
        'udp://exodus.desync.com:6969/announce',
        'udp://tracker.torrent.eu.org:451/announce',
        'udp://tracker.tiny-vps.com:6969/announce',
    ]
    trackers = '&'.join(urllib.parse.urlencode({'tr': t}) for t in trackers_list)

    def _get_ua(self):
        base = datetime.date(2024, 4, 16)
        ver = 125 + ((datetime.date.today() - base).days // 30)
        return f"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:{ver}.0) Gecko/20100101 Firefox/{ver}.0"

    def _fetch(self, url):
        try:
            ctx = ssl.create_default_context()
            req = urllib.request.Request(url, headers={
                'User-Agent': self._get_ua(),
                'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            })
            resp = urllib.request.urlopen(req, timeout=12, context=ctx)
            return resp.read().decode('utf-8', 'replace')
        except Exception:
            return ''

    def search(self, what, cat='all'):
        query = urllib.parse.unquote(what)

        for page in range(1, 4):  # 3 pages max
            search_url = (
                f'{self.url}/search.php?search={urllib.parse.quote(query)}'
                f'&sort=seeders&order=DESC&p={page}'
            )
            page_html = self._fetch(search_url)
            if not page_html or len(page_html) < 200:
                break

            # ── Primary: structured extraction via sr-magnet + sr-torrent-link ──
            # Each result has:
            #   <a class="sr-magnet" href="magnet:?xt=urn:btih:...">
            #   <a class="sr-torrent-link" href="/details.php?id=..." title="TORRENT NAME">

            # Find all magnet links with class="sr-magnet"
            magnet_matches = re.findall(
                r'class="sr-magnet"\s+href="(magnet:\?xt=urn:btih:[^"]+)"',
                page_html
            )
            # Find all torrent name links with class="sr-torrent-link"
            name_matches = re.findall(
                r'class="sr-torrent-link"[^>]*title="([^"]*)"',
                page_html
            )

            found = False

            if magnet_matches:
                # Parse seeds/leechers from the page — they appear in order near each result
                # Look for the pattern of green (seeds) and blue (leechers) values
                seed_matches = re.findall(r'>\s*(\d+)\s*</(?:td|span|div)', page_html)

                for i, magnet in enumerate(magnet_matches):
                    magnet = html_mod.unescape(magnet)

                    # Get name from sr-torrent-link title, or fallback to dn= in magnet
                    if i < len(name_matches):
                        name = html_mod.unescape(name_matches[i])
                    else:
                        dn_m = re.search(r'dn=([^&]+)', magnet)
                        name = urllib.parse.unquote_plus(dn_m.group(1)) if dn_m else 'Unknown'

                    # Extract size from magnet context — search nearby HTML
                    size_bytes = 0
                    # Try to find size near this result in the HTML
                    mag_pos = page_html.find(magnet[:60])
                    if mag_pos > 0:
                        nearby = page_html[mag_pos:mag_pos + 800]
                        size_m = re.search(r'([\d.]+)\s*(TB|GB|MB|KB)', nearby, re.I)
                        if size_m:
                            val = float(size_m.group(1))
                            unit = size_m.group(2).upper()
                            if unit == 'TB': size_bytes = int(val * 1099511627776)
                            elif unit == 'GB': size_bytes = int(val * 1073741824)
                            elif unit == 'MB': size_bytes = int(val * 1048576)
                            elif unit == 'KB': size_bytes = int(val * 1024)

                        # Extract seeds and leechers from nearby context
                        seeds_m = re.findall(r'>\s*(\d+)\s*</', nearby)
                        seeds = seeds_m[-2] if len(seeds_m) >= 2 else '0'
                        leech = seeds_m[-1] if len(seeds_m) >= 2 else '0'
                    else:
                        seeds = '0'
                        leech = '0'

                    prettyPrinter({
                        'link': magnet,
                        'name': name,
                        'size': str(size_bytes),
                        'seeds': seeds,
                        'leech': leech,
                        'engine_url': self.url,
                        'desc_link': self.url,
                    })
                    found = True

            # ── Fallback: generic table row extraction ──
            if not found:
                rows = re.findall(r'<tr[^>]*>(.*?)</tr>', page_html, re.DOTALL)
                for row in rows:
                    try:
                        mag_m = re.search(r'(magnet:\?xt=urn:btih:[^"\'<>\s]+)', row)
                        if not mag_m:
                            hash_m = re.search(r'btih:([a-fA-F0-9]{40})', row)
                            if not hash_m:
                                continue
                        name_m = re.search(r'<a[^>]*>([^<]+)</a>', row)
                        if not name_m:
                            continue
                        name = html_mod.unescape(name_m.group(1).strip())
                        if len(name) < 3:
                            continue

                        if mag_m:
                            magnet = html_mod.unescape(mag_m.group(1))
                        else:
                            dn = urllib.parse.urlencode({'dn': name})
                            magnet = f"magnet:?xt=urn:btih:{hash_m.group(1)}&{dn}&{self.trackers}"

                        size_m = re.search(r'([\d.]+)\s*(GB|MB|KB|TB)', row, re.I)
                        size_bytes = 0
                        if size_m:
                            val = float(size_m.group(1))
                            unit = size_m.group(2).upper()
                            if unit == 'TB': size_bytes = int(val * 1099511627776)
                            elif unit == 'GB': size_bytes = int(val * 1073741824)
                            elif unit == 'MB': size_bytes = int(val * 1048576)
                            elif unit == 'KB': size_bytes = int(val * 1024)

                        nums = re.findall(r'>(\d+)<', row)
                        seeds = nums[-2] if len(nums) >= 2 else '0'
                        leech = nums[-1] if len(nums) >= 2 else '0'

                        prettyPrinter({
                            'link': magnet,
                            'name': name,
                            'size': str(size_bytes),
                            'seeds': seeds,
                            'leech': leech,
                            'engine_url': self.url,
                            'desc_link': self.url,
                        })
                        found = True
                    except Exception:
                        continue

            if not found:
                break
