#!/bin/sh
# Build the body of a GitHub Release: hand-written highlights + every commit.
#
# Every release up to v0.6.4 shipped with a body of exactly one line —
# "**Full Changelog**: …compare/v0.6.2...v0.6.3" — because the publish job just
# set `generate_release_notes: true` and the repo has no PRs for GitHub to
# summarise. Anyone deciding whether to update had to read a diff of 54 commits
# to find out what changed.
#
# Two halves, because they answer different questions:
#
#   Highlights — what a USER gets. Hand-written, one section per version in
#                CHANGELOG.md. A generator cannot know that four commits are
#                one feature, or which of them anybody cares about.
#   Changes    — what actually landed. Generated from git so it can never drift
#                or omit anything; grouped by conventional-commit type, with the
#                internal churn (test/chore/refactor/docs/ci) folded away.
#
# Usage:
#   scripts/release-notes.sh <tag> [prev-tag]      # prev defaults to the tag before it
#
# `tag` names the compare link and selects the CHANGELOG section; it does NOT
# have to exist as a git ref, so this can be run on a range before tagging (and
# so the test suite can exercise it in a shallow CI checkout with no tags).
set -eu

TAG="${1:-}"
if [ -z "$TAG" ]; then
    echo "usage: $0 <tag> [prev-tag]" >&2
    exit 2
fi
REPO="${OPAL_REPO:-debpalash/Opal}"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CHANGELOG="$ROOT/CHANGELOG.md"

# Resolve the range. An unknown tag (not fetched, or not created yet) resolves
# to HEAD so the generator still produces a usable body instead of dying inside
# the release job.
if git -C "$ROOT" rev-parse -q --verify "$TAG^{commit}" >/dev/null 2>&1; then
    END="$TAG"
else
    END="HEAD"
fi
PREV="${2:-}"
if [ -z "$PREV" ]; then
    PREV=$(git -C "$ROOT" describe --tags --abbrev=0 "$END^" 2>/dev/null || true)
fi
if [ -n "$PREV" ]; then RANGE="$PREV..$END"; else RANGE="$END"; fi

# ── Highlights ────────────────────────────────────────────────────────────
# The section for this exact version, verbatim, minus its own heading. A
# missing section is not fatal — the release still ships, with the commit list
# doing the talking — but it is worth a visible note so it gets written.
highlights=""
if [ -f "$CHANGELOG" ]; then
    highlights=$(awk -v want="$TAG" '
        /^## / {
            # "## v0.6.4 — 2026-08-06" → compare the version token only.
            in_sec = ($2 == want)
            next
        }
        in_sec { print }
    ' "$CHANGELOG" | sed -e '/./,$!d')
    # Trim trailing blank lines.
    highlights=$(printf '%s\n' "$highlights" | awk 'NF {p = NR} {l[NR] = $0} END {for (i = 1; i <= p; i++) print l[i]}')
fi

printf '## Highlights\n\n'
if [ -n "$highlights" ]; then
    printf '%s\n\n' "$highlights"
else
    printf '_No highlights were written for %s — see the changes below._\n\n' "$TAG"
fi

# ── Changes ───────────────────────────────────────────────────────────────
# One pass over the log; each commit is bucketed by its conventional-commit
# type. Anything unprefixed lands in "Other" rather than being dropped — a
# changelog that silently omits commits is worse than an untidy one.
log=$(git -C "$ROOT" log --no-merges --format='%h%x09%s' "$RANGE" 2>/dev/null || true)

# Scope handling stays in sed rather than awk: `match(str, re, arr)` is a gawk
# extension and this script also runs on macOS's one-true-awk.
bucket() {
    # $1 = heading, $2 = alternation of conventional types
    body=$(printf '%s\n' "$log" | grep -E "$(printf '\t')($2)(\(|!?:)" || true)
    [ -n "$body" ] || return 0
    printf '### %s\n\n' "$1"
    printf '%s\n' "$body" | while IFS="$(printf '\t')" read -r sha subject; do
        [ -n "$sha" ] || continue
        clean=$(printf '%s' "$subject" | sed -E 's/^[a-z]+(\([^)]*\))?!?: *//')
        scope=$(printf '%s' "$subject" | sed -nE 's/^[a-z]+\(([^)]*)\)!?:.*/\1/p')
        if [ -n "$scope" ]; then
            printf -- '- **%s** — %s (`%s`)\n' "$scope" "$clean" "$sha"
        else
            printf -- '- %s (`%s`)\n' "$clean" "$sha"
        fi
    done
    printf '\n'
}

total=$(printf '%s\n' "$log" | grep -c . || true)
printf '## Changes\n\n'
if [ "${total:-0}" -eq 0 ]; then
    printf '_No commits in %s._\n\n' "$RANGE"
else
    bucket "Features" "feat" ""
    bucket "Fixes" "fix" ""
    bucket "Performance" "perf" ""
    bucket "Reverts" "revert" ""
    bucket "Other" "build|style" ""

    # Internal churn is real work but not release-note material; it goes in a
    # fold so the list stays complete without burying the two sections above.
    internal=$(printf '%s\n' "$log" | grep -E "$(printf '\t')(test|chore|refactor|docs|ci)(\(|!?:)" || true)
    if [ -n "$internal" ]; then
        n=$(printf '%s\n' "$internal" | grep -c .)
        if [ "$n" -eq 1 ]; then noun=commit; else noun=commits; fi
        printf '<details>\n<summary>Internal (%s %s — tests, refactors, CI, docs)</summary>\n\n' "$n" "$noun"
        printf '%s\n' "$internal" | while IFS="$(printf '\t')" read -r sha subject; do
            [ -n "$sha" ] || continue
            printf -- '- %s (`%s`)\n' "$subject" "$sha"
        done
        printf '\n</details>\n\n'
    fi
fi

# ── Footer ────────────────────────────────────────────────────────────────
printf -- '---\n\n'
printf 'Install: `curl -fsSL https://raw.githubusercontent.com/%s/main/scripts/install.sh | sh`\n' "$REPO"
printf 'Verify a download against `SHA256SUMS.txt` below.\n\n'
if [ -n "$PREV" ]; then
    printf '**Full Changelog**: https://github.com/%s/compare/%s...%s\n' "$REPO" "$PREV" "$TAG"
fi
