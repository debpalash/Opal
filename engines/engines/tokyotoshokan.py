#VERSION: 2.4
#Author: Douman (douman@gmx.se)
#        Bruno Barbieri (brunorex@gmail.com)

try:
    #python3
    from html.parser import HTMLParser
except ImportError:
    #python2
    from HTMLParser import HTMLParser

import html as html_mod
import re
from re import compile as re_compile
from urllib.parse import quote_plus, unquote

#qBt
from novaprinter import prettyPrinter
from helpers import download_file, retrieve_url

class tokyotoshokan(object):
    name = 'Tokyo Toshokan'
    supported_categories = {'all': '0', 'anime': '1', 'games': '14'}
    # www.tokyotosho.info now answers search.php with a Cloudflare challenge;
    # the project's tokyo-tosho.net mirror serves the same listing unwalled.
    url = 'https://tokyo-tosho.net'
    MAX_PAGES = 2  # ~50 rows each; the old loop walked every page until timeout

    def __init__(self):
        self.name = 'Tokyo Toshokan'
        self.supported_categories = {'all': '0', 'anime': '1', 'games': '14' }
        #self.supported_categories = {'all': '0', 'anime': '1', 'anime(non-english)': '10',
        #                        'manga': '3', 'drama': '8', 'music': '2',
        #                        'music video': '9', 'raw': '7', 'hentai': '4',
        #                        'eroge': '14', 'batch': '11', 'jav': '15', 'other': '5'}
        #

    def download_torrent(self, info):
        print(download_file(info))

    class MyHtmlParseWithBlackJack(HTMLParser):
        def __init__(self, url):
            HTMLParser.__init__(self)
            self.get_size_regex = re_compile(r".*Size:\s+([^ ]*)\s+.*")
            self.url = url
            self.current_item = None
            self.size_found = False
            self.name_found = False
            self.stats_found = False
            self.stat_name = None
            self.skip_break = False

        def handle_starttag(self, tag, attrs):
            params = dict(attrs)
            if self.current_item:
                href = params.get("href") or ""
                if tag == "a":
                    if href.startswith("magnet"):
                        self.current_item["link"] = href
                    elif 'type' in params and params["type"] == "application/x-bittorrent":
                        self.name_found = True
                        self.current_item["name"] = ""
                    elif href.startswith("details"):
                        self.current_item["desc_link"] = "".join((self.url, "/", href))

                elif tag == "td" and "class" in params:
                    if params["class"] == "desc-bot":
                        self.size_found = True
                        self.current_item['size'] = 'Unknown'
                    elif params["class"] == "stats":
                        self.stats_found = True

                elif self.stats_found and tag == "span":
                    # S, L, then C(ompleted): the third span used to overwrite
                    # leech with the completed-download count.
                    if "seeds" not in self.current_item:
                        self.stat_name = "seeds"
                    elif "leech" not in self.current_item:
                        self.stat_name = "leech"
                elif self.name_found and tag == "span" and params.get("class") == "s":
                    self.skip_break = True  # line-break hint inside the title

            elif tag == "tr" and "class" in params:
                # Was `.find("category")` used as a boolean: 0 (class starts
                # with "category", every unshaded row) is falsy and -1 (no
                # match) is truthy, so half the listing was dropped.
                if "category" in params["class"]:
                    self.current_item = dict()
                    self.current_item["engine_url"] = self.url

        def handle_endtag(self, tag):
            if tag == "a":
                if self.name_found:
                    self.name_found = False
            elif tag == "span":
                self.stat_name = None
            elif self.current_item and tag == "tr" and len(self.current_item) == 7:
                prettyPrinter(self.current_item)
                self.current_item = None
                self.size_found = False
                self.name_found = False
                self.stats_found = False
                self.stat_name = None

        def handle_data(self, data):
            if self.name_found:
                if self.skip_break:
                    self.skip_break = False
                    if not data.strip():
                        return
                self.current_item["name"] += data
            elif self.size_found:
                # There can be several pieces.
                result = self.get_size_regex.search(data)
                if result:
                    self.current_item['size'] = result.group(1)
                    self.size_found = False
            elif self.stat_name:
                self.current_item[self.stat_name] = data

    LISTING_RE = re_compile(r"(?s)<table class=\"listing\">(.*)</table>")

    def listing(self, data):
        """The results table of a search page, or '' when there is none.

        A challenge page or an empty body has no listing table; the old code
        called `.group(0)` on the failed match and died with
        `AttributeError: 'NoneType' object has no attribute 'group'`.
        """
        match = self.LISTING_RE.search(data or "")
        return match.group(0) if match else ""

    def rss_rows(self, body):
        """Rows from rss.php -- no swarm counts, but it is not behind the wall
        that search.php sits behind on the main domain."""
        rows = []
        for item in re.findall(r"(?s)<item>(.*?)</item>", body or ""):
            title = re.search(r"(?s)<title>(.*?)</title>", item)
            magnet = re.search(r"href=\"(magnet:\?xt=urn:btih:[^\"]+)\"", item)
            if not title or not magnet:
                continue
            name = html_mod.unescape(title.group(1).replace("<![CDATA[", "").replace("]]>", ""))
            name = " ".join(name.split())
            if not name:
                continue
            size = re.search(r"Size:\s*([0-9.]+\s*[KMGT]?i?B)", item)
            details = re.search(r"href=\"(https?://[^\"]*details\.php\?id=\d+)\"", item)
            rows.append({
                "link": html_mod.unescape(magnet.group(1)),
                "name": name,
                "size": size.group(1) if size else "-1",
                "seeds": -1,
                "leech": -1,
                "engine_url": self.url,
                "desc_link": details.group(1) if details else self.url,
            })
        return rows

    def search(self, query, cat='all'):
        query = quote_plus(unquote(query))
        category = self.supported_categories.get(cat, '0')
        parser = self.MyHtmlParseWithBlackJack(self.url)
        request_url = '{0}/search.php?terms={1}&type={2}&size_min=&size_max=&username='.format(self.url, query, category)

        first = self.listing(retrieve_url(request_url))
        if first:
            parser.feed(first)
            # Page links look like `?lastid=N&page=2&terms=...`; lastid pins the
            # result set, so take it from the page rather than guessing.
            for page in range(2, self.MAX_PAGES + 1):
                link = re.search(r"\?lastid=[0-9]+&(?:amp;)?page={0}&[^\"']*".format(page), first)
                if not link:
                    break
                more = self.listing(retrieve_url("".join((self.url, "/search.php", html_mod.unescape(link.group(0))))))
                if not more:
                    break
                parser.feed(more)
            parser.close()
            return

        feed = retrieve_url('{0}/rss.php?terms={1}&type={2}&searchName=true'.format(self.url, query, category),
                            unescape_html_entities=False)
        for row in self.rss_rows(feed):
            prettyPrinter(row)
