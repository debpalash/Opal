# VERSION: 1.0
# AUTHORS: Opal
"""FOSS Torrents: official torrents for free/open-source software and distros.

The site publishes one feed of every torrent it hosts and has no search API,
so the feed is fetched once and matched locally (every query word must appear).
Sizes and swarm counts are not in the feed and stay -1.
"""
import xml.etree.ElementTree as ET
from urllib.parse import unquote

from helpers import retrieve_url
from novaprinter import prettyPrinter
from opal_release_feed import MAX_BODY, MAX_ROWS, clean_title, provider_url
from opal_torrent_util import rfc822_epoch


class fosstorrents:
    url = 'https://fosstorrents.com'
    name = 'FOSS Torrents (Linux & open source)'
    supported_categories = {'all': '', 'software': '', 'games': ''}

    def search(self, what, cat='all'):
        words = unquote(what).lower().split()
        if not words or cat not in self.supported_categories:
            return
        base = self.url.rstrip('/')
        body = retrieve_url(base + '/feed/torrents.xml',
                            unescape_html_entities=False, max_bytes=MAX_BODY)
        if not body or '<!DOCTYPE' in body.upper() or '<!ENTITY' in body.upper():
            return
        try:
            root = ET.fromstring(body)
        except (ET.ParseError, ValueError):
            return
        seen, emitted = set(), 0
        for item in root.findall('./channel/item'):
            title = clean_title(item.findtext('title', ''))
            haystack = (title + ' ' + (item.findtext('description', '') or '')).lower()
            if not title or not all(word in haystack for word in words):
                continue
            link = provider_url((item.findtext('link', '') or '').strip(), base, torrent=True)
            if not link or link in seen:
                continue
            seen.add(link)
            prettyPrinter({
                'link': link, 'name': title, 'size': -1, 'seeds': -1, 'leech': -1,
                'engine_url': self.url, 'desc_link': base + '/',
                'pub_date': rfc822_epoch(item.findtext('pubDate', '')),
            })
            emitted += 1
            if emitted >= MAX_ROWS:
                break
