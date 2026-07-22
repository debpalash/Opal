"""AUR publish (packaging/aur/push-to-aur.sh + release.yml's `aur` job).

Regression tests for the two bugs that broke the v0.5.0 AUR publish, plus the
environment the script actually needs. The SSH key itself can only be fixed on
aur.archlinux.org — but everything downstream of it has to be correct or the
publish fails again the moment the key works.

See tests/features/harness.py for the shared @test decorator + _src()."""
import os as _os

from .harness import *  # noqa: F401,F403


def _read(rel):
    fp = _os.path.join(PROJECT_DIR, rel)
    return open(fp).read() if _os.path.exists(fp) else ""


@test("AUR push script: package list expands to two packages", "Packaging")
def test_aur_pkg_list_regression():
    sh = _read("packaging/aur/push-to-aur.sh")
    if not sh:
        return "fail", "packaging/aur/push-to-aur.sh missing"
    # THE v0.5.0 BUG: PKGS=("${@:-opal opal-bin}") expands, with no args, to a
    # SINGLE element "opal opal-bin" — the job then tried to clone
    # aur:"opal opal-bin".git and failed. Check CODE only; the script documents
    # the old form in a comment so nobody reintroduces it.
    code = [ln for ln in sh.splitlines() if not ln.lstrip().startswith("#")]
    if any('PKGS=("${@:-' in ln for ln in code):
        return "fail", 'PKGS=("${@:-…}") collapses the default list into one element'
    if "PKGS=(opal opal-bin)" not in sh or 'PKGS=("$@")' not in sh:
        return "fail", "expected an explicit $#-guarded default package list"

    # Prove it, don't just grep for it: run the same shell snippet.
    import re, subprocess
    m = re.search(r'if \[\[ \$# -gt 0 \]\]; then\n.*?\nfi', sh, re.S)
    if not m:
        return "fail", "could not locate the package-list block to execute"
    snippet = m.group(0) + '\nprintf "%s\\n" "${PKGS[@]}"'
    out = subprocess.run(["bash", "-c", snippet, "_"], capture_output=True, text=True)
    got = out.stdout.split()
    if got != ["opal", "opal-bin"]:
        return "fail", f"default package list expands to {got!r}, want ['opal', 'opal-bin']"
    return "pass", "default expands to 2 packages (opal, opal-bin) — v0.5.0 regression covered"


@test("AUR publish runs where makepkg exists", "Packaging")
def test_aur_needs_makepkg():
    sh = _read("packaging/aur/push-to-aur.sh")
    wf = _read(".github/workflows/release.yml")
    checks = {
        # AUR rejects a push whose .SRCINFO is missing or stale, and only
        # makepkg can generate one from a PKGBUILD (it's bash, not a data file).
        "srcinfo generated": "makepkg --printsrcinfo > .SRCINFO" in sh,
        # On Ubuntu that line aborted under `set -e` right after the clone.
        "missing makepkg is a clear error": "error: makepkg not found" in sh,
        "job runs in an arch container": "container: archlinux:base-devel" in wf,
        "arch tooling installed": "pacman -Syu --noconfirm --needed git openssh pacman-contrib" in wf,
        # makepkg and updpkgsums refuse to run as root.
        "non-root makepkg user": "useradd -m builder" in wf and "sudo -u builder" in wf
            and "HOME=/home/builder" in wf,
        # The key is materialised into $HOME — builder must own it.
        "workspace owned by builder": 'chown -R builder "$GITHUB_WORKSPACE"' in wf,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "AUR job environment incomplete: " + ", ".join(missing)
    return "pass", "aur job: archlinux container + non-root builder, makepkg available"


@test("AUR clone failure names the key registration step", "Packaging")
def test_aur_key_error_message():
    sh = _read("packaging/aur/push-to-aur.sh")
    checks = {
        # 'Permission denied (publickey)' was the v0.5.0 failure and the old
        # message blamed the namespace instead of the unregistered key.
        "explains publickey denial": "Permission denied (publickey)" in sh,
        "points at the AUR account page": "https://aur.archlinux.org/account/" in sh,
        # A brand-new package name clones as an empty repo with exit 0.
        "new package is not an error": "NOT an error" in sh,
        "empty secret is a no-op, not a failure": "AUR publish is a no-op" in sh
            and "exit 0" in sh,
    }
    missing = [k for k, ok in checks.items() if not ok]
    if missing:
        return "fail", "AUR error messaging incomplete: " + ", ".join(missing)
    return "pass", "clone failure distinguishes an unregistered key from a new package"
