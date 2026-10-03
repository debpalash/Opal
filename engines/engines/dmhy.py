# VERSION: 1.0
# AUTHORS: Opal
"""DMHY public keyword RSS: actual magnets, unknown swarm counts remain -1.

Provider identified in Prowlarr/Indexers definitions/v11/dmhy.yml; implementation
is original and consumes the provider's RSS rather than copying GPL selectors.
"""
from urllib.parse import unquote, urlencode
from helpers import retrieve_url
from novaprinter import prettyPrinter
from opal_release_feed import rss_rows


class dmhy:
    url = 'https://share.dmhy.org'
    name = 'DMHY (Anime)'
    supported_categories = {'all': '', 'movies': '', 'tv': '', 'anime': ''}

    def search(self, what, cat='all'):
        query = unquote(what).strip()
        if not query or cat not in self.supported_categories:
            return
        body = retrieve_url(self.url.rstrip('/') + '/topics/rss/rss.xml?' + urlencode({'keyword': query}),
                            unescape_html_entities=False, attempts=1, max_bytes=4 * 1024 * 1024)
        for row in rss_rows(body, self.url):
            prettyPrinter(row)
