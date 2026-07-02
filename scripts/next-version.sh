#!/usr/bin/env bash
#
# Compute the next release version from conventional-commit titles since the last
# `v*` tag. Pure: reads git history + Info.plist, writes nothing. Prints two
# lines to stdout (shell-eval friendly):
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

# Rank a single commit subject: 3=major 2=minor 1=patch 0=none.
level_of() {
    local subject="$1"
    case "$subject" in
        "chore: release v"*) echo 0; return ;;
    esac
    if printf '%s' "$subject" | grep -qE '^[a-z]+(\([^)]*\))?!:'; then
        echo 3
    elif printf '%s' "$subject" | grep -qE '^feat(\([^)]*\))?:'; then
        echo 2
    elif printf '%s' "$subject" | grep -qE '^(fix|perf|refactor)(\([^)]*\))?:'; then
        echo 1
    else
        echo 0
    fi
}

last_tag="$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || true)"
if [ -n "$last_tag" ]; then
    base="${last_tag#v}"
    range="${last_tag}..HEAD"
else
    base="$(current_version)"
    range="HEAD"
fi

max=0
while IFS= read -r subject; do
    [ -z "$subject" ] && continue
    lvl="$(level_of "$subject")"
    [ "$lvl" -gt "$max" ] && max="$lvl"
done < <(git log --no-merges --format='%s' "$range")

# A `BREAKING CHANGE:` footer anywhere in the range forces major.
if git log --no-merges --format='%b' "$range" | grep -q 'BREAKING CHANGE'; then
    max=3
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
