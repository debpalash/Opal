"""Settings is split into one module per tab (v2 roadmap item 6).

src/ui/settings.zig stays the entry point (nav, right pane, shared helpers,
modals) and dispatches each tab to src/ui/settings/<tab>.zig. These checks keep
the split from silently collapsing back into one 5k-line file, and keep the
moved code on the shared theme spacing/radius/font_size tokens.
"""

from .harness import *  # noqa: F401,F403
import os
import re

MAX_SETTINGS_MODULE_LINES = 1500
_SETTINGS_DIR = os.path.join(PROJECT_DIR, "src", "ui", "settings")


def _settings_modules():
    """(rel, text) for settings.zig plus every per-tab module."""
    out = [("src/ui/settings.zig", open(os.path.join(PROJECT_DIR, "src/ui/settings.zig"), encoding="utf-8").read())]
    if os.path.isdir(_SETTINGS_DIR):
        for name in sorted(os.listdir(_SETTINGS_DIR)):
            if name.endswith(".zig"):
                with open(os.path.join(_SETTINGS_DIR, name), encoding="utf-8") as f:
                    out.append((f"src/ui/settings/{name}", f.read()))
    return out


@test("Settings modules stay under 1,500 lines", "Settings")
def test_settings_module_size():
    mods = _settings_modules()
    if len(mods) < 2:
        return "fail", "src/ui/settings/ has no per-tab modules"
    over = [f"{rel} ({text.count(chr(10))})" for rel, text in mods
            if text.count("\n") > MAX_SETTINGS_MODULE_LINES]
    if over:
        return "fail", "over %d lines: %s" % (MAX_SETTINGS_MODULE_LINES, ", ".join(over))
    biggest = max(mods, key=lambda m: m[1].count("\n"))
    return "pass", f"{len(mods)} modules, largest {biggest[0]} ({biggest[1].count(chr(10))} lines)"


@test("Settings entry dispatches every tab to its module", "Settings")
def test_settings_tab_dispatch():
    entry = open(os.path.join(PROJECT_DIR, "src/ui/settings.zig"), encoding="utf-8").read()
    imports = dict(re.findall(r'^const (\w+_tab) = @import\("settings/(\w+)\.zig"\);', entry, re.M))
    pane = _between(entry, "fn renderRightPane(", "\n}\n")
    switch = _between(pane, "switch (state.app.settings_tab) {", "\n    }")
    arms = re.findall(r"^\s*\.(\w+) => ([\w.@\"()]+?)\(\),", switch, re.M)
    if len(arms) < 12:
        return "fail", f"tab switch not found or truncated ({len(arms)} arms)"
    problems = []
    for tab, call in arms:
        if tab == "Profiles":  # owned by profiles_ui.zig, never lived here
            continue
        mod, _, fn = call.rpartition(".")
        if mod not in imports:
            problems.append(f".{tab} renders inline ({call})")
            continue
        path = os.path.join(_SETTINGS_DIR, imports[mod] + ".zig")
        body = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        if f"pub fn {fn}(" not in body:
            problems.append(f"{imports[mod]}.zig lacks pub fn {fn}")
    if problems:
        return "fail", "; ".join(problems)
    return "pass", f"{len(arms)} tabs dispatched across {len(imports)} modules"


# On-scale literals that have a theme token (theme.spacing / theme.radius) and
# therefore must be spelled as the token in settings code. Off-scale values
# (1, 3, 5, 6, 10, ...) have no token and stay literal.
_SPACING_ON_SCALE = {"2", "4", "8", "12", "16", "24", "32", "48"}
_RADIUS_ON_SCALE = {"3", "5", "7", "10", "14", "999"}
_SPACING_RE = re.compile(r"\.(?:margin|padding)\s*=\s*(\.\{[^}]*\}|dvui\.Rect\.all\([^)]*\))")
_NUM_RE = re.compile(r"(?<![\w.])(\d+(?:\.\d+)?)(?![\w.])")


def token_violations(rel, text):
    """Raw on-scale spacing/radius/font literals in one settings module."""
    out = []
    code = re.sub(r"//[^\n]*", "", text)
    for m in _SPACING_RE.finditer(code):
        for n in _NUM_RE.findall(m.group(1)):
            if n in _SPACING_ON_SCALE:
                line = code.count("\n", 0, m.start()) + 1
                out.append(f"{rel}:{line} spacing {n}")
    for m in re.finditer(r"CornerRect\.all\((\d+(?:\.\d+)?)\)", code):
        if m.group(1) in _RADIUS_ON_SCALE:
            out.append(f"{rel}:{code.count(chr(10), 0, m.start()) + 1} radius {m.group(1)}")
    for m in re.finditer(r"\.size\s*=\s*(\d+(?:\.\d+)?)\s*[;,]", code):
        out.append(f"{rel}:{code.count(chr(10), 0, m.start()) + 1} font size {m.group(1)}")
    return out


@test("Settings use theme spacing/radius/font_size tokens", "Settings")
def test_settings_theme_tokens():
    theme = _src("src/ui/theme.zig")
    pure = _src("src/ui/theme_pure.zig")
    for ns in ("spacing", "radius", "font_size"):
        if f"pub const {ns} = struct" not in pure or f"pub const {ns} = tp.{ns};" not in theme:
            return "fail", f"theme.{ns} not exported from theme_pure.zig"
    entry = open(os.path.join(PROJECT_DIR, "src/ui/settings.zig"), encoding="utf-8").read()
    if "TODO: needs theme.spacing" in entry:
        return "fail", "settings.zig still carries the token TODO"
    # Self-check the scanner so a regex slip cannot make this vacuous.
    probe = token_violations("probe", ".margin = .{ .x = 0, .y = 4, .w = 0, .h = 6 }\n.corners = dvui.CornerRect.all(7)\nf.size = 11;")
    if len(probe) != 3:
        return "fail", f"scanner self-check failed: {probe}"
    bad = [v for rel, text in _settings_modules() for v in token_violations(rel, text)]
    if bad:
        return "fail", f"{len(bad)} raw literals: " + ", ".join(bad[:6])
    return "pass", "settings modules spell on-scale spacing/radius/font sizes as theme tokens"
