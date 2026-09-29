# VERSION: 1.0
# AUTHORS: Opal
"""Shana Project episode search. Torrent links; unknown swarm counts stay -1."""
import html
import re
from urllib.parse import unquote, urlencode

from helpers import retrieve_url
from novaprinter import prettyPrinter


def text(raw):
    return ' '.join(html.unescape(re.sub(r'<[^>]+>', ' ', raw)).split())


def field(row, name):
    match = re.search(r'class="' + re.escape(name) + r'(?: [^"]*)?"[^>]*>(.*?)</div>', row, re.S)
    return text(match.group(1)) if match else ''


class shanaproject:
    url = 'https://www.shanaproject.com'
    name = 'Shana Project (Anime)'
    supported_categories = {'all': '', 'movies': '', 'tv': ''}

    def search(self, what, cat='all'):
        words = unquote(what).strip()
        if not words or cat not in self.supported_categories:
            return
        url = f'{self.url}/search/?{urlencode({"title": words})}'
        body = retrieve_url(url, unescape_html_entities=False)
        rows = re.split(r'<div id="rel\d+" class="release_block">', body)[1:]
        for row in rows[:50]:
            download = re.search(r'href="(/download/\d+/)"', row)
            series = field(row, 'release_title')
            if not download or not series:
                continue
            episode, subber = field(row, 'release_episode'), field(row, 'release_subber')
            size = field(row, 'release_size') or '-1'
            prettyPrinter({
                'link': self.url.rstrip('/') + download.group(1),
                'name': f'[{subber}] {series} - {episode}'.strip(),
                'size': size, 'seeds': -1, 'leech': -1,
                'engine_url': self.url, 'desc_link': url,
            })
