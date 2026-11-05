#!/bin/bash
# Fetch the standalone CPython that Looking Glass ships, and print the path to its root folder.
# Usage: ./scripts/python-runtime.sh
#
# The app carries its own Python (Contents/Resources/python), so nothing Homebrew does can stop the sidecar from
# starting. This build comes from python-build-standalone: relocatable, and it links only macOS system libraries.
#
# To update: pick an aarch64-apple-darwin install_only_stripped build from
# https://github.com/astral-sh/python-build-standalone/releases and change the three values below (GitHub lists the
# sha256 beside each asset). Bump this at each release: a bundled Python only gets security fixes when we ship one.
#
# A new patch version (3.14.x) needs nothing else. A new minor version (3.15) changes the ABI: every wheel in
# sidecar/requirements-voice.txt needs a build for it, and users re-download the voice engine (runtimes/voice-py315).

set -euo pipefail

PY_VERSION="3.14.10"
PBS_RELEASE="20261026"
PBS_SHA256="95eb8c87d16af37c54e9765e31d8c56c0d8ffa9968ea0f704f73a9b83f84e9f9"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="$PROJECT_DIR/.python-runtime"
ROOT="$CACHE_DIR/cpython-$PY_VERSION+$PBS_RELEASE"

if [ ! -x "$ROOT/bin/python3" ]; then
    ASSET="cpython-$PY_VERSION%2B$PBS_RELEASE-aarch64-apple-darwin-install_only_stripped.tar.gz"
    URL="https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_RELEASE/$ASSET"

    mkdir -p "$CACHE_DIR"
    TMP="$(mktemp -d "$CACHE_DIR/.fetch.XXXXXX")"
    trap 'rm -rf "$TMP"' EXIT

    echo "  Downloading standalone Python $PY_VERSION..." >&2
    curl -fsSL -o "$TMP/python.tar.gz" "$URL"
    ACTUAL="$(shasum -a 256 "$TMP/python.tar.gz" | awk '{print $1}')"
    if [ "$ACTUAL" != "$PBS_SHA256" ]; then
        echo "ERROR: checksum mismatch for $ASSET (expected $PBS_SHA256, got $ACTUAL)" >&2
        exit 1
    fi
    tar xzf "$TMP/python.tar.gz" -C "$TMP"
    mv "$TMP/python" "$ROOT"
fi

printf '%s\n' "$ROOT"
