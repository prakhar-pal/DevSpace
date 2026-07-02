#!/usr/bin/env bash
#
# Compute the next release version from conventional-commit titles since the last
# `v*` tag. The base version is max(last tag, Info.plist) so a missing/stale tag
# (e.g. before the release workflow's tag-if-untagged step has ever run) can't
# regress the computed version below what's already shipped. Pure: reads git
# history + Info.plist, writes nothing. Prints two lines to stdout (shell-eval
# friendly):
#
#   bump=<major|minor|patch|none>
#   version=<X.Y.Z>
#
# Bump rule (highest wins): feat -> minor; fix|perf|refactor -> patch;
# a `!` type marker or a `BREAKING CHANGE` body -> major. While pre-1.0
# (major == 0) a "major" is applied as a minor. Merge commits and
# `chore: release` commits are ignored. `none` => nothing to release.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

current_version() {
    grep -A1 'CFBundleShortVersionString' Info.plist \
        | grep '<string>' \
        | sed -E 's/.*<string>([^<]*)<\/string>.*/\1/' \
        | head -1
}

# Compares two X.Y.Z versions; prints the greater one. Guards against a tag
# that lags Info.plist (e.g. the tag-if-untagged workflow step hasn't run yet,
# or a version was bumped by hand without a matching tag) so the computed
# base never regresses below what's already shipped.
greater_version() {
    IFS=. read -r a1 a2 a3 <<<"$1"
    IFS=. read -r b1 b2 b3 <<<"$2"
    for i in 1 2 3; do
        av="a${i}" bv="b${i}"
        if [ "${!av}" -gt "${!bv}" ]; then echo "$1"; return; fi
        if [ "${!av}" -lt "${!bv}" ]; then echo "$2"; return; fi
    done
    echo "$1"
}

last_tag="$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || true)"
plist_version="$(current_version)"
if [ -n "$last_tag" ]; then
    base="$(greater_version "${last_tag#v}" "$plist_version")"
    range="${last_tag}..HEAD"
else
    base="$plist_version"
    range="HEAD"
fi

# Classify the whole range with a few greps instead of forking per commit.
# Highest level wins (checked high→low). `chore: release` commits need no
# filtering — they never match the type regexes below.
subjects="$(git log --no-merges --format='%s' "$range")"
bodies="$(git log --no-merges --format='%b' "$range")"

max=0
if grep -qE '^[a-z]+(\([^)]*\))?!:' <<<"$subjects" \
    || grep -q 'BREAKING CHANGE' <<<"$bodies"; then
    max=3 # a `!` type marker or a `BREAKING CHANGE` footer -> major
elif grep -qE '^feat(\([^)]*\))?:' <<<"$subjects"; then
    max=2 # feat -> minor
elif grep -qE '^(fix|perf|refactor)(\([^)]*\))?:' <<<"$subjects"; then
    max=1 # fix|perf|refactor -> patch
fi

IFS=. read -r MA MI PA <<<"$base"
case "$max" in
    3) bump=major ;;
    2) bump=minor ;;
    1) bump=patch ;;
    *) bump=none ;;
esac

case "$bump" in
    major) if [ "$MA" -eq 0 ]; then MI=$((MI + 1)); PA=0; else MA=$((MA + 1)); MI=0; PA=0; fi ;;
    minor) MI=$((MI + 1)); PA=0 ;;
    patch) PA=$((PA + 1)) ;;
    none) : ;;
esac

echo "bump=${bump}"
echo "version=${MA}.${MI}.${PA}"
