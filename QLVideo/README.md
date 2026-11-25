# QLVideo (맥 Finder 미리보기)

[QuickLook Video](https://github.com/Marginal/QuickLookVideo) (Jonathan Harris, GPL 2.0 이상)의 미디어 확장 2개와 Spotlight 플러그인을 iRayer 맥 앱에 넣기 위한 것.

- 바이너리는 공식 배포판에서 꺼낸다: `Scripts/fetch-qlvideo.sh` → `Vendor/mac/QLVideo` (git 에서 빠짐). 새 버전이 나오면 스크립트의 `VERSION` 만 바꾼다.
- Xcode 대상 `QLVideoFormats`·`QLVideoCodecs` 는 빈 확장이다. 빌드 단계(`Scripts/embed-qlvideo.sh`)가 그 안에 QLVideo 실행 파일을 넣고, Xcode 가 이 폴더의 엔타이틀먼트로 iRayer 팀 서명을 한다.
- iRayer 코드와 링크하지 않는 별개 프로그램이다 (iRayer 는 MIT 그대로). 고지: [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md), 전문: [iRayer/Licenses/GPL-2.0.txt](../iRayer/Licenses/GPL-2.0.txt).
