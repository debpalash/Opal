# VERSION: 1.5
# AUTHORS: BurningMop (burning.mop@yandex.com)

# LICENSING INFORMATION
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

import json
import re
from html.parser import HTMLParser
from urllib.parse import quote, unquote, urlencode
from helpers import download_file, retrieve_url
from novaprinter import prettyPrinter, anySizeToBytes

MAGNET_RE = r'href=["\']magnet:.+?["\']'


def detail_url(base, href):
    """Join a listing href onto the site base without doubling the slash.

    hrefs come through as `/post-detail/...`, so the naive f'{base}/{href}'
    produced `https://therarbg.com//post-detail/...`.
    """
    return '{}/{}'.format(base.rstrip('/'), (href or '').lstrip('/'))


def first_magnet(html):
    """First magnet URI in a detail page, or None when there isn't one.

    Returning None rather than raising is the whole point: this runs inside an
    HTMLParser callback, so an IndexError here aborts the feed and throws away
    every row already parsed -- one unresolvable magnet zeroed a 50-row page.
    """
    for match in re.finditer(MAGNET_RE, html or '', re.MULTILINE):
        parts = re.split(r'["\']', match.group())
        if len(parts) > 1 and parts[1]:
            return parts[1]
    return None


class therarbg(object):
    url = 'https://therarbg.com'
    name = 'The RarBg'
    supported_categories = {
        'all':'All', 
        'movies':'Movies', 
        'tv': 'TV', 
        'music':'Music', 
        'games':'Games', 
        'anime':'Anime', 
        'software':'Apps'
        }
    
    class MyHtmlParser(HTMLParser):
    
        def error(self, message):
            pass
    
        DIV, TABLE, TBODY, TR, TD, A, SPAN, I, B = ('div', 'table', 'tbody', 'tr', 'td', 'a', 'span', 'i', 'b')
    
        def __init__(self, url):
            HTMLParser.__init__(self)
            self.magnet_regex = r'href=["\']magnet:.+?["\']'

            self.url = url
            self.row = {}
            self.column = 0

            self.foundTable = False
            self.foundTableTbody = False
            self.insideRow = False
            self.insideCell = False

            self.shouldParseName = False
            self.shouldGetCategory = False
            self.shouldGetSize = False
            self.shouldGetSeeds = False
            self.shouldGetLeechs = False

            self.alreadyParseName = False
            self.alreadyParsesLink = False

        def handle_starttag(self, tag, attrs):
            params = dict(attrs)
            cssClasses = params.get('class', '')
            elementId = params.get('id', '')

            if tag == self.TABLE:
                self.foundTable = True

            if tag == self.TBODY and self.foundTable:
                self.foundTableTbody = True

            if tag == self.TR and self.foundTableTbody:
                self.column = 0
                self.insideRow = True

            if tag == self.TD and self.insideRow:
                self.column += 1
                self.insideCell = True

            if self.insideCell:
                if self.column == 2 and tag == self.A and not self.alreadyParseName :
                    self.shouldParseName = True
                    href = params.get('href')
                    link = detail_url(self.url, href)
                    self.row['desc_link'] = link

                    # A dead detail fetch drops this one row; it must never
                    # escape into feed() and take the other 49 with it.
                    # attempts=1: this fires once per row, so retrying here
                    # would multiply a whole page's latency to save one row.
                    try:
                        magnet = first_magnet(retrieve_url(link, attempts=1))
                    except Exception:
                        magnet = None
                    if magnet:
                        self.row['link'] = magnet

                if self.column == 3 and tag == self.A:
                    self.shouldGetCategory = True                 

                if self.column == 6:
                    self.shouldGetSize = True

                if self.column == 7:
                    self.shouldGetSeeds = True

                if self.column == 8:
                    self.shouldGetLeechs = True                    

        def handle_data(self, data):
            if self.shouldParseName:
                self.row['name'] = data
                self.shouldParseName = False
                self.alreadyParseName = True

            if self.shouldGetCategory:
                self.row['name'] += f' ({data.strip()})'
                self.shouldGetCategory = False

            if self.shouldGetSize:
                self.row['size'] = data.replace(',', '.').replace('\xa0', ' ')
                self.shouldGetSize = False

            if self.shouldGetSeeds:    
                self.row['seeds']  = data
                self.shouldGetSeeds = False

            if self.shouldGetLeechs:    
                self.row['leech']  = data
                self.shouldGetLeechs = False

        def handle_endtag(self, tag):
            if tag == self.TD:
                self.insideCell = False

            if tag == self.TR and self.foundTableTbody:
                self.row['engine_url'] = self.url
                # Skip rows whose magnet never resolved, and rows the listing
                # left half-parsed -- prettyPrinter KeyErrors on a missing key,
                # which would abort the feed just as the IndexError used to.
                if all(self.row.get(k) for k in ('link', 'name', 'size', 'seeds', 'leech')):
                    prettyPrinter(self.row)
                self.column = 0
                self.row = {}
                self.insideRow = False
                self.alreadyParseName = False


    def download_torrent(self, info):
        print(download_file(info))

    TRACKERS = (
        'udp://tracker.opentrackr.org:1337/announce',
        'udp://open.stealth.si:80/announce',
        'udp://tracker.torrent.eu.org:451/announce',
        'udp://exodus.desync.com:6969/announce',
    )
    MAX_PAGES = 2  # 50 rows per JSON page

    def getPageUrl(self, what, cat, page, fmt=''):
        base = self.url.rstrip('/')
        if not cat == 'All':
            return f'{base}/get-posts/order:-se:category:{cat}:keywords:{what}{fmt}/?page={page}'
        else:
            return f'{base}/get-posts/order:-se:keywords:{what}{fmt}/?page={page}'

    def json_rows(self, body):
        """Rows from one `:format:json` listing page, plus whether more follow.

        The listing HTML carries no magnet, so the old engine fetched one detail
        page per row (100 extra requests per page) and gated the whole page on a
        `<title>Search for` that the site no longer serves -- zero rows. The
        JSON listing has the info-hash inline: one request per 50 rows.
        """
        try:
            data = json.loads(body)
        except (TypeError, ValueError):
            return [], False
        if not isinstance(data, dict) or not isinstance(data.get('results'), list):
            return [], False
        base = self.url.rstrip('/')
        rows = []
        for item in data['results']:
            if not isinstance(item, dict):
                continue
            name, digest = item.get('n'), item.get('h')
            if not isinstance(name, str) or not name.strip():
                continue
            if not isinstance(digest, str) or not re.fullmatch(r'[a-fA-F0-9]{40}', digest):
                continue
            name = ' '.join(name.split())
            category = item.get('c')
            params = [('dn', name)] + [('tr', t) for t in self.TRACKERS]
            row = {
                'link': 'magnet:?xt=urn:btih:{}&{}'.format(digest.lower(), urlencode(params)),
                'name': f'{name} ({category})' if isinstance(category, str) and category else name,
                'size': self._count(item.get('s')),
                'seeds': self._count(item.get('se')),
                'leech': self._count(item.get('le')),
                'engine_url': self.url,
                'desc_link': detail_url(base, 'post-detail/{}/'.format(quote(str(item.get('pk', '')), safe=''))),
            }
            added = self._count(item.get('a'))
            if added > 0:
                row['pub_date'] = added
            rows.append(row)
        links = data.get('links')
        return rows, bool(isinstance(links, dict) and links.get('next'))

    @staticmethod
    def _count(value):
        if isinstance(value, bool):
            return -1
        try:
            number = int(value)
        except (TypeError, ValueError):
            return -1
        return number if number >= 0 else -1

    def search(self, what, cat='all'):
        search_category = self.supported_categories.get(cat, 'All')
        # nova2 hands the query over percent-encoded; normalise so it is encoded
        # exactly once whatever the caller did.
        what = quote(unquote(what), safe='')
        found = 0
        for page in range(1, self.MAX_PAGES + 1):
            body = retrieve_url(self.getPageUrl(what, search_category, page, ':format:json'),
                                unescape_html_entities=False)
            rows, more = self.json_rows(body)
            for row in rows:
                prettyPrinter(row)
            found += len(rows)
            if not rows or not more:
                break
        if found:
            return
        # JSON listing unavailable (older mirror): one HTML page, magnets
        # resolved per row by the parser above.
        retrievedHtml = retrieve_url(self.getPageUrl(what, search_category, 1))
        if retrievedHtml:
            parser = self.MyHtmlParser(self.url)
            parser.feed(retrievedHtml)
            parser.close()
