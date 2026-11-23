#!/bin/sh
# 빌드 번호 = git 커밋 수, 커밋 해시를 Info.plist 에 넣는다 (설정 화면 아래에 보인다).
# 아이폰·아이패드에 따로 설치해도 어느 커밋으로 만든 빌드인지 알 수 있게.
# 커밋하지 않은 변경이 있으면 해시 뒤에 "+" 를 붙인다.
# Info.plist 처리가 끝난 뒤에 돌도록 그 파일을 입력으로 둔다 (아니면 처리하면서 덮어쓴다)
cd "$SRCROOT" || exit 0
count=$(git rev-list --count HEAD 2>/dev/null) || exit 0
hash=$(git rev-parse --short HEAD 2>/dev/null)
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then hash="$hash+"; fi
plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $count" "$plist"
/usr/libexec/PlistBuddy -c "Delete :IRayerCommit" "$plist" >/dev/null 2>&1
/usr/libexec/PlistBuddy -c "Add :IRayerCommit string $hash" "$plist"
# beta 브랜치(VLCKit 4 시험)로 만든 빌드는 설정에 "1.0b" 처럼 보이게 표시만 남긴다 (버전 번호 자체는 숫자만 허용)
/usr/libexec/PlistBuddy -c "Delete :IRayerBeta" "$plist" >/dev/null 2>&1
# 2.1b 처럼 이름이 b 로 끝나는 브랜치(다음 버전 시험판)도 같이 "2.1b" 로 보인다
case "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" in
    beta|*b) /usr/libexec/PlistBuddy -c "Add :IRayerBeta bool true" "$plist" ;;
esac
