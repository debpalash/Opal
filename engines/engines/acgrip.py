# VERSION: 1.0
# AUTHORS: Opal
"""ACG.RIP term RSS: actual .torrent enclosures and provider byte sizes.

Provider identified in Prowlarr/Indexers definitions/v11/acgrip.yml; original
RSS adapter, no upstream source code copied and no invented swarm counts.
"""
from urllib.parse import unquote, urlencode
from helpers import retrieve_url
from novaprinter import prettyPrinter
from opal_release_feed import rss_rows


class acgrip:
    url = 'https://acg.rip'
    name = 'ACG.RIP (Anime)'
    supported_categories = {'all': '', 'movies': '', 'tv': '', 'anime': ''}

    def search(self, what, cat='all'):
        query = unquote(what).strip()
        if not query or cat not in self.supported_categories:
            return
        body = retrieve_url(self.url.rstrip('/') + '/.xml?' + urlencode({'term': query}),
                            unescape_html_entities=False, attempts=1, max_bytes=4 * 1024 * 1024)
        for row in rss_rows(body, self.url, allow_torrent=True):
            prettyPrinter(row)
