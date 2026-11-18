"""Small shared pieces for the Opal-authored torrent engines (original code).

Kept beside ``opal_release_feed`` rather than inside ``engines/`` because every
file there is treated as an installable engine.
"""
import calendar
import re
from concurrent.futures import ThreadPoolExecutor
from email.utils import parsedate_to_datetime
from urllib.parse import urlencode

from opal_release_feed import clean_title

# Open public trackers, appended only when a provider publishes a bare info
# hash. They help peer discovery; DHT still works without them.
TRACKERS = (
    'udp://tracker.opentrackr.org:1337/announce',
    'udp://open.stealth.si:80/announce',
    'udp://tracker.torrent.eu.org:451/announce',
    'udp://exodus.desync.com:6969/announce',
    'udp://tracker.tiny-vps.com:6969/announce',
)

_HEX40 = re.compile(r'[a-fA-F0-9]{40}')
_TAG = re.compile(r'<[^>]*>')


def magnet_from_hash(digest, name='', trackers=TRACKERS):
    """A magnet for a provider-published 40-hex info hash, or '' if it is not one."""
    if not isinstance(digest, str) or not _HEX40.fullmatch(digest):
        return ''
    params = [('xt', 'urn:btih:' + digest.lower())]
    if name:
        params.append(('dn', name))
    params.extend(('tr', t) for t in trackers)
    return 'magnet:?' + urlencode(params, safe=':')


def text_of(fragment):
    """Visible text of an HTML fragment: tags dropped, entities decoded, one line."""
    return clean_title(_TAG.sub(' ', fragment or ''))


def rfc822_epoch(value):
    """Unix time for an RSS pubDate, or -1."""
    try:
        return int(parsedate_to_datetime(value.strip()).timestamp())
    except (AttributeError, TypeError, ValueError, OverflowError):
        return -1


def ymd_epoch(value):
    """Unix time (UTC midnight) for YYYY-MM-DD, or -1."""
    m = re.fullmatch(r'\s*(\d{4})-(\d{2})-(\d{2})\s*', value or '')
    if not m:
        return -1
    try:
        return calendar.timegm((int(m.group(1)), int(m.group(2)), int(m.group(3)), 0, 0, 0))
    except (ValueError, OverflowError):
        return -1


def fetch_many(fetch, urls, workers=4):
    """Bodies for `urls`, in order; a failed fetch is '' (that row is dropped).

    Detail pages are fetched on worker threads but rows are always printed by
    the caller: novaprinter's row counter is thread-local.
    """
    def one(url):
        try:
            return fetch(url) or ''
        except Exception:
            return ''
    if not urls:
        return []
    with ThreadPoolExecutor(max_workers=min(workers, len(urls))) as pool:
        return list(pool.map(one, urls))
