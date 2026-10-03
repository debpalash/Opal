"""Original bounded public-release feed helpers; no downloaded upstream code."""
import base64
import binascii
import html
import re
import xml.etree.ElementTree as ET
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

MAX_BODY = 4 * 1024 * 1024
MAX_ROWS = 100


def clean_title(value):
    if not isinstance(value, str):
        return ''
    return ' '.join(html.unescape(value).replace('|', ' ').split())[:1024]


def count(value):
    if isinstance(value, bool):
        return -1
    try:
        number = int(value)
        return number if 0 <= number <= 2**63 - 1 else -1
    except (TypeError, ValueError, OverflowError):
        return -1


def canonical_magnet(value, title=''):
    """Return an actual feed BTIH, normalizing base32 to hex for deduplication."""
    if not isinstance(value, str) or len(value) > 8192 or any(c in value for c in '\r\n|'):
        return None
    if not value.startswith('magnet:?'):
        return None
    fields = parse_qsl(urlsplit(value).query)
    identities = [v[9:] for k, v in fields if k == 'xt' and v.lower().startswith('urn:btih:')]
    if len(identities) != 1:
        return None
    digest = identities[0]
    if re.fullmatch(r'[a-fA-F0-9]{40}', digest):
        digest = digest.lower()
    elif re.fullmatch(r'[A-Za-z2-7]{32}', digest):
        try:
            digest = base64.b32decode(digest.upper()).hex()
        except (ValueError, binascii.Error):
            return None
    else:
        return None
    name = next((clean_title(v) for k, v in fields if k == 'dn'), '') or title
    size = count(next((v for k, v in fields if k == 'xl'), None))
    params = [('xt', 'urn:btih:' + digest)]
    if name:
        params.append(('dn', name))
    if size >= 0:
        params.append(('xl', str(size)))
    for k, v in fields:
        if k == 'tr' and v.startswith(('https://', 'http://', 'udp://')) and len(v) <= 1024 and not any(c in v for c in '\r\n|'):
            params.append((k, v))
    return 'magnet:?' + urlencode(params, safe=':'), digest, name, size


def provider_url(raw, base, torrent=False):
    if not isinstance(raw, str) or len(raw) > 2048 or any(c in raw for c in '\r\n|'):
        return ''
    parts, origin = urlsplit(raw), urlsplit(base)
    if parts.scheme not in ('http', 'https') or parts.hostname != origin.hostname or parts.username or parts.password:
        return ''
    if torrent and not parts.path.endswith('.torrent'):
        return ''
    # Public provider HTTPS endpoints were verified; no credential query added.
    return urlunsplit(('https' if origin.scheme == 'https' else parts.scheme, parts.netloc, parts.path, parts.query, ''))


def rss_rows(body, base, allow_torrent=False):
    if not isinstance(body, str) or len(body) > MAX_BODY or '<!DOCTYPE' in body.upper() or '<!ENTITY' in body.upper():
        return
    try:
        root = ET.fromstring(body)
    except (ET.ParseError, ValueError):
        return
    seen = set()
    for item in root.findall('./channel/item')[:MAX_ROWS]:
        title = clean_title(item.findtext('title', ''))
        enclosure = item.find('enclosure')
        if not title or enclosure is None:
            continue
        raw = enclosure.get('url', '')
        magnet = canonical_magnet(raw, title)
        size = -1
        if magnet:
            link, key, title, size = magnet
        elif allow_torrent:
            link = provider_url(raw, base, torrent=True)
            if not link:
                continue
            key = link
        else:
            continue
        if key in seen:
            continue
        seen.add(key)
        # DMHY reports enclosure length="1" as a placeholder, not file bytes.
        for child in item:
            if child.tag.rsplit('}', 1)[-1] == 'contentLength':
                size = count(child.text)
                break
        yield {'link': link, 'name': title, 'size': size, 'seeds': -1, 'leech': -1,
               'engine_url': base, 'desc_link': provider_url(item.findtext('link', ''), base)}
