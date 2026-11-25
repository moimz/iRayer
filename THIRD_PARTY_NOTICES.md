# 오픈 소스 고지 (Third-Party Notices)

iRayer 의 코드는 [MIT 라이선스](LICENSE)입니다. 앱에는 아래 라이브러리·글꼴이 함께 들어 있으며, 각각 자기 라이선스를 따릅니다.
라이선스 전문은 [iRayer/Licenses](iRayer/Licenses) 와 [iRayer/Fonts](iRayer/Fonts) 에 있고, 앱 안의 "iRayer에 관하여"에서도 볼 수 있습니다.

| 이름 | 라이선스 | 쓰는 곳 | 소스 |
|---|---|---|---|
| VLCKit 3.7.3 (맥) · MobileVLCKit 3.7.3 (아이폰·아이패드) — VideoLAN | LGPL 2.1 이상 | 영상 재생 | https://code.videolan.org/videolan/VLCKit |
| FFmpeg 8.0 (맥) | LGPL 2.1 이상 | 웹에서 받은 영상 조각 묶기 | https://ffmpeg.org — 빌드 설정: [Scripts/build-ffmpeg.sh](Scripts/build-ffmpeg.sh) |
| Sparkle 2.10.1 (맥) | MIT | 자동 업데이트 | https://sparkle-project.org |
| QuickLook Video 3.13 (맥) — Jonathan Harris | GPL 2.0 이상 | Finder 썸네일·미리보기, Spotlight 정보 (미디어 확장 2개·Spotlight 플러그인, 그 안의 FFmpeg·dav1d·zimg 라이브러리) | https://github.com/Marginal/QuickLookVideo (태그 `rel-313`) |
| AMSMB2 4.0.3 · libsmb2 | LGPL 2.1 | SMB(윈도우 공유 폴더) 접속 | https://github.com/amosavian/AMSMB2 |
| Unrar.swift 0.5.4 | MIT | RAR 만화 압축 풀기 | https://github.com/mtgto/Unrar.swift |
| UnRAR — Alexander Roshal | UnRAR 라이선스 | 〃 | https://www.rarlab.com/rar_add.htm |
| 나눔고딕·나눔명조·나눔바른고딕·나눔바른펜 — 네이버 | SIL OFL 1.1 | 자막·텍스트 뷰어 글꼴 | https://hangeul.naver.com |
| 마루부리 — 네이버 | SIL OFL 1.1 | 텍스트 뷰어 글꼴 | https://hangeul.naver.com |

## LGPL 라이브러리

- VLCKit·MobileVLCKit·AMSMB2 는 앱 안에 따로 된 동적 프레임워크(`Frameworks/*.framework`)로 들어 있어, 같은 이름의 다른 빌드로 바꿔 넣을 수 있습니다.
- FFmpeg 는 따로 된 실행 파일(`Contents/Helpers/ffmpeg`)로 들어 있고, GPL·nonfree 부분 없이(`--enable-gpl` 없음) 빌드했습니다. 위 스크립트로 같은 것을 다시 만들 수 있습니다.
- 각 라이브러리의 소스는 위 주소에서 받을 수 있습니다. 앱에 넣은 바이너리는 손대지 않은 공식 배포판(VLCKit) 또는 공식 소스로 빌드한 것입니다.

## GPL 프로그램 (맥)

- QuickLook Video 는 iRayer 코드와 링크하지 않는 별개 프로그램으로 앱 안에 함께 들어 있습니다: `Contents/Extensions/QLVideo Formats.appex`·`QLVideo Codecs.appex`, `Contents/Library/Spotlight/QLVideo Metadata.mdimporter`, 그리고 두 확장이 쓰는 `Contents/Frameworks/lib*.dylib`.
- 공식 배포판(`QLVideo_313.dmg`)의 바이너리를 그대로 쓰고, 애플 실리콘용만 남기고 번들 ID 를 바꿔 다시 서명한 것 말고는 손대지 않았습니다. 과정: [Scripts/fetch-qlvideo.sh](Scripts/fetch-qlvideo.sh).
- 해당 버전의 소스(하위 모듈·패치 포함)는 https://github.com/Marginal/QuickLookVideo/tree/rel-313 에 있습니다. 라이선스 전문: [iRayer/Licenses/GPL-2.0.txt](iRayer/Licenses/GPL-2.0.txt).

## 영화·TV 정보

이 앱은 TMDB API 를 쓰지만 TMDB 의 보증이나 인증을 받지 않았습니다.
This product uses the TMDB API but is not endorsed or certified by TMDB. — https://www.themoviedb.org
