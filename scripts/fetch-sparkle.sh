#!/bin/bash
# Fetch the official Sparkle release and verify GitHub's published asset digest.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=2.10.1
SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
ARCHIVE="$PWD/vendor/cache/Sparkle-$VERSION.tar.xz"
OUTPUT="$PWD/vendor/sparkle"
mkdir -p "$(dirname "$ARCHIVE")"
if [[ ! -f "$ARCHIVE" ]]; then
    trap 'rm -f "$ARCHIVE.download"' EXIT
    curl --fail --location --retry 3 "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "$ARCHIVE.download"
    mv "$ARCHIVE.download" "$ARCHIVE"
    trap - EXIT
fi
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 --check
STAGING=$(mktemp -d "$PWD/vendor/.sparkle.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
tar -xJf "$ARCHIVE" -C "$STAGING" ./Sparkle.framework ./bin ./LICENSE
[[ -x "$STAGING/bin/generate_keys" && -x "$STAGING/bin/sign_update" && -x "$STAGING/bin/generate_appcast" ]]
rm -rf "$OUTPUT"
mv "$STAGING" "$OUTPUT"
trap - EXIT
printf 'Sparkle %s installed in %s\n' "$VERSION" "$OUTPUT"
