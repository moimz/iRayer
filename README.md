# iRayer

아이폰·아이패드·맥에서 **NAS(SMB·WebDAV)에 있는 영상·만화·글을 라이브러리로 정리해 보는** 미디어 플레이어입니다. VLC 로 거의 모든 형식을 재생하고, 재생 위치·라이브러리·설정은 iCloud 로 기기끼리 이어집니다.

이름은 i + **Air** + Play**er** — "아이레이어" 라고 읽습니다.

*A media player for iPhone, iPad and Mac that organizes videos, comics and text on your NAS (SMB/WebDAV) into libraries, plays nearly any format via VLC, streams to Apple TV over AirPlay, and keeps everything in sync with iCloud. Korean UI only.*

## 기능

**라이브러리**
- NAS 폴더를 영화·TV·애니 등 라이브러리로 묶고, 포스터·줄거리·출연진을 TMDB(내 API 키)나 직접 만든 에이전트([규약](docs/에이전트%20규약.md))에서 가져옴
- 홈: 이어보기, 최근 추가, 장르·컬렉션, 즐겨찾는 인물, 재생목록
- 시즌·회차 정리, 회차 찾기, 본 것 표시, 성인 등급 숨기기(PIN)
- 폴더 그대로 둘러보기, 파일 옮기기·이름 바꾸기, 미리보기 그림

**재생 (VLC)**
- MKV·AVI·WMV·HEVC 등 대부분의 형식, 하드웨어 디코딩
- 자막: 영상 속·외부 자막, 글꼴·크기·가장자리, 싱크를 초 단위로 직접 입력(1분 넘게 어긋난 자막도)
- 오디오 트랙·싱크, 재생 속도, 다음 회차 단추, 레터박스를 영상 색으로 채우기
- **AirPlay**: 기기에서 VLC 로 풀고 바로 HLS 로 다시 묶어 Apple TV 로 보냄(어떤 형식이든, 자막 포함)
- 시스템 PiP(화면 속 화면)

**만화·글**
- 만화: 폴더·ZIP(암호 포함)·RAR, 자동 넘김
- 글: 텍스트 파일을 책처럼 (글꼴·크기·배경, 읽던 글자 위치를 기기끼리 이어 읽기)

**맥**
- 원본·2배·화면에 맞춤 크기, 항상 위에 두기, 전체 화면
- Apple TV 앱 보관함의 영화도 같은 라이브러리에
- **웹 탐색**: 탭, 즐겨찾기, 광고 차단(내가 쓴 규칙), 사이트별 브라우저 흉내(내가 쓴 규칙)
  - 페이지의 영상(HLS·DASH)을 찾아 받기, 받기 단추로 안 되는 플레이어는 재생되는 그대로 받기. DRM 이 걸린 영상은 받지 않습니다
  - 받는 중이면 Dock 아이콘에 개수·진행률
- **Finder 미리보기**: MKV·AVI·WMV 등도 Finder 썸네일·스페이스바 미리보기·QuickTime 으로 (QuickLook Video 의 확장을 넣음, 시스템 설정에서 켬)
- 자동 업데이트 (Sparkle)

**아이폰·아이패드 ↔ 맥**
- 폰에서 맥의 웹 탐색을 열어 영상을 찾고 맥에 받게 하기, 맥에서 받는 현황 보기

**공통**
- iCloud 동기화: 서버·라이브러리·재생 위치·본 기록·즐겨찾기·재생목록·설정 (비밀번호·키는 iCloud 키체인)
- 화면 모드(라이트·다크), 라이브러리마다 아이콘 고르기

## 요구 사항

- iOS / iPadOS 26 이상, macOS 26 이상 (맥 앱은 Apple 실리콘 전용)
- 영상을 둔 NAS (SMB 또는 WebDAV)
- 영화·TV 정보를 받으려면 TMDB API 키 (themoviedb.org 의 계정 설정 → API)

## 설치 (맥)

[Releases](../../releases) 에서 `iRayer-버전-빌드.dmg` 를 받아 Applications 로 옮깁니다. 공증된 앱이라 경고 없이 열리고, 다음 버전부터는 앱이 알아서 업데이트를 확인합니다.

## 빌드

Xcode 26 이상. 대상은 `iRayer`(아이폰·아이패드)와 `iRayerMac`(맥) 두 개이고 `iRayer` 폴더를 함께 씁니다.

용량이 큰 바이너리는 저장소에 넣지 않았습니다. `Vendor/` 에 먼저 준비합니다.

```bash
Scripts/fetch-vlckit.sh      # 아이폰·아이패드: MobileVLCKit 3.7.3 → Vendor/MobileVLCKit.xcframework
Scripts/build-ffmpeg.sh      # 맥: 최소 구성 FFmpeg 8.0 (LGPL) → Vendor/mac/ffmpeg/ffmpeg
```

맥 Finder 미리보기는 `Scripts/fetch-qlvideo.sh` 로 QuickLook Video 공식 배포판에서 확장을 꺼내 `Vendor/mac/QLVideo` 에 둡니다.

맥용 VLCKit 3.7.3 은 VideoLAN 배포판(`download.videolan.org/pub/cocoapods/prod/`)을 받아 `Vendor/mac/VLCKit.xcframework` 에 둡니다. 맥 앱은 Apple 실리콘 전용이라 `lipo` 로 arm64 만 남겨 씁니다.

서명은 Xcode 자동 서명을 쓰며, 팀 ID·번들 ID·iCloud 저장소 이름은 자기 것으로 바꿔야 합니다. 맥 앱은 Developer ID 로 내보내 쓰는 것을 전제로 합니다(일부 WebKit 기능 때문에 Mac App Store 용이 아님).

## 라이선스

[MIT](LICENSE).

앱에 넣는 외부 라이브러리·글꼴:

| 이름 | 라이선스 |
|---|---|
| [VLCKit · MobileVLCKit](https://code.videolan.org/videolan/VLCKit) 3.7.3 | LGPL 2.1 |
| [FFmpeg](https://ffmpeg.org) 8.0 (맥) | LGPL 2.1 |
| [AMSMB2](https://github.com/amosavian/AMSMB2) · libsmb2 | LGPL 2.1 |
| [Unrar.swift](https://github.com/mtgto/Unrar.swift) · UnRAR | MIT · UnRAR 라이선스 |
| [Sparkle](https://github.com/sparkle-project/Sparkle) (맥 자동 업데이트) | MIT |
| [QuickLook Video](https://github.com/Marginal/QuickLookVideo) (맥 Finder 미리보기, 별개 프로그램으로 넣음) | GPL 2.0 이상 |
| 나눔글꼴 · 마루부리 (네이버) | SIL OFL 1.1 |

자세한 고지는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 와 앱의 "iRayer에 관하여" 에 있습니다.

영화·TV 정보는 TMDB 에서 가져옵니다. 이 앱은 TMDB API 를 쓰지만 TMDB 의 보증이나 인증을 받지 않았습니다 (*This product uses the TMDB API but is not endorsed or certified by TMDB.*). Apple, AirPlay, Apple TV 는 Apple Inc. 의 상표입니다.

웹에서 영상을 받는 기능은 내가 볼 권리가 있는 영상에만 쓰세요. 각 사이트의 이용 약관과 저작권은 사용자가 지켜야 합니다.
