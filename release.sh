#!/bin/bash
# Build and package a verified source release and a universal app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
VERSION="$(sed -n 's/.*static let string = "\([^"]*\)".*/\1/p' Sources/Core/Environment.swift)"
./Tests/run.sh
./build.sh
ARCHS="$(lipo -archs build/JustCleaner.app/Contents/MacOS/JustCleaner)"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo 'Release requires both architectures.' >&2; exit 1; }
codesign --verify --deep build/JustCleaner.app
./sync.sh
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/justcleaner-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
SOURCE="$STAGE/JustCleaner-$VERSION"
mkdir -p "$SOURCE" dist
cp -R .github Sources Tests assets docs site README.md build.sh install.sh sync.sh release.sh .gitignore "$SOURCE/"
rm -f "$SOURCE/site/justcleaner-src.tar.gz"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$SOURCE" "$STAGE/JustCleaner-$VERSION-source.zip"
for arch in arm64 x64; do
  .github/scripts/package-macos.sh build/JustCleaner.app "$VERSION" "$arch" dist
done
mv "$STAGE/JustCleaner-$VERSION-source.zip" "dist/JustCleaner-$VERSION-source.zip"
(cd dist && shasum -a 256 "JustCleaner-$VERSION-source.zip" "JustCleaner-$VERSION-macOS-arm64.dmg" "JustCleaner-$VERSION-macOS-x64.dmg" > SHA256SUMS.txt)
printf 'Release: %s/dist\n' "$ROOT"
