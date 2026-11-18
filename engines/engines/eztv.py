# VERSION: 1.25
# AUTHORS: nindogo
# CONTRIBUTORS: Diego de las Heras (ngosang@hotmail.es)

import http.client
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from html.parser import HTMLParser
from typing import Callable, Dict, List, Mapping, Match, Optional, Tuple, Union
from urllib.parse import quote, unquote

from helpers import retrieve_url
from novaprinter import prettyPrinter


class eztv:
    name = "EZTV"
    url = 'https://eztvx.to/'
    supported_categories = {'all': 'all', 'tv': 'tv'}

    class MyHtmlParser(HTMLParser):
        A, TD, TR, TABLE = ('a', 'td', 'tr', 'table')

        """ Sub-class for parsing results """
        def __init__(self, url: str) -> None:
            HTMLParser.__init__(self)
            self.url = url

            now = datetime.now()
            self.date_parsers: Mapping[str, Callable[[Match[str]], datetime]] = {
                r"(\d+)h\s+(\d+)m": lambda m: now - timedelta(hours=int(m[1]), minutes=int(m[2])),
                r"(\d+)d\s+(\d+)h": lambda m: now - timedelta(days=int(m[1]), hours=int(m[2])),
                r"(\d+)\s+weeks?": lambda m: now - timedelta(weeks=int(m[1])),
                r"(\d+)\s+mo": lambda m: now - timedelta(days=int(m[1]) * 30),
                r"(\d+)\s+years?": lambda m: now - timedelta(days=int(m[1]) * 365),
            }
            self.in_table_row = False
            self.current_item: Dict[str, object] = {}
            self.rows = 0

        def handle_starttag(self, tag: str, attrs: List[Tuple[str, Union[str, None]]]) -> None:
            def getStr(d: Mapping[str, Union[str, None]], key: str) -> str:
                value = d.get(key, '')
                return value if value is not None else ''

            params = dict(attrs)

            if (params.get('class') == 'forum_header_border'
                    and params.get('name') == 'hover'):
                self.in_table_row = True
                self.current_item = {}
                self.current_item['seeds'] = -1
                self.current_item['leech'] = -1
                self.current_item['size'] = -1
                self.current_item['engine_url'] = self.url
                self.current_item['pub_date'] = -1

            if (tag == self.A
                    and self.in_table_row and params.get('class') == 'magnet'):
                self.current_item['link'] = params.get('href')

            if (tag == self.A
                    and self.in_table_row and params.get('class') == 'epinfo'):
                self.current_item['desc_link'] = self.url + getStr(params, 'href')
                self.current_item['name'] = getStr(params, 'title').split(' (')[0]

        def handle_data(self, data: str) -> None:
            data = data.replace(',', '')
            if (self.in_table_row
                    and (data.endswith(' KB') or data.endswith(' MB') or data.endswith(' GB'))):
                self.current_item['size'] = data

            elif self.in_table_row and data.isnumeric():
                self.current_item['seeds'] = int(data)

            elif self.in_table_row:  # Check for a relative time
                for pattern, calc in self.date_parsers.items():
                    m = re.match(pattern, data)
                    if m:
                        self.current_item["pub_date"] = int(calc(m).timestamp())
                        break

        def handle_endtag(self, tag: str) -> None:
            if self.in_table_row and tag == self.TR:
                prettyPrinter(self.current_item)  # type: ignore[arg-type] # refactor later
                self.rows += 1
                self.in_table_row = False

    def do_query(self, what: str) -> str:
        url = f"{self.url}/search/{what.replace('%20', '-')}"
        data = b"layout=def_wlinks"
        # No hand-rolled fallback. This used to drop to a bare urllib.urlopen when
        # retrieve_url raised TypeError ("older versions did not support
        # request_data") -- ours has supported it for years, so that branch was
        # dead weight that would silently bypass the retry, the per-attempt
        # deadline and the anti-block browser fallback if it ever fired again.
        return retrieve_url(url, request_data=data)

    def search(self, what: str, cat: str = 'all') -> None:
        eztv_html = self.do_query(what)

        eztv_parser = self.MyHtmlParser(self.url)
        eztv_parser.feed(eztv_html)
        eztv_parser.close()
        if eztv_parser.rows == 0:
            self.search_api(what)

    # ── JSON API fallback ────────────────────────────────────────────────────
    #
    # Every EZTV mirror now answers /search/ with a Cloudflare "Just a moment"
    # challenge (403), so the HTML path yields nothing unless Opal's browser
    # fallback is up. The site's own JSON API is not walled, but it only takes
    # an IMDb id -- so the show name is resolved through TVMaze (keyless, and
    # already what Opal's TV pages use) and the episodes are filtered locally.

    TVMAZE = 'https://api.tvmaze.com/singlesearch/shows?q='
    _NOISE = re.compile(
        r'^(?:s\d{1,2}(?:e\d{1,3})?|e\d{1,3}|\d{1,2}x\d{1,3}|\d{3,4}p|(?:19|20)\d{2}|'
        r'season|episode|complete|x26[45]|h26[45]|hevc|avc|web|webrip|web-?dl|hdtv|'
        r'bluray|brrip|hdr|uhd|4k|aac|proper|repack)$')

    @classmethod
    def split_query(cls, what: str) -> Tuple[str, Optional[int], Optional[int], List[str]]:
        """(show title, season, episode, other required tokens) from a search.

        'severance s02e01 1080p' -> ('severance', 2, 1, ['1080p'])
        """
        tokens = re.findall(r"[a-z0-9']+", unquote(what).replace('+', ' ').lower())
        title: List[str] = []
        required: List[str] = []
        season: Optional[int] = None
        episode: Optional[int] = None
        i = 0
        while i < len(tokens):
            tok = tokens[i]
            nxt = tokens[i + 1] if i + 1 < len(tokens) else ''
            m = re.fullmatch(r's(\d{1,2})(?:e(\d{1,3}))?', tok) or re.fullmatch(r'(\d{1,2})x(\d{1,3})', tok)
            if m:
                season = int(m.group(1))
                if m.group(2):
                    episode = int(m.group(2))
            elif tok in ('season', 'episode') and nxt.isdigit():
                if tok == 'season':
                    season = int(nxt)
                else:
                    episode = int(nxt)
                i += 1
            elif re.fullmatch(r'e\d{1,3}', tok) and season is not None:
                episode = int(tok[1:])
            elif cls._NOISE.match(tok) and title:
                # A year only narrows the show lookup; release names omit it.
                if not re.fullmatch(r'(?:19|20)\d{2}', tok):
                    required.append(tok)
            else:
                title.append(tok)
            i += 1
        return ' '.join(title), season, episode, required

    @staticmethod
    def api_rows(body: str, season: Optional[int], episode: Optional[int],
                 required: List[str], engine_url: str) -> Tuple[List[Dict[str, object]], int]:
        """(matching result rows, torrents on the page) from one API response."""
        try:
            torrents = json.loads(body).get('torrents') or []
        except (ValueError, AttributeError):
            return [], 0
        if not isinstance(torrents, list):
            return [], 0

        def num(value: object) -> int:
            try:
                return max(-1, int(str(value)))
            except (TypeError, ValueError):
                return -1

        rows: List[Dict[str, object]] = []
        for t in torrents:
            if not isinstance(t, dict):
                continue
            magnet, name = t.get('magnet_url'), t.get('title') or t.get('filename')
            if (not isinstance(magnet, str) or not magnet.startswith('magnet:?')
                    or not isinstance(name, str) or not name.strip()):
                continue
            if season is not None and num(t.get('season')) != season:
                continue
            if episode is not None and num(t.get('episode')) != episode:
                continue
            # `required` carries the show-title words too: TVMaze matches
            # fuzzily, and a wrong show must not surface as results.
            words = set(re.findall(r'[a-z0-9]+', (name + ' ' + str(t.get('filename') or ''))
                                   .lower().replace("'", '')))
            if any(tok.replace('-', '').replace("'", '') not in words for tok in required):
                continue
            rows.append({'link': magnet, 'name': ' '.join(name.split()),
                         'size': num(t.get('size_bytes')), 'seeds': num(t.get('seeds')),
                         'leech': num(t.get('peers')), 'engine_url': engine_url,
                         'desc_link': '', 'pub_date': num(t.get('date_released_unix'))})
        return rows, len(torrents)

    def search_api(self, what: str) -> None:
        title, season, episode, required = self.split_query(what)
        if not title:
            return
        try:
            imdb = (json.loads(retrieve_url(self.TVMAZE + quote(title))).get('externals') or {}).get('imdb')
        except (ValueError, AttributeError):
            return
        if not isinstance(imdb, str) or not re.fullmatch(r'tt\d{5,10}', imdb):
            return
        narrowed = season is not None or episode is not None or bool(required)
        for page in range(1, 6):
            body = retrieve_url('{0}/api/get-torrents?imdb_id={1}&limit=100&page={2}'.format(
                self.url.rstrip('/'), imdb[2:], page), unescape_html_entities=False)
            rows, on_page = self.api_rows(body, season, episode, required + title.split(), self.url)
            for row in rows:
                prettyPrinter(row)  # type: ignore[arg-type]
            # A plain show search is answered by the newest page; an episode
            # search walks back until it is found (bounded at 500 torrents).
            if on_page < 100 or rows or not narrowed:
                break
