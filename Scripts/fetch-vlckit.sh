#!/bin/zsh
# VLCKit(MobileVLCKit) 을 내려받아 Vendor/ 에 풀어 둔다. Vendor/ 는 용량이 커서 git 에서 제외되어 있다.
set -euo pipefail

VERSION="3.7.3-319ed2c0-79128878"
URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-${VERSION}.tar.xz"
ROOT="${0:A:h:h}"
VENDOR="$ROOT/Vendor"

if [[ -d "$VENDOR/MobileVLCKit.xcframework" ]]; then
    echo "이미 있음: $VENDOR/MobileVLCKit.xcframework"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fL -o "$TMP/vlckit.tar.xz" "$URL"
tar -xJf "$TMP/vlckit.tar.xz" -C "$TMP"
mkdir -p "$VENDOR"
mv "$TMP/MobileVLCKit-binary/MobileVLCKit.xcframework" "$VENDOR/"
echo "완료: $VENDOR/MobileVLCKit.xcframework"
