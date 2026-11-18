# VERSION: 1.7
# AUTHORS: LightDestory (https://github.com/LightDestory) achernet (https://github.com/achernet)
import concurrent.futures
import re
import sys
import xml.etree.ElementTree as ET
from datetime import date, datetime
from pathlib import Path
from urllib import request

from helpers import retrieve_url, download_file
from novaprinter import prettyPrinter, SearchResults

DATABASE_URL = "https://academictorrents.com/database.xml"
MAX_RESULTS = 40       # rows per search; each costs one detail-page fetch
DETAIL_WORKERS = 8
DETAIL_DEADLINE = 12   # seconds for all detail fetches together
home = str(Path.home())
system_paths = {
    "win32": f"{home}/AppData/Roaming",
    "linux": f"{home}/.local/share",
    "darwin": f"{home}/Library/Application Support",
}
cache_path = Path(f"{system_paths[sys.platform]}/qbit_plugins_data/academic_cache.xml")


class academictorrents(object):
    url = "https://academictorrents.com/"
    name = "AcademicTorrents"
    """ 
    ***TLDR; It is safer to force an 'all' research***
        AcademicTorrents categories are very specific
        qBittorrent does not provide enough categories to implement a good filtering.
    """
    supported_categories = {"all": "0"}

    def __init__(self, output=True):
        self.output = output
        self.filters = []

    def _torrent_filter(self, item) -> bool:
        """Every query term must appear, in the title or the description.

        This was an OR: one matching term was enough. Academic dataset
        descriptions are long prose, so a common word carried the whole
        catalogue -- searching "Spider-Man: Brand New Day" returned 25 rows of
        Crossref data files, MIT lecture videos and Wikipedia dumps, because
        "new" and "day" appear somewhere in almost every description. A
        multi-word query means all of the words; AND is what the user asked for.

        Empty terms are dropped first: `"" in title` is always True, so a query
        with a trailing or doubled space matched EVERY item even under AND.
        """
        terms = [f for f in self.filters if f]
        if not terms:
            return False
        title: str = (item.findtext("title") or "").lower()
        desc: str = (item.findtext("description") or "").lower()
        for f in terms:
            if f not in title and f not in desc:
                return False
        return True

    def _retrieve_database(self):
        folder_path = Path(f"{system_paths[sys.platform]}/qbit_plugins_data")
        if not folder_path.exists():
            folder_path.mkdir()
        self._update_database_cache()
        with open(cache_path, encoding="utf-8") as f:
            lines = f.readlines()[1:]
            return ET.fromstring("".join(lines))

    def _update_database_cache(self):
        if cache_path.exists():
            current_date = str(date.today())
            with open(cache_path, encoding="utf-8") as f:
                saved_date = f.readline().rstrip()
                if current_date == saved_date:
                    return
        # Through helpers: this is a multi-MB download that ran with no retry and
        # no socket deadline, so a stalled mirror hung the engine outright.
        db_local_text = retrieve_url(DATABASE_URL, unescape_html_entities=False)
        if not db_local_text:
            return  # leave any existing cache in place rather than truncating it
        f = open(cache_path, "w", encoding="utf-8")
        f.write(f"{str(date.today())}\n")
        f.write(db_local_text)
        f.close()

    def resolve_search_result(self, torrent) -> SearchResults:
        data = {
            "link": f"{self.url}download/{torrent.findtext('infohash')}.torrent",
            "name": torrent.findtext("title"),
            "size": torrent.findtext("size"),
            "engine_url": self.url,
            "desc_link": torrent.findtext("link"),
        }
        # attempts=1: one fetch per row, so a retry multiplies the whole search.
        torrent_desc = retrieve_url(f"{data['desc_link']}/tech", attempts=1)
        peer_data = re.search(
            "<tr><td>Mirrors</td><td>(\\d+)\\s*complete,\\s*(\\d+)\\s*downloading",
            torrent_desc,
        )
        if peer_data:
            data["seeds"] = int(peer_data.group(1))
            data["leech"] = int(peer_data.group(2))
        else:
            data["leech"] = -1
            data["seeds"] = -1
        added_date_data = re.search(
            "<tr><td>Added</td><td>([^<]+)</td></tr>", torrent_desc
        )
        try:
            data["pub_date"] = int(datetime.fromisoformat(added_date_data.group(1)).timestamp())
        except (AttributeError, ValueError):
            data["pub_date"] = -1  # detail page missing or reshaped: keep the row
        return SearchResults(**data)

    def basic_result(self, torrent) -> SearchResults:
        """The row the catalogue alone supports, for when the detail page is slow."""
        return SearchResults(
            link=f"{self.url}download/{torrent.findtext('infohash')}.torrent",
            name=torrent.findtext("title"), size=torrent.findtext("size"),
            seeds=-1, leech=-1, engine_url=self.url,
            desc_link=torrent.findtext("link"), pub_date=-1)

    def select(self, items):
        """At most MAX_RESULTS matches, title matches before description-only.

        Every match used to get its own detail-page fetch with no cap: a broad
        term matched hundreds of datasets and the engine ran until nova2 killed
        it at the timeout.
        """
        terms = [f for f in self.filters if f]
        in_title, in_desc = [], []
        for item in items:
            if not self._torrent_filter(item):
                continue
            title = (item.findtext("title") or "").lower()
            (in_title if all(f in title for f in terms) else in_desc).append(item)
        return (in_title + in_desc)[:MAX_RESULTS]

    def download_torrent(self, info):
        print(download_file(info))

    def search(self, what, cat="all"):
        self.filters = [f.lower() for f in re.split("%20|\\s", str(what))]
        db = self._retrieve_database()
        chosen = self.select(db.findall("channel/item"))
        if not chosen:
            return
        executor = concurrent.futures.ThreadPoolExecutor(max_workers=DETAIL_WORKERS)
        futures = {executor.submit(self.resolve_search_result, t): t for t in chosen}
        done, pending = concurrent.futures.wait(futures, timeout=DETAIL_DEADLINE)
        for future in futures:  # catalogue order, not completion order
            torrent = futures[future]
            try:
                result = future.result() if future in done else self.basic_result(torrent)
            except Exception:
                result = self.basic_result(torrent)
            if self.output and result.get("name") and result.get("size"):
                prettyPrinter(result)
        for future in pending:
            future.cancel()
        executor.shutdown(wait=False)
