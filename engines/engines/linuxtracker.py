# VERSION: 1.0
# AUTHORS: Opal
"""LinuxTracker: Linux distribution ISOs. The result table names each torrent
by info hash and reports size plus tracker and external swarm counts.
"""
import re
from urllib.parse import unquote, urlencode

from helpers import retrieve_url
from novaprinter import prettyPrinter
from opal_release_feed import MAX_BODY, MAX_ROWS
from opal_torrent_util import magnet_from_hash, text_of

_NAME = re.compile(r'<a class="torrent-name" href="/torrents/([a-f0-9]{40})/">(.*?)</a>', re.S | re.I)
_SIZE = re.compile(r'class="numeric muted-cell">\s*([\d.]+\s*[KMGT]?i?B)', re.I)


def _swarm(row, kind):
    """Tracker count plus the "+N ext" external count for one swarm column."""
    cell = re.search(r'class="numeric ' + kind + r' stat-stack">(.*?)</td>', row, re.S)
    if not cell:
        return -1
    local = re.search(r'<strong>\s*(\d+)\s*</strong>', cell.group(1))
    if not local:
        return -1
    extra = re.search(r'\+\s*(\d+)\s*ext', cell.group(1))
    return int(local.group(1)) + (int(extra.group(1)) if extra else 0)


class linuxtracker:
    url = 'https://linuxtracker.org'
    name = 'LinuxTracker (Linux ISOs)'
    supported_categories = {'all': '', 'software': ''}

    def search(self, what, cat='all'):
        query = unquote(what).strip()
        if not query or cat not in self.supported_categories:
            return
        base = self.url.rstrip('/')
        body = retrieve_url(base + '/torrents/?' + urlencode({'q': query}),
                            unescape_html_entities=False, max_bytes=MAX_BODY)
        seen = set()
        for row in body.split('<tr>')[1:MAX_ROWS + 1]:
            found = _NAME.search(row)
            if not found:
                continue
            digest, title = found.group(1).lower(), text_of(found.group(2))
            if not title or digest in seen:
                continue
            seen.add(digest)
            size = _SIZE.search(row)
            prettyPrinter({
                'link': magnet_from_hash(digest, title), 'name': title,
                'size': size.group(1) if size else -1,
                'seeds': _swarm(row, 'seeds'), 'leech': _swarm(row, 'leeches'),
                'engine_url': self.url, 'desc_link': base + '/torrents/' + digest + '/',
            })
