#!/bin/sh
# QuickLook Video(QLVideo) 바이너리를 iRayer 맥 빌드에 넣는다. Vendor/mac/QLVideo 는 Scripts/fetch-qlvideo.sh 가 만든다.
#   embed-qlvideo.sh Formats|Codecs  — 확장 대상(QLVideoFormats·QLVideoCodecs)의 빌드 단계: 빈 appex 에 실행 파일·리소스를 넣는다.
#                                      서명은 그 뒤 Xcode 가 프로필·엔타이틀먼트(QLVideo/*.entitlements)로 한다.
#   embed-qlvideo.sh app             — iRayerMac 의 빌드 단계: FFmpeg 라이브러리·Spotlight 플러그인·확인용 영상을 넣고 서명한다.
set -e
Q="$SRCROOT/Vendor/mac/QLVideo"
[ -f "$Q/VERSION" ] || { echo "error: $Q 가 없음 — Scripts/fetch-qlvideo.sh 를 먼저 돌린다"; exit 1; }
B="$TARGET_BUILD_DIR"

case "$1" in
Formats|Codecs)
	mkdir -p "$B/$EXECUTABLE_FOLDER_PATH" "$B/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
	cp -f "$Q/$1/executable" "$B/$EXECUTABLE_PATH"
	ditto "$Q/$1/Resources" "$B/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
	;;
app)
	ID="${EXPANDED_CODE_SIGN_IDENTITY:--}"
	sign() { codesign --force --sign "$ID" --options runtime --timestamp=none "$1"; }
	F="$B/$FRAMEWORKS_FOLDER_PATH"; mkdir -p "$F"
	for d in "$Q/Frameworks/"*.dylib; do cp -f "$d" "$F/"; sign "$F/$(basename "$d")"; done
	S="$B/$CONTENTS_FOLDER_PATH/Library/Spotlight"; mkdir -p "$S"
	rm -rf "$S/QLVideo Metadata.mdimporter"
	ditto "$Q/QLVideo Metadata.mdimporter" "$S/QLVideo Metadata.mdimporter"
	sign "$S/QLVideo Metadata.mdimporter"
	cp -f "$Q/qlvideo-test.webm" "$B/$UNLOCALIZED_RESOURCES_FOLDER_PATH/"
	echo "QLVideo $(cat "$Q/VERSION") 넣음"
	;;
esac
