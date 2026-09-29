# VERSION: 1.0
# AUTHORS: Opal
"""Public Domain Torrents movie catalog and its actual downloadable torrents."""
from html.parser import HTMLParser
from urllib.parse import unquote, urljoin, urlsplit, urlunsplit

from helpers import retrieve_url
from novaprinter import prettyPrinter


class Links(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.rows, self.href, self.parts = [], None, []

    def handle_starttag(self, tag, attrs):
        if tag == 'a':
            self.href, self.parts = dict(attrs).get('href'), []

    def handle_data(self, data):
        if self.href is not None:
            self.parts.append(data)

    def handle_endtag(self, tag):
        if tag == 'a' and self.href is not None:
            self.rows.append((self.href, ' '.join(' '.join(self.parts).split())))
            self.href = None


class publicdomaintorrents:
    url = 'https://www.publicdomaintorrents.info'
    name = 'Public Domain Torrents'
    supported_categories = {'all': '', 'movies': ''}

    def search(self, what, cat='all'):
        terms = unquote(what).lower().split()
        if not terms or cat not in self.supported_categories:
            return
        catalog = Links()
        catalog.feed(retrieve_url(f'{self.url}/nshowcat.html?category=ALL', unescape_html_entities=False))
        seen, matched = set(), 0
        for href, title in catalog.rows:
            if (not href.startswith('nshowmovie.html?movieid=')
                    or not all(term in title.lower() for term in terms) or href in seen):
                continue
            seen.add(href)
            matched += 1
            if matched > 10:
                break
            detail = urljoin(self.url + '/', href)
            links = Links()
            links.feed(retrieve_url(detail, unescape_html_entities=False))
            for torrent, label in links.rows:
                parts = urlsplit(urljoin(detail, torrent))
                if (parts.hostname not in ('www.publicdomaintorrents.com', 'www.publicdomaintorrents.info')
                        or '.torrent' not in parts.query or '\n' in torrent or '\r' in torrent):
                    continue
                # The catalog's old HTTP links also work over TLS.
                playable = urlunsplit(('https', parts.netloc, parts.path, parts.query, ''))
                prettyPrinter({'link': playable, 'name': f'{title} ({label})',
                               'size': -1, 'seeds': -1, 'leech': -1,
                               'engine_url': self.url, 'desc_link': detail})
