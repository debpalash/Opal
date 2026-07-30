# VERSION: 1.0
# AUTHORS: Opal
"""Installed-source config for the nova2 engines.

Opal had TWO unrelated source layers. The Zig resolvers read the endpoints the
Plugins page writes to ``~/.config/opal/plugins/sources/<id>.json``; the ~25
nova2 engines hardcoded their URLs and never opened that directory. So for every
nova2-backed source, install/uninstall wrote a file nothing read — the Plugins
page was reporting control it did not have (a second, independent cause of the
"sources are not installing" reports).

This module is the missing half. ``nova2.py`` calls into it for every search, so
one choke point covers all engines instead of editing 25 files:

* ``base``    overrides the engine's hardcoded ``url``
* ``mirrors`` (list, or comma/semicolon/newline-separated string) is tried in
  order when the base yields nothing — blocked/seized domains are the single
  most common failure mode for these sites, and each engine had exactly one host
* the host that produced results is remembered in the cache dir and tried first
  next time (no background prober — the search itself is the probe)

Nothing here is Opal-specific to a given engine: `<id>` is the engine's module
name, which is already what nova2's install gate matches against.

The path logic MUST mirror ``src/core/paths.zig`` (see ``config_base``).
Pure helpers (``normalize_base``, ``parse_mirrors``, ``order_candidates``) are
covered by tests/features/test_source_layer.py.
"""

import json
import os
import sys
import traceback

_SOURCES_SUBDIR = ('opal', 'plugins', 'sources')


# ── Paths (must mirror src/core/paths.zig) ───────────────────────────────────

def config_base():
    """Platform config root. Windows keeps config under %APPDATA%, NOT ~/.config
    — looking in the POSIX spot there finds nothing and every source looks
    uninstalled."""
    if sys.platform == 'win32':
        return os.environ.get('APPDATA') or os.path.join(
            os.path.expanduser('~'), 'AppData', 'Roaming')
    return os.environ.get('XDG_CONFIG_HOME') or os.path.join(
        os.path.expanduser('~'), '.config')


def cache_base():
    if sys.platform == 'win32':
        return os.path.join(
            os.environ.get('LOCALAPPDATA') or os.path.join(
                os.path.expanduser('~'), 'AppData', 'Local'),
            'opal', 'cache')
    return os.path.join(
        os.environ.get('XDG_CACHE_HOME') or os.path.join(
            os.path.expanduser('~'), '.cache'),
        'opal')


def sources_dir():
    return os.path.join(config_base(), *_SOURCES_SUBDIR)


def installed_ids():
    """Source ids the user installed via the Plugins page. Opal ships NEUTRAL —
    empty here means no engine runs."""
    try:
        return {f[:-5] for f in os.listdir(sources_dir()) if f.endswith('.json')}
    except OSError:
        return set()


def load(source_id):
    """The installed endpoint map for `source_id`, or {} when not installed."""
    try:
        with open(os.path.join(sources_dir(), source_id + '.json'),
                  encoding='utf-8') as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


# ── Pure helpers (unit-tested) ───────────────────────────────────────────────

def parse_mirrors(value):
    """Mirror list from either JSON shape: a list of strings, or one string with
    comma / semicolon / newline separators."""
    if isinstance(value, (list, tuple)):
        return [str(v) for v in value if isinstance(v, str) and v.strip()]
    if isinstance(value, str):
        out = []
        for chunk in value.replace(';', ',').replace('\n', ',').split(','):
            chunk = chunk.strip()
            if chunk:
                out.append(chunk)
        return out
    return []


def normalize_base(url, template):
    """`url` reshaped to match `template`'s trailing-slash convention.

    This is not cosmetic: the engines disagree. ``one337x`` does ``self.url +
    '/search/...'`` (needs NO trailing slash) while ``bitsearch`` does
    ``self.url[:-1] + path`` and ``'{0}search?q='.format(self.url)`` (needs
    one). Substituting a base of the wrong shape silently produces 404s.
    """
    url = (url or '').strip().rstrip('/')
    if not url:
        return url
    return url + '/' if (template or '').endswith('/') else url


def order_candidates(base, mirrors, last_good=None):
    """Hosts to try, in order: base first, then mirrors as listed, de-duplicated
    and trailing-slash-insensitive. A remembered last-good host moves to the
    front — a rotation, so every other host still gets its turn."""
    out = []
    for raw in [base] + list(mirrors or []):
        u = (raw or '').strip().rstrip('/')
        if not u or not u.startswith(('http://', 'https://')) or ' ' in u:
            continue
        if u not in out:
            out.append(u)
    if last_good:
        lg = last_good.strip().rstrip('/')
        if lg in out:
            out.remove(lg)
            out.insert(0, lg)
    return out


# ── Last-good mirror memory ──────────────────────────────────────────────────
#
# nova2 is a fresh process per search (and forks a pool on top), so the memory
# has to be on disk to be worth anything. One tiny file per source, written
# atomically; a failure to write is never fatal.

def _state_path(source_id):
    return os.path.join(cache_base(), 'mirrors', source_id)


def last_good(source_id):
    try:
        with open(_state_path(source_id), encoding='utf-8') as f:
            return f.read().strip()
    except Exception:
        return ''


def remember(source_id, url):
    path = _state_path(source_id)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write(url)
        os.replace(tmp, path)
    except Exception:
        pass


# ── The bit nova2 calls ──────────────────────────────────────────────────────

def candidates_for(source_id, default_url):
    """Ordered hosts for `source_id`, each already shaped like `default_url`.

    Falls back to the engine's hardcoded URL when the source supplies no base —
    an installed-but-baseless source keeps working exactly as before.
    """
    cfg = load(source_id)
    base = cfg.get('base') or cfg.get('url') or default_url
    hosts = order_candidates(base, parse_mirrors(cfg.get('mirrors')),
                             last_good(source_id))
    if not hosts:
        hosts = order_candidates(default_url, [])
    return [normalize_base(h, default_url) for h in hosts]


def search_with_failover(engine, source_id, what, cat, result_counter):
    """Run `engine.search` against each candidate host until one yields results.

    `result_counter` returns the number of rows printed so far (novaprinter's
    counter); a host that prints nothing is treated as unreachable and the next
    mirror is tried. Returns True if the search ran without raising.
    """
    default_url = getattr(engine, 'url', '') or ''
    hosts = candidates_for(source_id, default_url)
    if not hosts:
        hosts = ['']

    ok = True
    for host in hosts:
        if host:
            engine.url = host
        before = result_counter()
        try:
            if hasattr(engine, 'supported_categories') and cat:
                engine.search(what, cat)
            else:
                engine.search(what)
        except Exception:
            # stderr, never stdout — Opal parses stdout as result rows.
            traceback.print_exc()
            ok = False
        if result_counter() > before:
            if host:
                remember(source_id, host)
            return True
    return ok
