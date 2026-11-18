# VERSION: 1.0
# AUTHORS: Opal
"""NNM-Club: large Russian-language general tracker with a guest-visible
search. The result table carries exact sizes and swarm counts; the magnet is
on each topic page, so the best-seeded results are opened (bounded, in
parallel). The site speaks windows-1251, including in the query string.
"""
import re
from urllib.parse import quote, unquote

from helpers import retrieve_url
from novaprinter import prettyPrinter
from opal_release_feed import MAX_BODY
from opal_torrent_util import fetch_many, magnet_from_hash, text_of

MAX_DETAILS = 10

_TOPIC = re.compile(r'href="viewtopic\.php\?t=(\d+)"[^>]*>\s*<b>(.*?)</b>', re.S)
_STAMPED = re.compile(r'<u>(\d+)</u>')
_SEEDS = re.compile(r'class="seedmed">\s*<b>(\d+)')
_LEECH = re.compile(r'class="leechmed">\s*<b>(\d+)')
_MAGNET = re.compile(r'href="magnet:\?xt=urn:btih:([a-fA-F0-9]{40})')


class nnmclub:
    url = 'https://nnmclub.to'
    name = 'NNM-Club (Russian)'
    supported_categories = {'all': '', 'movies': '', 'tv': '', 'music': '', 'games': '',
                            'software': '', 'books': '', 'anime': ''}

    def search(self, what, cat='all'):
        query = unquote(what).strip()
        if not query or cat not in self.supported_categories:
            return
        base = self.url.rstrip('/')
        # o=10&s=2: order by seeders, descending.
        body = retrieve_url(base + '/forum/tracker.php?nm='
                            + quote(query.encode('cp1251', 'ignore')) + '&o=10&s=2',
                            unescape_html_entities=False, max_bytes=MAX_BODY)
        rows, seen = [], set()
        for chunk in body.split('<tr class="prow')[1:]:
            topic = _TOPIC.search(chunk)
            if not topic or topic.group(1) in seen:
                continue
            seen.add(topic.group(1))
            title = text_of(topic.group(2))
            stamped = _STAMPED.findall(chunk)  # [size in bytes, added (unix time)]
            seeds, leech = _SEEDS.search(chunk), _LEECH.search(chunk)
            if not title:
                continue
            rows.append((topic.group(1), title,
                         int(stamped[0]) if stamped else -1,
                         int(seeds.group(1)) if seeds else -1,
                         int(leech.group(1)) if leech else -1,
                         int(stamped[1]) if len(stamped) > 1 else -1))
            if len(rows) >= MAX_DETAILS:
                break

        def fetch(url):
            return retrieve_url(url, unescape_html_entities=False, attempts=1, max_bytes=MAX_BODY)

        pages = fetch_many(fetch, [base + '/forum/viewtopic.php?t=' + r[0] for r in rows])
        emitted = set()
        for (topic_id, title, size, seeds, leech, added), page in zip(rows, pages):
            found = _MAGNET.search(page)
            if not found or found.group(1).lower() in emitted:
                continue
            emitted.add(found.group(1).lower())
            prettyPrinter({
                'link': magnet_from_hash(found.group(1), title), 'name': title, 'size': size,
                'seeds': seeds, 'leech': leech, 'engine_url': self.url,
                'desc_link': base + '/forum/viewtopic.php?t=' + topic_id, 'pub_date': added,
            })
