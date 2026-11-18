# VERSION: 1.0
# AUTHORS: Opal
"""AudioBook Bay: audiobook search. The result list gives title and size; the
info hash and tracker list are only on each book's page, so the first few
results are opened (bounded, in parallel) to build real magnets.
Swarm counts are not published, so seeds/leech stay -1.
"""
import re
from urllib.parse import unquote, urlencode

from helpers import retrieve_url
from novaprinter import prettyPrinter
from opal_release_feed import MAX_BODY
from opal_torrent_util import TRACKERS, fetch_many, magnet_from_hash, text_of

MAX_DETAILS = 12

_POST = re.compile(r'<div class="postTitle">\s*<h2>\s*<a href="(/[a-z0-9_-]+/[^"/]+/)"[^>]*>(.*?)</a>', re.S | re.I)
_SIZE = re.compile(r'File Size:\s*<span[^>]*>\s*([\d.]+)\s*</span>\s*([KMGT]B)', re.I)
_HASH = re.compile(r'Info Hash:\s*</td>\s*<td>\s*([a-f0-9]{40})\s*</td>', re.I)
_TRACKER = re.compile(r'<td>\s*Tracker:\s*</td>\s*<td>\s*((?:udp|https?)://[^<\s|]{4,200})\s*</td>', re.I)


class audiobookbay:
    url = 'https://audiobookbay.lu'
    name = 'AudioBook Bay (Audiobooks)'
    supported_categories = {'all': '', 'books': ''}

    def search(self, what, cat='all'):
        # The site's search only matches lower-case terms.
        query = unquote(what).strip().lower()
        if not query or cat not in self.supported_categories:
            return
        base = self.url.rstrip('/')
        body = retrieve_url(base + '/?' + urlencode({'s': query}),
                            unescape_html_entities=False, max_bytes=MAX_BODY)
        posts, seen_paths = [], set()
        for chunk in body.split('<div class="post">')[1:]:
            found = _POST.search(chunk)
            if not found or found.group(1) in seen_paths:
                continue
            seen_paths.add(found.group(1))
            size = _SIZE.search(chunk)
            posts.append((found.group(1), text_of(found.group(2)),
                          size.group(1) + ' ' + size.group(2) if size else -1))
            if len(posts) >= MAX_DETAILS:
                break

        def fetch(url):
            return retrieve_url(url, unescape_html_entities=False, attempts=1, max_bytes=MAX_BODY)

        pages = fetch_many(fetch, [base + path for path, _, _ in posts])
        seen = set()
        for (path, title, size), page in zip(posts, pages):
            found = _HASH.search(page)
            if not title or not found or found.group(1).lower() in seen:
                continue
            seen.add(found.group(1).lower())
            trackers = list(dict.fromkeys(_TRACKER.findall(page)))[:8] or TRACKERS
            prettyPrinter({
                'link': magnet_from_hash(found.group(1), title, trackers), 'name': title,
                'size': size, 'seeds': -1, 'leech': -1,
                'engine_url': self.url, 'desc_link': base + path,
            })
