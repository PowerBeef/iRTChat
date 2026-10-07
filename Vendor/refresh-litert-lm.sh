#!/bin/sh
# Refresh the vendored LiteRT-LM Swift package surface from an upstream tag.
# Usage: TAG=v0.19.0 ./Vendor/refresh-litert-lm.sh
set -eu
TAG="${TAG:?Set TAG, e.g. TAG=v0.19.0 $0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -sL --fail -o "$TMP/litertlm.tar.gz" \
  "https://github.com/google-ai-edge/LiteRT-LM/archive/refs/tags/${TAG}.tar.gz"
tar xzf "$TMP/litertlm.tar.gz" -C "$TMP"
SRC="$TMP/LiteRT-LM-${TAG#v}"
rm -rf "$ROOT/Vendor/LiteRT-LM"
mkdir -p "$ROOT/Vendor/LiteRT-LM"
cp "$SRC/Package.swift" "$SRC/LICENSE" "$ROOT/Vendor/LiteRT-LM/"
cp -r "$SRC/swift" "$ROOT/Vendor/LiteRT-LM/swift"
echo "Vendored $TAG into Vendor/LiteRT-LM ($(du -sh "$ROOT/Vendor/LiteRT-LM" | cut -f1))"
