# VERSION: 1.4
# AUTHORS: LightDestory (https://github.com/LightDestory)

import re
from time import sleep
from datetime import datetime

from helpers import retrieve_url
from novaprinter import prettyPrinter


class bitsearch(object):
    # bitsearch.to (and solidtorrents.to) 301 to bitsearch.eu since 2026.
    url = "https://bitsearch.eu/"
    name = "BitSearch"
    supported_categories = {
        "all": "",
        "movies": "2",
        "music": "7",
        "games": "6",
        "software": "5",
        "tv": "3",
        "anime": "4",
        "books": "9",
    }

    class HTMLParser:
        def __init__(self, url):
            self.url = url
            self.noTorrents = False

        def feed(self, html):
            self.noTorrents = False
            torrents = self.__findTorrents(html)
            resultSize = len(torrents)
            if resultSize == 0:
                self.noTorrents = True
                return
            for torrent in range(resultSize):
                data = {
                    "link": torrents[torrent][0],
                    "name": torrents[torrent][1],
                    "size": torrents[torrent][2],
                    "seeds": torrents[torrent][3],
                    "leech": torrents[torrent][4],
                    "engine_url": self.url,
                    "desc_link": torrents[torrent][5],
                    "pub_date": torrents[torrent][6],
                }
                prettyPrinter(data)

        # One independent, linear pattern per field. The old single pattern
        # chained eight lazy `.+?` groups; when the swarm-stats markup changed
        # (seeders/leechers moved into a nested <span data-swarm-field>) it no
        # longer matched and backtracked for minutes per card. `re` holds the
        # GIL throughout, so nova2's --timeout deadline could not fire either
        # and the whole torrent search hung.
        _CARD = re.compile(
            r'<div class="(?:torrent-result-card )?bg-white rounded-lg shadow-sm border border-gray-200 p-6 hover:shadow-md transition duration-150 ease-in-out">.*?<!-- Mobile')
        _TITLE = re.compile(r'<a href="(/torrent/[^"#]+)"[^>]*>\s*([^<]+?)\s*</a>')
        _MAGNET = re.compile(r'href="(magnet:\?[^"]+)"')
        _SIZE = re.compile(r'fa-download"></i>\s*<span>\s*([0-9.,]+ (?:TB|GB|MB|KB))\s*</span>')
        _DATE = re.compile(r'fa-calendar"></i>\s*<span>\s*([^<]+?)\s*</span>')
        # Optional nested <span data-swarm-field=...> (2026 swarm-stats markup).
        _SEEDS = re.compile(r'fa-arrow-up"></i>\s*(?:<span[^>]*>\s*){1,2}([0-9,.]+)')
        _LEECH = re.compile(r'fa-arrow-down"></i>\s*(?:<span[^>]*>\s*){1,2}([0-9,.]+)')

        def __findTorrents(self, html):
            torrents = []
            for card in self._CARD.findall(html):
                title, magnet = self._TITLE.search(card), self._MAGNET.search(card)
                size = self._SIZE.search(card)
                if not title or not magnet or not size:
                    continue
                seeds, leech = self._SEEDS.search(card), self._LEECH.search(card)
                date = self._DATE.search(card)
                try:
                    timestamp = int(datetime.strptime(date.group(1), "%m/%d/%Y").timestamp()) if date else -1
                except (ValueError, OverflowError):
                    timestamp = -1
                torrents.append([
                    magnet.group(1),
                    title.group(2),
                    size.group(1),
                    seeds.group(1) if seeds else "-1",
                    leech.group(1) if leech else "-1",
                    "{0}{1}".format(self.url[:-1], title.group(1)),
                    timestamp,
                ])
            return torrents

    def download_torrent(self, download_url):
        print(download_url + " " + download_url)

    def search(self, what, cat="all"):
        what = what.replace("%20", "+")
        cat = "" if cat == "all" else f"&category={self.supported_categories[cat]}"
        parser = self.HTMLParser(self.url)
        current_page = 1
        max_pages = 50
        while current_page <= max_pages:
            url = "{0}search?q={1}&page={2}{3}&sortBy=relevance".format(
                self.url, what, current_page, cat
            )
            html = re.sub(r"\s+", " ", retrieve_url(url)).strip()
            parser.feed(html)
            if parser.noTorrents:
                break
            current_page += 1
            sleep(3)
