#!/bin/zsh
# 맥 앱(웹에서 받은 영상 묶기)에 넣을 최소 ffmpeg를 (VideoGrabber 의 tools/build-ffmpeg.sh 에서 가져옴) 공식 소스로 빌드한다.
#
# - 받기(네트워크)는 앱(URLSession·웹뷰)이 하고, ffmpeg는 받아 둔 로컬 파일을 다시 묶는 데만 쓴다.
#   그래서 네트워크·외부 라이브러리·GPL 구성 요소 없이, 재포장(-c copy)에 필요한 것만 켠다. (LGPL)
# - 필요한 도구: Xcode의 clang, make. Homebrew 패키지는 필요 없다.
# - 결과: Vendor/mac/ffmpeg/ffmpeg (git 에서 빠짐, 맥 앱에 넣는다)  (소스와 중간 파일은 지운다)
#
# 사용: Scripts/build-ffmpeg.sh [작업 폴더]   (기본: 임시 폴더)
set -euo pipefail

VERSION=8.0
ARCH=$(uname -m)
ROOT=${0:A:h:h}
OUT_DIR="$ROOT/Vendor/mac/ffmpeg"
WORK=${1:-$(mktemp -d)}

mkdir -p "$WORK" "$OUT_DIR"
cd "$WORK"
[[ -f ffmpeg-$VERSION.tar.xz ]] || curl -fsSL -o ffmpeg-$VERSION.tar.xz "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
rm -rf ffmpeg-$VERSION
tar xf ffmpeg-$VERSION.tar.xz
cd ffmpeg-$VERSION

./configure \
  --disable-everything --disable-autodetect --disable-network \
  --disable-doc --disable-ffplay --disable-ffprobe --disable-debug \
  --enable-protocol=file,pipe,concat \
  --enable-demuxer=hls,dash,mov,mpegts,aac,mp3,matroska,flv,concat,ogg \
  --enable-muxer=mp4,mov,ipod,matroska,webm,mpegts,adts,mp3,opus,ogg \
  --enable-parser=h264,hevc,aac,av1,vp9,opus,mpegaudio \
  --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata \
  --enable-decoder=h264,hevc,vp9,aac,mp3,opus \
  --enable-filter=aresample,anull,null \
  --extra-cflags=-mmacosx-version-min=12.0 --extra-ldflags=-mmacosx-version-min=12.0

make -j"$(sysctl -n hw.ncpu)"
strip ffmpeg
cp ffmpeg "$OUT_DIR/ffmpeg"
cp COPYING.LGPLv2.1 "$OUT_DIR/LICENSE"
echo "ffmpeg $VERSION ($ARCH), configure: $(./ffmpeg -hide_banner -buildconf 2>/dev/null | tr -s ' \n' ' ')" > "$OUT_DIR/BUILD.txt"

cd /
[[ -z ${1:-} ]] && rm -rf "$WORK"
echo "완료: $OUT_DIR/ffmpeg"
