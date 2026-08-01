# VERSION: 1.58

# Author:
#  Christophe DUMEZ (chris@qbittorrent.org)

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#    * Redistributions of source code must retain the above copyright notice,
#      this list of conditions and the following disclaimer.
#    * Redistributions in binary form must reproduce the above copyright
#      notice, this list of conditions and the following disclaimer in the
#      documentation and/or other materials provided with the distribution.
#    * Neither the name of the author nor the names of its contributors may be
#      used to endorse or promote products derived from this software without
#      specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

import datetime
import gzip
import html
import io
import os
import socket
import ssl
import sys
import time
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Mapping
from typing import Any, Optional, cast

import socks


def _getBrowserUserAgent() -> str:
    """
    Disguise as browser to circumvent website blocking
    """

    # Firefox release calendar
    # https://whattrainisitnow.com/calendar/
    # https://wiki.mozilla.org/index.php?title=Release_Management/Calendar&redirect=no

    baseDate = datetime.date(2024, 4, 16)
    baseVersion = 125

    nowDate = datetime.date.today()
    nowVersion = baseVersion + ((nowDate - baseDate).days // 30)

    return f"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:{nowVersion}.0) Gecko/20100101 Firefox/{nowVersion}.0"


_headers: dict[str, str] = {'User-Agent': _getBrowserUserAgent()}

# Seconds to wait before each retry. Short and bounded on purpose: a fully dead
# host must not add more than ~1s per fetch to a search that is already slow.
_RETRY_BACKOFF = (0.3, 0.7)

# Per-attempt socket deadline.
#
# urlopen() without `timeout` uses the global default socket timeout, which is
# None -- so a host that completes the TCP handshake and then never answers
# blocks the calling engine thread FOREVER. Opal's resolver drains nova2's
# stdout to EOF and then wait()s with no deadline of its own
# (resolver.zig resolveTorrents), so one such host holds the whole torrent
# search open. Measured: `ilcorsaronero.link` hung a single retrieve_url call
# past 20 minutes from this network. Adding retries multiplied that by
# `attempts`, so the deadline has to be per attempt.
#
# 15s is well past the <5s these sites take when they answer at all, and bounds
# a fully hung host at 15*attempts + backoff (~46s at the default 3).
_FETCH_TIMEOUT = 15

# ...but only for a DIRECT fetch. Through Opal's DPI-bypass SOCKS sidecar the
# same request pays SOCKS setup, the bypass's own connect, and the segmented
# handshake it uses to get past the filter. Measured on a connection that blocks
# trackers by SNI: torrentdownloads answered in 20.5s proxied versus <5s direct.
# At a 15s deadline every proxied fetch timed out, retrieve_url swallowed it
# (see its `return ""`), and the engines reported zero results -- so turning the
# bypass on appeared to do nothing for search, which is the opposite of the
# point. Applied only while a proxy is actually configured, so direct fetches
# keep the tight bound above and a dead host still fails fast.
_FETCH_TIMEOUT_PROXIED = 40

_proxy_active = False


def fetch_timeout() -> int:
    """Per-attempt deadline, widened while a SOCKS proxy is in use."""
    return _FETCH_TIMEOUT_PROXIED if _proxy_active else _FETCH_TIMEOUT


_original_socket = socket.socket


def enable_socks_proxy(enable: bool) -> None:
    if enable:
        socksURL = os.environ.get("qbt_socks_proxy")
        if socksURL is not None:
            parts = urllib.parse.urlsplit(socksURL)
            resolveHostname = (parts.scheme == "socks4a") or (parts.scheme == "socks5h")
            if (parts.scheme == "socks4") or (parts.scheme == "socks4a"):
                socks.setdefaultproxy(socks.PROXY_TYPE_SOCKS4, parts.hostname, parts.port, resolveHostname)
                socket.socket = cast(type[socket.socket], socks.socksocket)  # type: ignore[misc]
            elif (parts.scheme == "socks5") or (parts.scheme == "socks5h"):
                socks.setdefaultproxy(socks.PROXY_TYPE_SOCKS5, parts.hostname, parts.port, resolveHostname, parts.username, parts.password)
                socket.socket = cast(type[socket.socket], socks.socksocket)  # type: ignore[misc]
        else:
            # the following code provide backward compatibility for older qbt versions
            # TODO: scheduled be removed with qbt >= 5.3
            legacySocksURL = os.environ.get("sock_proxy")
            if legacySocksURL is not None:
                legacySocksURL = f"socks5h://{legacySocksURL.strip()}"
                parts = urllib.parse.urlsplit(legacySocksURL)
                socks.setdefaultproxy(socks.PROXY_TYPE_SOCKS5, parts.hostname, parts.port, True, parts.username, parts.password)
                socket.socket = cast(type[socket.socket], socks.socksocket)  # type: ignore[misc]
    else:
        socket.socket = _original_socket  # type: ignore[misc]

    # Derived from whether the patch actually took, rather than from `enable`:
    # every branch above is conditional on an env var being present and
    # well-formed, so `enable=True` alone does not mean a proxy is in play.
    global _proxy_active
    _proxy_active = socket.socket is not _original_socket


# This is only provided for backward compatibility, new code should not use it
htmlentitydecode = html.unescape


# ── Anti-block fallback ──────────────────────────────────────────────────────
#
# A bot wall is not a transient failure, so `_is_retryable` correctly refuses to
# retry it -- which left the walled engines at a permanent zero. Measured
# 2026-07-30: `1337x.to` answered 403 to 7 of 10 requests and `uindex` serves a
# Cloudflare "Just a moment..." interstitial on /search.php while its homepage
# returns 200. No retry policy can fix either.
#
# Opal already defeats exactly this for its Zig scrapers, in
# `src/services/scrape_fetch.zig`: plain curl first, and when the response is an
# interstitial it re-fetches through the anti-detect browser (camoufox /
# CloakBrowser over the Playwright bridge), which passes the challenge. The nova2
# engines could not reach it -- they are a child process with no handle on the
# browser bridge -- so `GET /api/scrape?url=` now exposes that same call, and
# this is the client for it.
#
# Degrades to today's behaviour whenever the app is not up, the token is absent,
# or the endpoint fails: those cases return None and the caller returns "".

# Body markers for a challenge/captcha interstitial served under a 200. Kept in
# step with `needsBrowser` in src/services/scrape_fetch_pure.zig -- that module
# holds the authoritative set and its false-positive guards.
_WALL_MARKERS = (
    'just a moment',
    'checking your browser',
    'cf-browser-verification',
    'cf_chl_opt',
    'ddos-guard',
    '__cf_chl',
    'enable javascript and cookies to continue',
    'attention required! | cloudflare',
)

# Statuses a bot wall answers with. 429 is excluded on purpose: it is genuinely
# transient and `_is_retryable` already handles it, so sending it through the
# browser would spend ~45s on something a 0.7s backoff fixes.
_WALL_STATUSES = (403, 503)

# The browser fallback is bounded at ~45s server-side (bridge start + goto +
# challenge wait), so allow for that plus the round trip.
_SCRAPE_TIMEOUT = 60


def _looks_walled(status: int, body: str) -> bool:
    """Whether a response is a bot wall rather than the page that was asked for.

    `status` 0 means "no HTTP error" -- the 200-with-an-interstitial case, which
    is the one that fails silently, since the engine parses the challenge page
    and reports zero rows on a fetch that looked like it worked.
    """
    if status in _WALL_STATUSES:
        return True
    if not body:
        return False
    head = body[:4096].lower()
    return any(m in head for m in _WALL_MARKERS)


def _opal_api_token() -> Optional[str]:
    """Opal's static API token, or None when the app has never written one."""
    try:
        import opal_sources  # same directory; imported lazily to avoid a cycle
        base = opal_sources.config_base()
    except Exception:
        return None
    try:
        with open(os.path.join(base, 'opal', 'api.token'), encoding='utf-8') as fh:
            token = fh.read().strip()
        return token or None
    except OSError:
        return None


def _opal_scrape(url: str) -> Optional[str]:
    """Re-fetch `url` through Opal's anti-block fetch. None if unavailable."""
    token = _opal_api_token()
    if not token:
        return None
    port = os.environ.get('OPAL_REMOTE_PORT', '41595')
    api = 'http://127.0.0.1:{0}/api/scrape?url={1}'.format(
        port, urllib.parse.quote(url, safe=''))
    req = urllib.request.Request(api, headers={'Authorization': 'Bearer ' + token})
    try:
        resp = urllib.request.urlopen(req, timeout=_SCRAPE_TIMEOUT)
        body = resp.read().decode('utf-8', 'replace')
    except Exception:
        return None  # app not running, or the browser could not get through
    if not body:
        return None
    print('helpers: unblocked {0} via the anti-detect browser'.format(url),
          file=sys.stderr)  # stdout is the result stream
    return body


def _is_retryable(exc: Exception) -> bool:
    """Whether a failed fetch is worth another attempt.

    A 4xx is the server's considered answer -- 403 from a bot wall, 404 for a
    dead path -- and retrying it just burns time. Connection resets, timeouts
    and 5xx/429 are transient, and on this class of site they are common: a
    host observed answering roughly one request in three returns zero rows on
    every search, because a single reset ends the only attempt.
    """
    if isinstance(exc, urllib.error.HTTPError):
        return exc.code == 429 or exc.code >= 500
    return True  # URLError, socket timeout, IncompleteRead


def retrieve_url(url: str, custom_headers: Mapping[str, str] = {}, request_data: Optional[Any] = None, ssl_context: Optional[ssl.SSLContext] = None, unescape_html_entities: bool = True, attempts: int = 3) -> str:
    """
    Return the content of the url page as a string

    `attempts` bounds transient-failure retries (see `_is_retryable`). Pass
    attempts=1 for per-row best-effort fetches, where a miss should drop that
    row rather than multiply the latency of a whole page.

    A bot wall (403/503, or a challenge interstitial under a 200) is not retried
    -- it is re-fetched once through Opal's anti-detect browser, see
    `_opal_scrape`. That is the only thing that gets `uindex` and `one337x` off
    zero.
    """

    request = urllib.request.Request(url, request_data, {**_headers, **custom_headers})
    response = None
    walled = False
    for attempt in range(max(1, attempts)):
        try:
            response = urllib.request.urlopen(request, timeout=fetch_timeout(), context=ssl_context)
            break
        except Exception as exc:  # URLError, HTTPError, socket.timeout
            if not isinstance(exc, (urllib.error.URLError, OSError)):
                raise
            if isinstance(exc, urllib.error.HTTPError) and _looks_walled(exc.code, ""):
                walled = True
            if attempt == attempts - 1 or not _is_retryable(exc):
                break  # give up on the plain path
            time.sleep(_RETRY_BACKOFF[min(attempt, len(_RETRY_BACKOFF) - 1)])
    if response is None:
        # A wall is worth one browser attempt; a dead host is not.
        if walled:
            unblocked = _opal_scrape(url)
            if unblocked:
                return html.unescape(unblocked) if unescape_html_entities else unblocked
        return ""  # Silently handle connection errors
    try:
        data: bytes = response.read()
    except Exception:
        # Handle IncompleteRead, chunked transfer errors, etc.
        return ""

    # Check if it is gzipped
    if data[:2] == b'\x1f\x8b':
        # Data is gzip encoded, decode it
        with io.BytesIO(data) as compressedStream, gzip.GzipFile(fileobj=compressedStream) as gzipper:
            data = gzipper.read()

    charset = 'utf-8'
    try:
        charset = response.getheader('Content-Type', '').split('charset=', 1)[1]
    except IndexError:
        pass

    dataStr = data.decode(charset, 'replace')

    # A challenge page served under 200 OK is the failure mode that hides: the
    # engine parses the interstitial and reports zero rows on a fetch that looked
    # like it worked. uindex does exactly this on /search.php.
    if _looks_walled(0, dataStr):
        unblocked = _opal_scrape(url)
        if unblocked:
            dataStr = unblocked

    if unescape_html_entities:
        dataStr = html.unescape(dataStr)

    return dataStr


def download_file(url: str, referer: Optional[str] = None, ssl_context: Optional[ssl.SSLContext] = None) -> str:
    """
    Download file at url and write it to a file, return both the path to the file and the url
    """

    # Download url
    request = urllib.request.Request(url, headers=_headers)
    if referer is not None:
        request.add_header('referer', referer)
    response = urllib.request.urlopen(request, timeout=fetch_timeout(), context=ssl_context)
    data = response.read()

    # Check if it is gzipped
    if data[:2] == b'\x1f\x8b':
        # Data is gzip encoded, decode it
        with io.BytesIO(data) as compressedStream, gzip.GzipFile(fileobj=compressedStream) as gzipper:
            data = gzipper.read()

    # Write it to a file
    fileHandle, path = tempfile.mkstemp()
    with os.fdopen(fileHandle, "wb") as file:
        file.write(data)

    # return file path
    return f"{path} {url}"
