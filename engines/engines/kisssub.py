# VERSION: 1.0
# AUTHORS: Opal
"""Kisssub / Comicat / MioBT keyword RSS (one site family, same feed shape).

Each item names its torrent by info hash (show-<hash>.html); the magnet is
built from that hash. The feed has no size or swarm counts, so they stay -1.
"""
import re
import xml.etree.ElementTree as ET
from urllib.parse import quote, unquote

from helpers import retrieve_url
from novaprinter import prettyPrinter
from opal_release_feed import MAX_BODY, MAX_ROWS, clean_title
from opal_torrent_util import magnet_from_hash, rfc822_epoch

_HASH = re.compile(r'(?<![a-f0-9])([a-f0-9]{40})(?![a-f0-9])', re.I)


class kisssub:
    url = 'https://www.kisssub.org'
    name = 'Kisssub (Anime)'
    supported_categories = {'all': '', 'anime': '', 'tv': '', 'movies': ''}

    def search(self, what, cat='all'):
        query = ' '.join(unquote(what).replace('/', ' ').split())
        if not query or cat not in self.supported_categories:
            return
        base = self.url.rstrip('/')
        body = retrieve_url(base + '/rss-' + quote(query, safe='') + '.xml',
                            unescape_html_entities=False, max_bytes=MAX_BODY)
        if not body or '<!DOCTYPE' in body.upper() or '<!ENTITY' in body.upper():
            return
        try:
            root = ET.fromstring(body)
        except (ET.ParseError, ValueError):
            return
        seen = set()
        for item in root.findall('./channel/item')[:MAX_ROWS]:
            title = clean_title(item.findtext('title', ''))
            enclosure = item.find('enclosure')
            found = _HASH.search(item.findtext('link', '') or '') or _HASH.search(
                enclosure.get('url', '') if enclosure is not None else '')
            if not title or not found:
                continue
            digest = found.group(1).lower()
            if digest in seen:
                continue
            seen.add(digest)
            prettyPrinter({
                'link': magnet_from_hash(digest, title), 'name': title, 'size': -1,
                'seeds': -1, 'leech': -1, 'engine_url': self.url,
                'desc_link': base + '/show-' + digest + '.html',
                'pub_date': rfc822_epoch(item.findtext('pubDate', '')),
            })
