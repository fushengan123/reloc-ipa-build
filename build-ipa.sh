#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate

xcodebuild build \
  -project Reloc.xcodeproj \
  -scheme Reloc \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO

mkdir -p build/Payload
cp -R build/DerivedData/Build/Products/Release-iphoneos/Reloc.app build/Payload/
(cd build && zip -qry Reloc-ready.ipa Payload)

echo "IPA: $(pwd)/build/Reloc-ready.ipa"
