# VERSION: 1.0
# AUTHORS: Opal
"""AniRena public keyword RSS: real .torrent enclosures and provider sizes.

The feed carries no swarm counts, so seeds/leech stay -1 (unknown).
"""
import re
import xml.etree.ElementTree as ET
from urllib.parse import unquote, urlencode

from helpers import retrieve_url
from novaprinter import prettyPrinter
from opal_release_feed import MAX_BODY, MAX_ROWS, clean_title, provider_url
from opal_torrent_util import rfc822_epoch

_SIZE = re.compile(r'Size:\s*([\d.]+\s*[KMGT]?i?B)', re.I)
_CATEGORY_PREFIX = re.compile(r'^\[[^\]]*>[^\]]*\]\s*')


class anirena:
    url = 'https://www.anirena.com'
    name = 'AniRena (Anime)'
    supported_categories = {'all': '', 'anime': '', 'tv': '', 'movies': ''}

    def search(self, what, cat='all'):
        query = unquote(what).strip()
        if not query or cat not in self.supported_categories:
            return
        base = self.url.rstrip('/')
        body = retrieve_url(base + '/rss?' + urlencode({'s': query}),
                            unescape_html_entities=False, max_bytes=MAX_BODY)
        if not body or '<!DOCTYPE' in body.upper() or '<!ENTITY' in body.upper():
            return
        try:
            root = ET.fromstring(body)
        except (ET.ParseError, ValueError):
            return
        seen = set()
        for item in root.findall('./channel/item')[:MAX_ROWS]:
            enclosure = item.find('enclosure')
            # The feed prefixes every title with "[Category > Subcategory] ".
            title = _CATEGORY_PREFIX.sub('', clean_title(item.findtext('title', '')))
            link = provider_url(enclosure.get('url', ''), base, torrent=True) if enclosure is not None else ''
            if not title or not link or link in seen:
                continue
            seen.add(link)
            size = _SIZE.search(item.findtext('description', '') or '')
            prettyPrinter({
                'link': link, 'name': title, 'size': size.group(1) if size else -1,
                'seeds': -1, 'leech': -1, 'engine_url': self.url,
                'desc_link': provider_url(item.findtext('link', ''), base),
                'pub_date': rfc822_epoch(item.findtext('pubDate', '')),
            })
