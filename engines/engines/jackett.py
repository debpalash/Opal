# VERSION: 4.9
# AUTHORS: Diego de las Heras (ngosang@hotmail.es)
# CONTRIBUTORS: ukharley
#               hannsen (github.com/hannsen)
#               Alexander Georgievskiy <galeksandrp@gmail.com>

import json
import os
import sys
import urllib.request
import xml.etree.ElementTree
from datetime import datetime
from http.cookiejar import CookieJar
from multiprocessing.dummy import Pool
from threading import Lock
from typing import Any, Dict, List, Tuple, Union
from urllib.parse import unquote, urlencode

import helpers
from novaprinter import prettyPrinter


###############################################################################
class ProxyManager:
    HTTP_PROXY_KEY = "http_proxy"
    HTTPS_PROXY_KEY = "https_proxy"

    def __init__(self) -> None:
        self.http_proxy = os.environ.get(self.HTTP_PROXY_KEY, "")
        self.https_proxy = os.environ.get(self.HTTPS_PROXY_KEY, "")

    def enable_proxy(self, enable: bool) -> None:
        # http proxy
        if enable:
            os.environ[self.HTTP_PROXY_KEY] = self.http_proxy
            os.environ[self.HTTPS_PROXY_KEY] = self.https_proxy
        else:
            os.environ.pop(self.HTTP_PROXY_KEY, None)
            os.environ.pop(self.HTTPS_PROXY_KEY, None)

        # SOCKS proxy
        # best effort and avoid breaking older qbt versions
        try:
            helpers.enable_socks_proxy(enable)
        except AttributeError:
            pass


# initialize it early to ensure env vars were not tampered
proxy_manager = ProxyManager()
proxy_manager.enable_proxy(False)  # off by default


###############################################################################
# load configuration
#
# Opal change: this engine used to read ONLY engines/engines/jackett.json, while
# the Plugins page wrote ~/.config/opal/plugins/sources/jackett.json — a file it
# never opened. Install appeared to succeed and changed nothing. The user config
# now wins, so the Install button controls what it appears to; the in-repo file
# stays as a fallback for an existing hand-edited setup.
#
# Key names: the Plugins page writes {base, apikey} (the endpoint names every
# other Opal source uses); this engine historically wanted {url, api_key}. Both
# spellings are accepted, so neither side has to know about the other.
import opal_sources  # noqa: E402  (engines/ is on sys.path, added by nova2.py)

SOURCE_ID = 'jackett'
LEGACY_CONFIG_PATH = os.path.join(os.path.dirname(os.path.realpath(__file__)), 'jackett.json')
CONFIG_PATH = os.path.join(opal_sources.sources_dir(), SOURCE_ID + '.json')
CONFIG_DATA: Dict[str, Any] = {
    'api_key': 'YOUR_API_KEY_HERE',  # jackett api
    'url': 'http://127.0.0.1:9117',  # jackett url
    'tracker_first': False,          # (False/True) add tracker name to beginning of search result
    'thread_count': 20,              # number of threads to use for http requests
}
PRINTER_THREAD_LOCK = Lock()


def load_configuration() -> None:
    global CONFIG_DATA
    loaded: Dict[str, Any] = opal_sources.load(SOURCE_ID)
    if not loaded:
        try:
            with open(LEGACY_CONFIG_PATH, encoding='utf-8') as f:
                loaded = json.load(f)
        except ValueError:
            CONFIG_DATA['malformed'] = True
            return
        except Exception:  # pylint: disable=broad-exception-caught
            loaded = {}
    # NOTE: no file is written back. Creating the user file here would make the
    # source look INSTALLED to the Plugins page and to nova2's install gate
    # without the user ever asking for it.

    # Accept Opal's endpoint names as aliases of this engine's historical ones.
    if 'url' not in loaded and 'base' in loaded:
        loaded['url'] = loaded['base']
    if 'api_key' not in loaded and 'apikey' in loaded:
        loaded['api_key'] = loaded['apikey']

    for key, default in (('api_key', ''), ('url', ''), ('tracker_first', False), ('thread_count', 20)):
        if key not in loaded:
            loaded[key] = default
    if not loaded['url'] or not loaded['api_key']:
        loaded['malformed'] = True
    CONFIG_DATA = loaded  # pyright: ignore [reportConstantRedefinition]


load_configuration()
###############################################################################


class jackett:
    name = 'Jackett'
    url = (CONFIG_DATA['url'] or '').rstrip('/')
    api_key = CONFIG_DATA['api_key']
    thread_count = CONFIG_DATA['thread_count']
    supported_categories = {
        'all': None,
        'anime': ['5070'],
        'books': ['8000'],
        'games': ['1000', '4000'],
        'movies': ['2000'],
        'music': ['3000'],
        'software': ['4000'],
        'tv': ['5000'],
    }

    def download_torrent(self, download_url: str) -> None:
        # fix for some indexers with magnet link inside .torrent file
        if download_url.startswith('magnet:?'):
            print(download_url + " " + download_url)
        proxy_manager.enable_proxy(True)
        response = self.get_response(download_url)
        proxy_manager.enable_proxy(False)
        if response is not None and response.startswith('magnet:?'):
            print(response + " " + download_url)
        else:
            print(helpers.download_file(download_url))

    def search(self, what: str, cat: str = 'all') -> None:
        what = unquote(what)
        category = self.supported_categories[cat.lower()]

        # check for malformed configuration
        if 'malformed' in CONFIG_DATA:
            self.handle_error("malformed configuration file", what)
            return

        # check api_key
        if self.api_key == "YOUR_API_KEY_HERE":
            self.handle_error("api key error", what)
            return

        # search in Jackett API
        if self.thread_count > 1:
            args: List[Tuple[str, Union[List[str], None], str]] = []
            indexers = self.get_jackett_indexers(what)
            for indexer in indexers:
                args.append((what, category, indexer))
            with Pool(min(len(indexers), self.thread_count)) as pool:
                pool.starmap(self.search_jackett_indexer, args)
        else:
            self.search_jackett_indexer(what, category, 'all')

    def get_jackett_indexers(self, what: str) -> List[str]:
        params = urlencode([
            ('apikey', self.api_key),
            ('t', 'indexers'),
            ('configured', 'true')
        ])
        jacket_url = f"{self.url}/api/v2.0/indexers/all/results/torznab/api?{params}"
        response = self.get_response(jacket_url)
        if response is None:
            self.handle_error("connection error getting indexer list", what)
            return []
        # process results
        response_xml = xml.etree.ElementTree.fromstring(response)
        indexers: List[str] = []
        for indexer in response_xml.findall('indexer'):
            indexers.append(indexer.attrib['id'])
        return indexers

    def search_jackett_indexer(self, what: str, category: Union[List[str], None], indexer_id: str) -> None:
        def toStr(s: Union[str, None]) -> str:
            return s if s is not None else ''

        def getTextProp(e: Union[xml.etree.ElementTree.Element, None]) -> str:
            return toStr(e.text if e is not None else '')

        # prepare jackett url
        params_tmp = [
            ('apikey', self.api_key),
            ('q', what)
        ]
        if category is not None:
            params_tmp.append(('cat', ','.join(category)))
        params = urlencode(params_tmp)
        jacket_url = f"{self.url}/api/v2.0/indexers/{indexer_id}/results/torznab/api?{params}"
        response = self.get_response(jacket_url)
        if response is None:
            self.handle_error("connection error for indexer: " + indexer_id, what)
            return
        # process search results
        response_xml = xml.etree.ElementTree.fromstring(response)
        channel = response_xml.find('channel')
        if channel is None:
            return
        for result in channel.findall('item'):
            res: Dict[str, Any] = {}

            title_tmp = result.find('title')
            if title_tmp is not None:
                title = title_tmp.text
            else:
                continue

            tracker = getTextProp(result.find('jackettindexer'))
            if CONFIG_DATA['tracker_first']:
                res['name'] = f"[{tracker}] {title}"
            else:
                res['name'] = f"{title} [{tracker}]"

            res['link'] = result.find(self.generate_xpath('magneturl'))
            if res['link'] is not None:
                res['link'] = res['link'].attrib['value']
            else:
                res['link'] = result.find('link')
                if res['link'] is not None:
                    res['link'] = res['link'].text
                else:
                    continue

            res['size'] = result.find('size')
            res['size'] = -1 if res['size'] is None else (toStr(res['size'].text) + ' B')

            res['seeds'] = result.find(self.generate_xpath('seeders'))
            res['seeds'] = -1 if res['seeds'] is None else int(res['seeds'].attrib['value'])

            res['leech'] = result.find(self.generate_xpath('peers'))
            res['leech'] = -1 if res['leech'] is None else int(res['leech'].attrib['value'])

            if res['seeds'] != -1 and res['leech'] != -1:
                res['leech'] -= res['seeds']

            res['desc_link'] = result.find('comments')
            if res['desc_link'] is not None:
                res['desc_link'] = res['desc_link'].text
            else:
                res['desc_link'] = result.find('guid')
                res['desc_link'] = '' if res['desc_link'] is None else res['desc_link'].text

            # note: engine_url can't be changed, torrent download stops working
            res['engine_url'] = self.url

            try:
                date = datetime.strptime(getTextProp(result.find('pubDate')), '%a, %d %b %Y %H:%M:%S %z')
                res['pub_date'] = int(date.timestamp())
            except Exception:  # pylint: disable=broad-exception-caught
                res['pub_date'] = -1

            self.pretty_printer_thread_safe(res)

    def generate_xpath(self, tag: str) -> str:
        return './{http://torznab.com/schemas/2015/feed}attr[@name="%s"]' % tag

    def get_response(self, query: str) -> Union[str, None]:
        response = None
        try:
            # we can't use helpers.retrieve_url because of redirects
            # we need the cookie processor to handle redirects
            opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CookieJar()))
            response = opener.open(query).read().decode('utf-8')
        except urllib.request.HTTPError as e:
            # if the page returns a magnet redirect, used in download_torrent
            if e.code == 302:
                response = e.url
        except Exception:  # pylint: disable=broad-exception-caught
            pass
        return response

    def handle_error(self, error_msg: str, what: str) -> None:
        # Opal change: this used to emit the error as a RESULT ROW, so a Jackett
        # install with no api key yet put "Jackett: api key error!..." into the
        # user's search results as if it were a torrent. Opal parses stdout rows;
        # diagnostics belong on stderr (which lands in the app log).
        print(f"jackett: {error_msg} (config: {CONFIG_PATH}, search: '{what}')", file=sys.stderr)

    def pretty_printer_thread_safe(self, dictionary: Dict[str, Any]) -> None:
        escaped_dict = self.escape_pipe(dictionary)
        with PRINTER_THREAD_LOCK:
            prettyPrinter(escaped_dict)  # type: ignore[arg-type] # refactor later

    def escape_pipe(self, dictionary: Dict[str, Any]) -> Dict[str, Any]:
        # Safety measure until it's fixed in prettyPrinter
        for key in dictionary.keys():
            if isinstance(dictionary[key], str):
                dictionary[key] = dictionary[key].replace('|', '%7C')
        return dictionary
