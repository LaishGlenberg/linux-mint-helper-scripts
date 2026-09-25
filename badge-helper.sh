#!/usr/bin/env bash
# badge-helper.sh — insert npm/CI badges under a README's H1 title.
#
# Run from the directory that contains README.md and package.json:
#
#   badge-helper.sh
#
# Reads the package name (including scope) from package.json and the GitHub
# owner/repo from repository.url (falling back to `git remote origin`), then
# (re)inserts three shields.io badges directly below the README title. Safe to
# re-run: existing badges are replaced, not duplicated.

set -euo pipefail

readme="README.md"
pkg="package.json"

die() { printf 'badge-helper: %s\n' "$*" >&2; exit 1; }

[[ -f "$pkg" ]] || die "no $pkg in $(pwd)"
[[ -f "$readme" ]] || die "no $readme in $(pwd)"
command -v jq >/dev/null 2>&1 || die "jq is required"

name=$(jq -r '.name // empty' "$pkg")
[[ -n "$name" ]] || die "could not read .name from $pkg"

repo_url=$(jq -r '.repository.url // .repository // empty' "$pkg")
if [[ -z "$repo_url" ]]; then
  repo_url=$(git config --get remote.origin.url 2>/dev/null || true)
fi
[[ -n "$repo_url" ]] || die "no repository.url in $pkg and no git remote"

slug=$(printf '%s' "$repo_url" |
  sed -E 's#^git\+##; s#^git@github\.com:#https://github.com/#; s#^https?://github\.com/##; s#\.git$##; s#/$##')
slug=${slug%%#*}
slug=${slug%%/tree/*}
[[ "$slug" == */* ]] || die "could not derive owner/repo from '$repo_url'"

badges=$(
  cat <<EOF
[![npm version](https://img.shields.io/npm/v/${name}.svg?logo=npm)](https://www.npmjs.com/package/${name})
[![Downloads](https://img.shields.io/npm/dm/${name}.svg?logo=npm)](https://www.npmjs.com/package/${name})
[![Build Status](https://github.com/${slug}/workflows/CI/badge.svg)](https://github.com/${slug}/actions)
EOF
)

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

awk -v badges="$badges" '
  BEGIN { badge_re = "(img\\.shields\\.io/npm/(v|dm)/|workflows/CI/badge\\.svg)" }
  skipping {
    if ($0 ~ /^[[:space:]]*$/) next
    if ($0 ~ badge_re) next
    skipping = 0
  }
  !done && /^# / {
    print
    print ""
    printf "%s\n", badges
    print ""
    done = 1
    skipping = 1
    next
  }
  $0 ~ badge_re { next }
  { print }
' "$readme" >"$tmp"

grep -q 'shields\.io/npm/v/' "$tmp" || die "no H1 title found in $readme"
grep -q . "$tmp" || die "refusing to write an empty $readme"

if cmp -s "$readme" "$tmp"; then
  echo "badge-helper: no changes needed"
else
  mv "$tmp" "$readme"
  echo "badge-helper: inserted badges for ${name} (${slug})"
fi
