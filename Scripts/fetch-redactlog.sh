#!/bin/bash
# Put the RedactLog framework the xcframework build links into build/deps/.
#
# `Package.swift` takes RedactLog from its sources, pinned to a release tag, and
# SwiftPM resolves that by itself. The framework target in `project.yml` cannot:
# it links RedactLog without embedding it, so that the host's one copy serves
# both — and what it links against has to be that release's own dynamic
# framework, not a second build of the sources. This script fetches it.
#
# Which release, and what its bytes must hash to, is `Scripts/RedactLog.pin`.
# The version there has to be the one `Package.swift` pins: the package and the
# framework must not disagree about which logger they were built against, and
# this script refuses to go on if they do.
#
#   Scripts/fetch-redactlog.sh          # fetch unless the pinned one is there
#
# No credentials: the repository and its releases are public.
set -euo pipefail

cd "$(dirname "$0")/.."

pin="Scripts/RedactLog.pin"
version=$(awk -F'= *' '$1 ~ /^version/ {print $2}' "$pin")
checksum=$(awk -F'= *' '$1 ~ /^sha256/ {print $2}' "$pin")
[ -n "$version" ] && [ -n "$checksum" ] || { echo "$pin: no version or sha256" >&2; exit 1; }

# The manifest's pin and this one, side by side.
if ! grep -q "redactlog-swift.git\", exact: \"$version\"" Package.swift; then
  echo "Package.swift does not pin redactlog-swift to $version, as $pin does" >&2
  exit 1
fi

dest="build/deps"
framework="$dest/RedactLog.xcframework"
stamp="$dest/RedactLog.version"

if [ -d "$framework" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$version $checksum" ]; then
  echo "==> RedactLog $version already in $dest"
  exit 0
fi

url="https://github.com/altessa-s/redactlog-swift/releases/download/v$version/RedactLog.xcframework.zip"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "==> fetching RedactLog $version"
curl -sSL --fail -o "$work/RedactLog.xcframework.zip" "$url"

# The checksum SwiftPM would compute for the same archive: a release whose bytes
# changed is not the release that was pinned.
actual=$(shasum -a 256 "$work/RedactLog.xcframework.zip" | cut -d' ' -f1)
if [ "$actual" != "$checksum" ]; then
  echo "RedactLog $version hashes to $actual, $pin says $checksum" >&2
  exit 1
fi

unzip -q "$work/RedactLog.xcframework.zip" -d "$work/unpacked"
[ -d "$work/unpacked/RedactLog.xcframework" ] || { echo "the archive holds no RedactLog.xcframework" >&2; exit 1; }

mkdir -p "$dest"
rm -rf "$framework"
mv "$work/unpacked/RedactLog.xcframework" "$framework"
echo "$version $checksum" > "$stamp"
echo "==> RedactLog $version in $framework"
