#!/bin/zsh
# 맥: QuickLook Video(QLVideo, GPL-2.0 이상, Jonathan Harris — github.com/Marginal/QuickLookVideo) 공식 배포판에서
# 미디어 확장 2개(형식 읽기·영상 디코더)와 Spotlight 플러그인을 꺼내 iRayer 에 넣을 준비를 한다.
# → Finder 썸네일·스페이스바 미리보기·QuickTime 이 MKV·AVI·WMV 등을 열게 된다. QuickLook Video 앱을 따로 깔 필요가 없다.
#
# - 빌드는 하지 않는다: 그쪽이 공증까지 마친 바이너리를 그대로 쓰고, arm64 만 남긴다 (iRayer 는 애플 실리콘 전용).
# - 번들 ID 는 iRayer 아래(com.moimz.iRayer.…)로 바꾸고, 서명은 iRayer 빌드가 다시 한다 (확장 대상 QLVideoFormats·QLVideoCodecs).
# - iRayer 코드와 링크하지 않는 별개 실행 파일이라 iRayer 는 MIT 그대로. 고지는 QLVideo/README.md.
# - 결과: Vendor/mac/QLVideo (git 에서 빠짐)
#
# 사용: Scripts/fetch-qlvideo.sh            (새 버전이 나오면 아래 VERSION 만 바꾸고 다시 돌린다)
set -eu
VERSION=313                                  # QLVideo 릴리즈 태그 rel-313 = 3.13
ROOT=${0:A:h:h}
OUT=$ROOT/Vendor/mac/QLVideo
WORK=$(mktemp -d)
trap 'hdiutil detach "$WORK/mnt" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

echo "QLVideo $VERSION 받기…"
curl -fsSL -o "$WORK/q.dmg" "https://github.com/Marginal/QuickLookVideo/releases/download/rel-$VERSION/QLVideo_$VERSION.dmg"
hdiutil attach -nobrowse -readonly -mountpoint "$WORK/mnt" "$WORK/q.dmg" >/dev/null
SRC="$WORK/mnt/QuickLook Video.app/Contents"
# 받은 것이 그쪽 Developer ID 서명 그대로인지 확인 (팀 R8954VZGV2)
codesign --verify --deep --strict "$SRC/.." && codesign -dvv "$SRC/.." 2>&1 | grep -q "TeamIdentifier=R8954VZGV2" \
    || { echo "서명 확인 실패"; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT/Frameworks"
thin() {   # 범용 → arm64, 서명은 지운다 (iRayer 빌드가 다시 서명)
    local f=$1
    file -b "$f" | grep -q Mach-O || return 0
    lipo -archs "$f" | grep -q x86_64 && lipo -thin arm64 "$f" -output "$f"
    codesign --remove-signature "$f" 2>/dev/null || true
}

# 1. FFmpeg 등 라이브러리 (두 확장이 @executable_path/../../../../Frameworks 에서 찾는다 = iRayer.app/Contents/Frameworks)
ditto "$SRC/Frameworks" "$OUT/Frameworks"
for f in "$OUT/Frameworks/"*.dylib; do thin "$f"; done

# 2. 미디어 확장: 실행 파일·리소스, Info.plist 는 Xcode 확장 대상이 쓸 원본으로
appex() {   # appex() <원래 이름> <대상 폴더> <새 번들 ID 끝>
    local A="$SRC/Extensions/$1.appex/Contents" D="$OUT/$2"
    mkdir -p "$D"
    ditto "$A/MacOS/$1" "$D/executable"; thin "$D/executable"
    [[ -d "$A/Resources" ]] && ditto "$A/Resources" "$D/Resources"
    cp "$A/Info.plist" "$D/Info.plist"; plutil -convert xml1 "$D/Info.plist"
    local P="$D/Info.plist"
    for k in BuildMachineOSBuild DTCompiler DTPlatformBuild DTPlatformName DTPlatformVersion DTSDKBuild DTSDKName DTXcode DTXcodeBuild CFBundleSupportedPlatforms; do
        /usr/libexec/PlistBuddy -c "Delete :$k" "$P" 2>/dev/null || true
    done
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier $(PRODUCT_BUNDLE_IDENTIFIER)' "$P"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable $(EXECUTABLE_NAME)' "$P"
    /usr/libexec/PlistBuddy -c "Set :EXAppExtensionAttributes:ClassImplementationID com.moimz.iRayer.$3" "$P"
    # 확장이 Info.plist 의 ApplicationGroup 으로 설정을 읽는다 → iRayer 팀 그룹 (엔타이틀먼트와 같아야 함)
    /usr/libexec/PlistBuddy -c 'Set :ApplicationGroup $(TeamIdentifierPrefix)com.moimz.iRayer' "$P"
}
appex "QLVideo Formats" Formats formatreader
appex "QLVideo Codecs" Codecs videodecoder

# 3. Spotlight 플러그인 (iRayer.app/Contents/Library/Spotlight 에 그대로 넣고 서명만 다시)
M="$OUT/QLVideo Metadata.mdimporter"
ditto "$SRC/Library/Spotlight/QLVideo Metadata.mdimporter" "$M"
rm -rf "$M/Contents/_CodeSignature"
thin "$M/Contents/MacOS/QLVideo Metadata"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.moimz.iRayer.mdimporter" "$M/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :ApplicationGroup XSDBV8D2XL.com.moimz.iRayer" "$M/Contents/Info.plist"

# 4. 상태 확인용 작은 영상 (VP8 WebM — macOS 기본으로는 못 연다. 확장이 켜져 있으면 열림)
cp "$SRC/Resources/test-vp8-vorbis-webvtt.webm" "$OUT/qlvideo-test.webm"

echo "rel-$VERSION" > "$OUT/VERSION"
echo "끝: $OUT ($(du -sh "$OUT" | cut -f1), QLVideo $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SRC/Info.plist"))"
