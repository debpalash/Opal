# VERSION: 1.0
# AUTHORS: Opal
"""FitGirl Repacks: the site's own WordPress search feed, which embeds each
repack's magnet link. Posts without a magnet (news, update digests) are skipped.
Swarm counts are not published there, so seeds/leech stay -1.
"""
import re
import xml.etree.ElementTree as ET
from urllib.parse import unquote, urlencode

from helpers import retrieve_url
from novaprinter import prettyPrinter
from opal_release_feed import MAX_BODY, canonical_magnet, clean_title, provider_url
from opal_torrent_util import rfc822_epoch, text_of

_CONTENT = '{http://purl.org/rss/1.0/modules/content/}encoded'
_MAGNET = re.compile(r'href="(magnet:\?xt=urn:btih:[^"]+)"', re.I)
_SIZE = re.compile(r'Repack Size:\s*(?:from\s*)?([\d.]+\s*[KMGT]B)', re.I)


class fitgirl:
    url = 'https://fitgirl-repacks.site'
    name = 'FitGirl Repacks (Games)'
    supported_categories = {'all': '', 'games': ''}

    def search(self, what, cat='all'):
        query = unquote(what).strip()
        if not query or cat not in self.supported_categories:
            return
        base = self.url.rstrip('/')
        body = retrieve_url(base + '/?' + urlencode({'s': query, 'feed': 'rss2'}),
                            unescape_html_entities=False, max_bytes=MAX_BODY)
        if not body or '<!DOCTYPE' in body.upper() or '<!ENTITY' in body.upper():
            return
        try:
            root = ET.fromstring(body)
        except (ET.ParseError, ValueError):
            return
        seen = set()
        for item in root.findall('./channel/item')[:50]:
            title = clean_title(item.findtext('title', ''))
            content = item.findtext(_CONTENT, '') or ''
            found = _MAGNET.search(content)
            magnet = canonical_magnet(clean_title(found.group(1)), title) if found else None
            if not title or not magnet or magnet[1] in seen:
                continue
            seen.add(magnet[1])
            size = _SIZE.search(text_of(content))
            # The magnet's own name carries the languages; fall back to the post title.
            name = magnet[2] if 'fitgirl' in magnet[2].lower() else title + ' [FitGirl Repack]'
            prettyPrinter({
                'link': magnet[0], 'name': name,
                'size': size.group(1) if size else -1,
                'seeds': -1, 'leech': -1, 'engine_url': self.url,
                'desc_link': provider_url(item.findtext('link', ''), base),
                'pub_date': rfc822_epoch(item.findtext('pubDate', '')),
            })
