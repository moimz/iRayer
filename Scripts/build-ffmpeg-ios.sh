#!/bin/zsh
# 아이폰·아이패드 썸네일 확장(iRayerThumbnail)용 최소 FFmpeg 를 공식 소스로 빌드한다.
# iNAS 의 Scripts/build-ffmpeg-ios.sh 를 그대로 가져옴 (2026-11-25) — 두 앱이 같은 구성을 쓴다.
#
# - 영상 한 장면만 뽑으면 되니 디코더·디먹서·swscale 만 켠다. 네트워크·외부 라이브러리·GPL 구성 요소 없음 (LGPL).
# - 필요한 도구: Xcode 의 clang, make. Homebrew 패키지는 필요 없다.
# - 결과: Vendor/FFmpeg.xcframework (아이폰 arm64 + 시뮬레이터 arm64 정적 라이브러리, git 에서 빠짐) + Vendor/FFmpeg-LICENSE
#   iNAS 에서 이미 빌드했으면 그 Vendor/FFmpeg.xcframework 를 복사해 써도 된다.
#
# 사용: Scripts/build-ffmpeg-ios.sh [작업 폴더]   (기본: 임시 폴더, 끝나면 지움)
set -euo pipefail

VERSION=8.0
ROOT=${0:A:h:h}
VENDOR="$ROOT/Vendor"
WORK=${1:-$(mktemp -d)}
CLEAN_WORK=$([[ $# -eq 0 ]] && echo 1 || echo 0)

DECODERS=h264,hevc,mpeg4,mpeg2video,mpeg1video,msmpeg4v1,msmpeg4v2,msmpeg4v3,wmv1,wmv2,wmv3,vc1,flv,vp6f,vp8,vp9,theora,mjpeg,h263,rv30,rv40,prores,av1
DEMUXERS=matroska,mov,avi,asf,flv,mpegts,mpegps,ogg,m4v,h264,hevc,rm,mpegvideo
PARSERS=h264,hevc,mpeg4video,mpegvideo,vc1,vp8,vp9,av1

mkdir -p "$WORK" "$VENDOR"
cd "$WORK"
[[ -f ffmpeg-$VERSION.tar.xz ]] || curl -fsSL -o ffmpeg-$VERSION.tar.xz "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
rm -rf ffmpeg-$VERSION
tar xf ffmpeg-$VERSION.tar.xz
SRC="$WORK/ffmpeg-$VERSION"

build() {
  local sdk=$1 target=$2 name=$3
  local dir="$WORK/$name"
  rm -rf "$dir"; mkdir -p "$dir/build"
  cd "$dir/build"
  "$SRC/configure" \
    --prefix="$dir/install" \
    --enable-cross-compile --target-os=darwin --arch=arm64 \
    --cc="$(xcrun --sdk $sdk -f clang)" --sysroot="$(xcrun --sdk $sdk --show-sdk-path)" \
    --extra-cflags="-target $target" --extra-ldflags="-target $target" \
    --disable-programs --disable-doc --disable-debug --disable-network --disable-autodetect \
    --disable-everything --disable-avdevice --disable-avfilter --disable-swresample \
    --enable-static --disable-shared --enable-pic \
    --enable-decoder=$DECODERS --enable-demuxer=$DEMUXERS --enable-parser=$PARSERS \
    --enable-swscale > "$dir/configure.log"
  make -j"$(sysctl -n hw.ncpu)" > "$dir/make.log" 2>&1
  make install > /dev/null
  libtool -static -o "$dir/libffmpeg.a" "$dir/install/lib/libavformat.a" "$dir/install/lib/libavcodec.a" \
    "$dir/install/lib/libswscale.a" "$dir/install/lib/libavutil.a" 2> /dev/null
  cd "$WORK"
}

build iphoneos arm64-apple-ios17.0 ios
build iphonesimulator arm64-apple-ios17.0-simulator sim

HEADERS="$WORK/headers"
rm -rf "$HEADERS"; mkdir -p "$HEADERS"
cp -R "$WORK/ios/install/include/"* "$HEADERS/"
cat > "$HEADERS/ffmpeg.h" <<'EOF'
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libswscale/swscale.h"
#include "libavutil/imgutils.h"
#include "libavutil/display.h"
EOF
cat > "$HEADERS/module.modulemap" <<'EOF'
module FFmpeg {
    header "ffmpeg.h"
    link "z"
    link "bz2"
    link "iconv"
    export *
}
EOF

rm -rf "$VENDOR/FFmpeg.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK/ios/libffmpeg.a" -headers "$HEADERS" \
  -library "$WORK/sim/libffmpeg.a" -headers "$HEADERS" \
  -output "$VENDOR/FFmpeg.xcframework" > /dev/null
cp "$SRC/COPYING.LGPLv2.1" "$VENDOR/FFmpeg-LICENSE"
echo "FFmpeg $VERSION (ffmpeg.org 공식 소스) 디코더: $DECODERS 디먹서: $DEMUXERS" > "$VENDOR/FFmpeg-BUILD.txt"

[[ $CLEAN_WORK == 1 ]] && rm -rf "$WORK"
du -sh "$VENDOR/FFmpeg.xcframework"
echo 완료
