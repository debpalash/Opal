# VERSION: 1.1
# AUTHORS: LightDestory (https://github.com/LightDestory)


import html as html_mod
import re
from urllib.parse import quote, unquote
from helpers import download_file, retrieve_url
from novaprinter import prettyPrinter
from time import sleep
from datetime import datetime


class torrentgalaxy(object):
    # torrentgalaxy.one stopped resolving (NXDOMAIN on public DNS, 2026-11).
    # torrentgalaxy.info serves the same get-posts listing.
    url = "https://torrentgalaxy.info/"
    MAX_PAGES = 2  # 50 rows each; the old loop walked every page, 3s apart
    name = "TorrentGalaxy"
    supported_categories = {
        "all": "",
        "movies": "Movies",
        "tv": "TV",
        "music": "Music",
        "games": "Games",
        "anime": "Anime",
        "software": "Apps",
        "books": "Books",
    }

    class HTMLParser:
        def __init__(self, url):
            self.url = url
            self.noTorrents = False

        def feed(self, html):
            self.noTorrents = False
            torrents = self.__findTorrents(html)
            if len(torrents) == 0:
                self.noTorrents = True
                return
            for torrent in range(len(torrents)):
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

        def __findTorrents(self, html):
            torrents = []
            trs = re.findall(
                r"<div class=\"tgxtablerow txlight\".+?</table>\s?</div>", html
            )
            base = self.url.rstrip("/")
            for tr in trs:
                # Each field is matched on its own. The old single regex took
                # "the first href after <b>" as the detail link, which is now
                # the IMDb badge, and never used the magnet the row carries.
                name = re.search(r"<b>(.+?)</b>", tr)
                detail = re.search(r"href=\"(/post-detail/[^\"]+)\"", tr)
                magnet = re.search(r"href=\"(magnet:\?xt=urn:btih:[^\"]+)\"", tr)
                size = re.search(r"([0-9][0-9,.]*\s?(?:TB|GB|MB|KB))", tr)
                peers = re.search(
                    r"Seeders/Leechers.+?<b>([0-9.,]+)</b>.+?<b>([0-9.,]+)</b>", tr
                )
                if not (name and size and (magnet or detail)):
                    continue
                desc = base + detail.group(1) if detail else base
                torrents.append([
                    html_mod.unescape(magnet.group(1)) if magnet else desc,
                    html_mod.unescape(re.sub(r"<[^>]+>", "", name.group(1))).strip(),
                    size.group(1),
                    peers.group(1).replace(",", "") if peers else -1,
                    peers.group(2).replace(",", "") if peers else -1,
                    desc,
                    -1,
                ])
            return torrents

    def download_torrent(self, info):
        torrent_page = re.sub(r"\s+", " ", retrieve_url(info)).strip()
        download_link = re.search(
            r"href=\"(https?://itorrents.+?)\?.+?\"", torrent_page
        )
        if download_link:
            print(download_file(download_link.groups(1)[0]))
        else:
            raise Exception("Download link not found")

    def search(self, what, cat="all"):
        cat = "" if cat == "all" else f":category:{self.supported_categories[cat]}"
        what = quote(unquote(what), safe="")
        parser = self.HTMLParser(self.url)
        for current_page in range(1, self.MAX_PAGES + 1):
            url = "{0}get-posts/keywords:{1}{2}/?page={3}".format(
                self.url, what, cat, current_page
            )
            html = re.sub(r"\s+", " ", retrieve_url(url, unescape_html_entities=False)).strip()
            parser.feed(html)
            if parser.noTorrents or "?page={0}".format(current_page + 1) not in html:
                break
            sleep(1)
