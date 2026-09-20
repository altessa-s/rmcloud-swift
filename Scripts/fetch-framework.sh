#!/bin/bash
# Fetch one external package's framework from its latest release.
#
# The one thing this package depends on is a repository of its own — the logging
# facade (`rmlog-swift`) — and what the framework target links is the
# `.xcframework` it releases. The artefact is committed under ThirdParty/<name>/,
# so a clone builds with no network and no credentials; this script is what puts
# a newer one there. One framework per run, named by its module.
#
#   Scripts/fetch-framework.sh RMLog          # fetch if the release moved
#   Scripts/fetch-framework.sh RMLog --check  # say what would happen
#   Scripts/fetch-framework.sh RMLog --force  # fetch and replace regardless
#
# Why the download is by API asset id and not by the release's own URL: the
# repository is private, and GitHub then serves the browser URL
# (…/releases/download/<tag>/RMLog.xcframework.zip) 404 to any credential curl
# can present. The asset endpoint does serve it — with
# `Accept: application/octet-stream`, without which it answers with JSON
# metadata. That is also why the framework cannot be a remote SwiftPM binary
# target: SwiftPM requires a URL whose path ends in `.zip`, which the asset
# endpoint has no way to give it. Hence a script, and hence the artefact in the
# commit.
#
# Credentials: $GITHUB_TOKEN or $GH_TOKEN, else `machine api.github.com` in
# ~/.netrc. With none — or with no network — this is not an error: the committed
# artefact stands, and the build goes on. It is an error only when there is
# nothing committed to fall back to.
set -euo pipefail

cd "$(dirname "$0")/.."

# name → repository. Another one is one line here and a directory under
# ThirdParty/; nothing else in this script knows any one of them.
name="${1:-}"
case "$name" in
  RMLog) repo="altessa-s/rmlog-swift" ;;
  "")      echo "usage: $0 <RMLog> [--check|--force]" >&2; exit 2 ;;
  *)       echo "$0: no such framework: $name" >&2; exit 2 ;;
esac
shift

asset_name="$name.xcframework.zip"
dest="ThirdParty/$name"
framework="$dest/$name.xcframework"
# Committed beside the framework: which release it came from and what its bytes
# hashed to. It is what makes "the release moved" answerable without a download,
# and what makes the artefact's provenance a line in the diff rather than a
# thing somebody remembers.
stamp="$dest/$name.version"

mode="update"
case "${1:-}" in
  --check) mode="check" ;;
  --force) mode="force" ;;
  "") ;;
  *) echo "usage: $0 <RMLog> [--check|--force]" >&2; exit 2 ;;
esac

say() { printf '%s\n' "$*"; }
have_artefact() { [ -d "$framework" ]; }

# The token, from wherever this machine keeps it. Never echoed.
token=""
if [ -n "${GITHUB_TOKEN:-}" ]; then token="$GITHUB_TOKEN"
elif [ -n "${GH_TOKEN:-}" ]; then token="$GH_TOKEN"
elif [ -f "$HOME/.netrc" ]; then
  token=$(awk '
    $1 == "machine" { m = ($2 == "api.github.com") }
    m && $1 == "password" { print $2; exit }
  ' "$HOME/.netrc")
fi

# Nothing to authenticate with. Not fatal — that is the point of committing the
# artefact — but say so, because a stale framework that nobody was told about is
# how a fixed parser bug comes back.
if [ -z "$token" ]; then
  if have_artefact; then
    say "$name: no GitHub credentials; keeping the committed $(awk -F'= *' '$1 ~ /^tag/ {print $2}' "$stamp" 2>/dev/null || echo artefact)"
    exit 0
  fi
  cat >&2 <<MSG
$name: no framework in $dest and no GitHub credentials to fetch one.

Set GITHUB_TOKEN to a token that can read $repo (fine-grained: Contents
read), or add to ~/.netrc:

    machine api.github.com
      login x-access-token
      password <token>
MSG
  exit 1
fi

api() { curl -sS --fail-with-body -H "Authorization: Bearer $token" \
                 -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }

# The latest release, prereleases included: a parser at 0.x is going to have
# them, and `/releases/latest` skips them silently — which would pin this
# application to an old tag with nothing on screen to say why.
release_json=$(api "https://api.github.com/repos/$repo/releases?per_page=1" || true)
if [ -z "$release_json" ] || [ "${release_json:0:1}" != "[" ]; then
  if have_artefact; then
    say "$name: could not reach GitHub; keeping the committed artefact"
    exit 0
  fi
  say "$name: could not reach GitHub, and there is no committed artefact" >&2
  exit 1
fi

read -r tag asset_id asset_size <<EOF
$(printf '%s' "$release_json" | python3 -c '
import json, sys
rs = json.load(sys.stdin)
if not rs:
    print("- - -"); raise SystemExit
r = rs[0]
a = next((a for a in r.get("assets", []) if a["name"] == "'"$asset_name"'"), None)
print(r.get("tag_name", "-"), a["id"] if a else "-", a["size"] if a else "-")
')
EOF

# A package that has only just left this repository has no release yet, and a
# release can exist without the artefact. Both are ordinary states, not errors.
if [ "$tag" = "-" ] || [ "$asset_id" = "-" ]; then
  why="has no release yet"
  [ "$tag" = "-" ] || why="release $tag carries no $asset_name"
  if have_artefact; then
    say "$name: $repo $why; keeping what is committed"
    exit 0
  fi
  say "$name: $repo $why, and there is no committed artefact" >&2
  exit 1
fi

current=""
[ -f "$stamp" ] && current=$(awk -F'= *' '$1 ~ /^tag/ {print $2}' "$stamp")

if [ "$mode" != "force" ] && [ "$current" = "$tag" ] && have_artefact; then
  say "$name: $tag, up to date"
  exit 0
fi

if [ "$mode" = "check" ]; then
  say "$name: ${current:-nothing} committed, $tag released — run 'Scripts/fetch-framework.sh <name>'"
  exit 0
fi

say "$name: fetching $tag ($asset_size bytes)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

api -L -H "Accept: application/octet-stream" \
    -o "$work/$asset_name" \
    "https://api.github.com/repos/$repo/releases/assets/$asset_id"

sha=$(shasum -a 256 "$work/$asset_name" | cut -d' ' -f1)
unzip -q "$work/$asset_name" -d "$work/unpacked"
new="$work/unpacked/$name.xcframework"
[ -d "$new" ] || { say "$name: $asset_name holds no $name.xcframework" >&2; exit 1; }

# The two properties the application cannot do without, checked here rather than
# discovered at link time: a static slice is refused by Xcode's copy phase when
# the framework is embedded, and a single-slice one fails the release link of a
# universal app.
binary="$new/macos-arm64_x86_64/$name.framework/Versions/A/$name"
[ -f "$binary" ] || binary=$(find "$new" -type f -name "$name" -perm +111 | head -1)
case "$(file -b "$binary")" in
  *"dynamically linked shared library"*) ;;
  *) say "$name: $tag is not a dynamic framework: $(file -b "$binary")" >&2; exit 1 ;;
esac
archs=$(lipo -archs "$binary")
case "$archs" in
  *arm64*x86_64*|*x86_64*arm64*) ;;
  *) say "$name: $tag has only [$archs]; a universal app needs both" >&2; exit 1 ;;
esac

mkdir -p "$dest"
rm -rf "$framework"
mv "$new" "$framework"
cat > "$stamp" <<EOF
tag = $tag
sha256 = $sha
asset = $asset_name (id $asset_id, $asset_size bytes)
repo = https://github.com/$repo
fetched by Scripts/fetch-framework.sh — do not edit by hand
EOF

say "$name: $tag in $framework ($archs)"
say "$name: commit $dest — the framework is part of this repository's build"
