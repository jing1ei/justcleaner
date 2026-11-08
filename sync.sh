#!/bin/bash
# Refresh the files served by the install page. Deployment is a separate step.
set -euo pipefail
cd "$(dirname "$0")"
if [ "$#" -ne 0 ]; then
  printf 'Usage: ./sync.sh (packages locally; does not commit or deploy)\n' >&2
  exit 2
fi
ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/justcleaner-source.XXXXXX")"
trap 'rm -f "$ARCHIVE"' EXIT
COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" .github Sources Tests assets docs build.sh install.sh sync.sh release.sh .gitignore README.md site/index.html
mkdir -p site
mv "$ARCHIVE" site/justcleaner-src.tar.gz
cp install.sh site/install.sh
printf 'Updated site/justcleaner-src.tar.gz and site/install.sh.\n'
