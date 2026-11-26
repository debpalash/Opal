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
    return open(fp, encoding="utf-8").read() if _os.path.exists(fp) else ""


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
    if "PKGS=(opal-media-player opal-media-player-bin)" not in sh or 'PKGS=("$@")' not in sh:
        return "fail", "expected an explicit $#-guarded default package list"

    # Prove it, don't just grep for it: run the same shell snippet.
    import re, subprocess
    m = re.search(r'if \[\[ \$# -gt 0 \]\]; then\n.*?\nfi', sh, re.S)
    if not m:
        return "fail", "could not locate the package-list block to execute"
    snippet = m.group(0) + '\nprintf "%s\\n" "${PKGS[@]}"'
    shell = _posix_shell()
    if shell is None:
        return "skip", "package-list source guard passes; no POSIX shell for expansion probe"
    out = subprocess.run([shell, "-c", snippet, "_"], capture_output=True, text=True)
    got = out.stdout.split()
    if got != ["opal-media-player", "opal-media-player-bin"]:
        return "fail", f"default package list expands to {got!r}, want the two Opal media packages"
    return "pass", "default expands to the two uniquely named Opal media packages"


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
        "arch tooling installed": "pacman -Syu --noconfirm --needed git openssh pacman-contrib sudo" in wf,
        # makepkg and updpkgsums refuse to run as root.
        "non-root makepkg user": "useradd -m builder" in wf and "sudo -H -u builder" in wf,
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


@test("AUR packages load and can search after install", "Packaging")
def test_aur_packages_runtime_contract():
    # Ported from the unmerged packaging-and-search-fixes branch (48da9ac3).
    # 1. The source package pre-built libtorrent_wrapper.so with a g++ line that
    #    lacked -Wl,-soname. build.zig skips an up-to-date .so, so that unnamed
    #    one was linked: DT_NEEDED became the absolute $srcdir path and the
    #    installed binary could not load once makepkg removed $srcdir.
    # 2. Every g++ wrapper link bypasses makepkg's hardening LDFLAGS, so namcap
    #    reported the wrapper as lacking full RELRO.
    # 3. Torrent search shells out to python3 engines/nova2.py, yet python was
    #    only an optdepend.
    import re, shutil, subprocess
    src_pkg = _read("packaging/aur/opal-media-player/PKGBUILD")
    bin_pkg = _read("packaging/aur/opal-media-player-bin/PKGBUILD")
    bld = _read("build.zig")
    sh = _read("packaging/aur/push-to-aur.sh")
    nfpm = _read("packaging/nfpm.yaml")
    if not src_pkg or not bin_pkg:
        return "fail", "AUR PKGBUILDs missing"

    def code(text):
        return "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))

    linux_wrapper = next((ln for ln in bld.splitlines()
                          if "g++" in ln and "libtorrent_wrapper.so" in ln and "-Wl,-soname" in ln), "")
    deb_deps = nfpm.split("  deb:", 1)[-1].split("  archlinux:", 1)[0]
    arch_deps = nfpm.split("  archlinux:", 1)[-1]
    checks = {
        "source package leaves the wrapper to build.zig": "g++" not in code(src_pkg)
            and "zig build" in code(src_pkg),
        "build.zig wrapper has SONAME + full RELRO": "-Wl,-z,relro -Wl,-z,now" in linux_wrapper,
        "-bin wrapper rebuild has SONAME + full RELRO": "-Wl,-soname,libtorrent_wrapper.so" in bin_pkg
            and "-Wl,-z,relro -Wl,-z,now" in bin_pkg,
        "new pkgver resets pkgrel": "s/^pkgrel=.*/pkgrel=1/" in sh,
        "deb depends on python3": re.search(r"^\s*- python3\s*$", deb_deps, re.M) is not None,
        "arch nfpm depends on python": re.search(r"^\s*- python\s*$", arch_deps, re.M) is not None,
    }
    bad = [k for k, ok in checks.items() if not ok]
    if bad:
        return "fail", "AUR runtime contract: " + ", ".join(bad)

    # Evaluate the arrays the way makepkg does rather than grepping them.
    bash = shutil.which("bash")
    if bash is None:
        return "skip", "source contract passes; no bash to evaluate PKGBUILD arrays"
    for rel in ("packaging/aur/opal-media-player/PKGBUILD", "packaging/aur/opal-media-player-bin/PKGBUILD"):
        out = subprocess.run([bash, "-c", 'source "$1"; printf "%s\\n" "${depends[@]}"', "_",
                              _os.path.join(PROJECT_DIR, rel)], capture_output=True, text=True)
        if out.returncode != 0 or "python" not in out.stdout.split():
            return "fail", f"{rel}: python is not in depends ({out.stdout.split()!r})"
    return "pass", "wrapper built once with SONAME + full RELRO; python is a hard dependency"
