"""i18n string table (native + web) and the community add-on index."""
import json
import os
import re
import subprocess
import sys
from .harness import *

LOCALE_DIR = os.path.join(PROJECT_DIR, 'src', 'core', 'locales')
KEY_RE = re.compile(r'^\s*\.([a-z][a-z0-9_]*)\s*=\s*"', re.M)


def _locale_keys():
    out = {}
    for name in sorted(os.listdir(LOCALE_DIR)):
        if name.endswith('.zig'):
            keys = KEY_RE.findall(open(os.path.join(LOCALE_DIR, name), encoding='utf-8').read())
            out[name[:-4]] = keys
    return out


def _zig_test(rel):
    result = subprocess.run([sys.executable, os.path.join(PROJECT_DIR, 'scripts', 'zig-test.py'), rel],
                            cwd=PROJECT_DIR, capture_output=True, text=True, timeout=300)
    if result.returncode:
        return 'fail', rel + ': ' + (result.stderr or result.stdout)[-2000:]
    return 'pass', 'executed ' + rel


@test('i18n: every key exists in en and no locale has keys en lacks', 'i18n')
def test_i18n_key_parity():
    locales = _locale_keys()
    if 'en' not in locales or len(locales['en']) < 40:
        return 'fail', 'locales/en.zig missing or too small'
    en = locales['en']
    if len(set(en)) != len(en):
        return 'fail', 'duplicate keys in en'
    if len(locales) < 2:
        return 'fail', 'no second locale shipped'
    pure = _src('src/core/i18n_pure.zig')
    problems = []
    for tag, keys in locales.items():
        extra = sorted(set(keys) - set(en))
        if extra:
            problems.append(f'{tag} has keys not in en: {extra[:5]}')
        if len(set(keys)) != len(keys):
            problems.append(f'{tag} has duplicate keys')
        if tag != 'en' and f'@import("locales/{tag}.zig")' not in pure:
            problems.append(f'{tag} is not registered in i18n_pure.locales')
    if problems:
        return 'fail', '; '.join(problems)
    missing = {t: len(set(en) - set(k)) for t, k in locales.items() if t != 'en'}
    return 'pass', f'{len(en)} keys; locales {sorted(locales)}; untranslated (fall back to en): {missing}'


@test('i18n: negotiation, pt-BR->pt->en fallback, plurals and format execute', 'i18n')
def test_i18n_pure():
    return _zig_test('src/core/i18n_pure.zig')


# Chrome surfaces that must read their labels through i18n.t(). Raise the bar
# as more of the app migrates; the count is reported every run.
MIGRATED_SURFACES = ['src/ui/drawer.zig', 'src/ui/header.zig', 'src/ui/footer.zig', 'src/ui/components.zig',
                     'src/ui/shell.zig', 'src/ui/locale_picker.zig', 'src/ui/addon_index_ui.zig']


@test('i18n: chrome surfaces read labels from the string table', 'i18n')
def test_i18n_migrated_surfaces():
    ui_dir = os.path.join(PROJECT_DIR, 'src', 'ui')
    using = {}
    for name in sorted(os.listdir(ui_dir)):
        if name.endswith('.zig'):
            n = _src('src/ui/' + name).count('i18n.t(')
            if n:
                using['src/ui/' + name] = n
    missing = [s for s in MIGRATED_SURFACES if s not in using]
    if missing:
        return 'fail', 'not migrated: ' + ', '.join(missing)
    drawer = _src('src/ui/drawer.zig')
    for label in ['"Search"', '"Downloads"', '"Settings"', '"Movies & TV"', '"Developer Console"']:
        if re.search(r'renderRailTab\([^)]*\), ' + re.escape(label), drawer) or ('=> ' + label) in drawer:
            return 'fail', 'drawer still hardcodes ' + label
    if 'i18n.t(.common_confirm_again)' not in _src('src/ui/components.zig'):
        return 'fail', 'confirmDangerButton confirm text not translated'
    total = sum(using.values())
    return 'pass', f'{len(using)} UI files, {total} i18n.t() call sites'


@test('i18n: web UI uses the served key table', 'i18n')
def test_i18n_web():
    en = set(_locale_keys()['en'])
    api = _src('src/services/remote_i18n_api.zig')
    if '"/i18n"' not in api or 'i18n.zig").writeJson' not in api or 'remote_i18n_api.zig").handle(' not in _src('src/services/remote.zig'):
        return 'fail', 'remote.zig does not serve /api/i18n from core/i18n.zig'
    core = _src('web/js/core.js')
    if "api('/i18n?locale='" not in core or 'loadI18n();' not in core:
        return 'fail', 'web UI does not load the served table'
    html = _src('web/index.html')
    used = set(re.findall(r'data-i18n(?:-label|-placeholder)?="([a-z0-9_]+)"', html))
    used |= set(re.findall(r"\btr\('([a-z0-9_]+)'", _web_js() + _src('web/js/commons.js')))
    unknown = sorted(used - en)
    if unknown:
        return 'fail', 'web keys missing from en: ' + ', '.join(unknown)
    if len(used) < 20:
        return 'fail', f'only {len(used)} web keys'
    return 'pass', f'{len(used)} web keys, all in en'


@test('Addon index: fixture index + signed repo parse, verify, rank and compare versions', 'Commons')
def test_addon_index_pure():
    return _zig_test('src/services/addon_index_pure.zig')


@test('Addon index: fixture index points at the signed fixture repo by pinned key', 'Commons')
def test_addon_index_fixture():
    d = os.path.join(PROJECT_DIR, 'src', 'services', 'fixtures', 'addon_index')
    index = json.load(open(os.path.join(d, 'index.json')))
    keys = json.load(open(os.path.join(d, 'keys.json')))
    repo = json.load(open(os.path.join(d, 'repo.json')))
    signed = json.load(open(os.path.join(d, 'index.signed.json')))
    entry = next((e for e in index['repositories'] if e['id'] == 'fixture'), None)
    if not entry or entry['public_key'] != keys['repo_public_key']:
        return 'fail', 'fixture entry does not carry the repo key'
    if not entry['url'].startswith('http://127.0.0.1:'):
        return 'fail', 'fixture repo must be a localhost URL'
    if set(repo) != {'manifest', 'signature'} or len(repo['signature']) != 128:
        return 'fail', 'repo fixture is not a signed envelope'
    if json.loads(signed['manifest']) != index:
        return 'fail', 'signed index manifest differs from index.json'
    catalog = json.loads(repo['manifest'])
    if 'network' not in catalog['addons'][0]['permissions']:
        return 'fail', 'fixture add-on must exercise the network permission'
    return 'pass', f"{len(index['repositories'])} entries; signed repo with {len(catalog['addons'])} add-ons"


@test('Addon index: cannot bypass signatures, pinned keys or executable approval', 'Commons')
def test_addon_index_trust_path():
    src = _src('src/services/addon_index.zig')
    problems = []
    if 'repos.add(e.id, e.url, e.public_key)' not in src:
        problems.append('index add must go through addon_repositories.add')
    if 'repos.install(repo_id, addon_id, confirmation)' not in src:
        problems.append('update must go through addon_repositories.install')
    if 'setContentTrust(addon_id, true)' in src or 'plugin-trust' in src:
        problems.append('index code must never grant executable trust')
    if 'setContentTrust(addon_id, false)' not in src:
        problems.append('update/uninstall must revoke the old approval')
    if 'repo_pure.verify(' not in src:
        problems.append('catalog versions must come from verified catalogs')
    if re.search(r'"https?://', src):
        problems.append('no built-in index URL allowed (off by default)')
    if '.conflict => error.KeyConflict' not in src:
        problems.append('index must refuse to replace a pinned key')
    if 'recordInstall(repo_id, addon.id, addon.version)' not in _src('src/services/addon_repositories.zig'):
        problems.append('install must record provenance')
    access = _src('src/services/access_pure.zig')
    if 'std.mem.startsWith(u8, path, "/addons/")) return .administer_host' not in access or '"/addons/update")) return .approve_executable' not in access:
        problems.append('access_pure must gate /addons/* and machine-only updates')
    if problems:
        return 'fail', '; '.join(problems)
    return 'pass', 'add/install/update reuse the signed path; no trust grants; routes gated'


@test("Native page-shell sidebar follows the UI language", "i18n")
def test_shell_sidebar_localized():
    # REGRESSION: with LANG unset and Spanish preferred, /api/i18n reported
    # "es" but the native sidebar stayed English: shell.zig's tabLabel and the
    # Home/Watching/Browser entries were literals; only the old drawer used i18n.
    shell = _src("src/ui/shell.zig")
    en = _src("src/core/locales/en.zig")
    body = _between(shell, "fn tabLabel(t: state.DrawerTab) []const u8 {", "\n}\n")
    want = {".TMDB": "nav_movies_tv", ".Downloads": "nav_downloads", ".Comics": "nav_comics",
            ".Iptv": "nav_live_tv", ".Web": "nav_browser", ".Settings": "nav_settings"}
    missing = [tab for tab, key in want.items() if f"{tab} => i18n.t(.{key})" not in body]
    if "i18n.t(.nav_home)" not in shell or "i18n.t(.nav_watching)" not in shell:
        missing.append("Home/Watching entries")
    if missing:
        return "fail", "sidebar labels still literal: " + ", ".join(missing)
    # English must render exactly as before: every key used keeps its old text.
    old = {"nav_movies_tv": "Movies & TV", "nav_live_tv": "Live TV", "nav_browser": "Browser",
           "nav_home": "Home", "nav_watching": "Watching", "nav_visual_novels": "Visual Novels"}
    drift = [k for k, v in old.items() if f'.{k} = "{v}"' not in en]
    if drift:
        return "fail", "English nav text changed: " + ", ".join(drift)
    return "pass", "tabLabel + Home/Watching/Browser go through i18n; English text unchanged"
