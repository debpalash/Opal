# VERSION: 1.0
# AUTHORS: Opal
"""TorrentKitty: DHT-crawled magnet search. Rows carry a full magnet and the
date first seen. The "size" column there is not the content size and swarm
counts are not published, so size/seeds/leech stay -1 (unknown).
"""
import re
from urllib.parse import quote, unquote

from helpers import retrieve_url
from novaprinter import prettyPrinter
from opal_release_feed import MAX_BODY, MAX_ROWS, canonical_magnet, clean_title
from opal_torrent_util import text_of, ymd_epoch

_ROW = re.compile(r'<td class="name">(.*?)</td>\s*<td class="size">.*?</td>\s*'
                  r'<td class="date">(.*?)</td>\s*<td class="action">(.*?)</td>', re.S)
_DETAIL = re.compile(r'href="(/information/[A-Fa-f0-9]{40})"')
_MAGNET = re.compile(r'href="(magnet:\?xt=urn:btih:[^"]+)"', re.I)


class torrentkitty:
    url = 'https://www.torrentkitty.tv'
    name = 'TorrentKitty (DHT)'
    supported_categories = {'all': ''}

    def search(self, what, cat='all'):
        query = ' '.join(unquote(what).replace('/', ' ').split())
        if not query or cat not in self.supported_categories:
            return
        base = self.url.rstrip('/')
        body = retrieve_url(base + '/search/' + quote(query, safe='') + '/',
                            unescape_html_entities=False, max_bytes=MAX_BODY)
        seen = set()
        for name, date, action in _ROW.findall(body)[:MAX_ROWS]:
            title, found = text_of(name), _MAGNET.search(action)
            magnet = canonical_magnet(clean_title(found.group(1)), title) if found else None
            if not title or not magnet or magnet[1] in seen:
                continue
            seen.add(magnet[1])
            detail = _DETAIL.search(action)
            prettyPrinter({
                'link': magnet[0], 'name': title, 'size': -1, 'seeds': -1, 'leech': -1,
                'engine_url': self.url, 'desc_link': base + detail.group(1) if detail else base,
                'pub_date': ymd_epoch(date),
            })
