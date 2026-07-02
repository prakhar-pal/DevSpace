#!/usr/bin/env bash
#
# Apply the computed release to the working tree so the release workflow can
# commit it to the `release/main` branch:
#   1. bump Info.plist CFBundleShortVersionString to the next version
#   2. prepend a dated, grouped section to CHANGELOG.md
#
# Exits 1 (no-op) when there is nothing to release. Prints the new version to
# stdout on success.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

eval "$(scripts/next-version.sh)" # sets: bump, version
if [ "$bump" = "none" ]; then
    echo "No releasable commits since the last tag; nothing to prepare." >&2
    exit 1
fi

last_tag="$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || true)"
if [ -n "$last_tag" ]; then range="${last_tag}..HEAD"; else range="HEAD"; fi

# 1) Info.plist bump (perl slurps the file so the key/string span two lines).
perl -0777 -pi -e \
    "s#(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)#\${1}${version}\${2}#" \
    Info.plist

# 2) Build the grouped changelog section.
features=""
fixes=""
others=""
while IFS=$'\t' read -r sha subject; do
    [ -z "$subject" ] && continue
    case "$subject" in
        "chore: release v"*) continue ;;
    esac
    entry="- ${subject} (${sha:0:7})"
    if printf '%s' "$subject" | grep -qE '^feat(\([^)]*\))?!?:'; then
        features+="${entry}"$'\n'
    elif printf '%s' "$subject" | grep -qE '^(fix|perf|refactor)(\([^)]*\))?!?:'; then
        fixes+="${entry}"$'\n'
    else
        others+="${entry}"$'\n'
    fi
done < <(git log --no-merges --format='%H%x09%s' "$range")

section="## v${version} - $(date -u +%Y-%m-%d)"$'\n'
[ -n "$features" ] && section+=$'\n### Features\n'"${features}"
[ -n "$fixes" ] && section+=$'\n### Fixes\n'"${fixes}"
[ -n "$others" ] && section+=$'\n### Other\n'"${others}"

# 3) Prepend the section below the top-level title, above existing entries.
tmp="$(mktemp)"
if head -1 CHANGELOG.md | grep -q '^# '; then
    head -1 CHANGELOG.md >"$tmp"
    echo >>"$tmp"
    printf '%s\n' "$section" >>"$tmp"
    tail -n +2 CHANGELOG.md >>"$tmp"
else
    printf '%s\n' "$section" >"$tmp"
    cat CHANGELOG.md >>"$tmp"
fi
mv "$tmp" CHANGELOG.md

echo "$version"
