import Foundation

extension SyncEngine {
    /// 앱이 시작할 때 한 번: 동기화할 저장소를 모두 등록하고 시작한다 (아이폰·아이패드·맥 같은 목록)
    /// 동기화 영역은 "iRayer". 비밀번호·에이전트 키는 iCloud 키체인으로 따로 넘어간다.
    func startAll() {
        let kinds = PlaybackStateStore.shared.syncKinds + WatchHistory.shared.syncKinds + LocationStore.shared.syncKinds
            + FolderOptionsStore.shared.syncKinds + ComicSettingsStore.shared.syncKinds + AppleTVLibrary.shared.syncKinds
            + AgentStore.shared.syncKinds + LibraryStore.shared.syncKinds + FavoritePeople.shared.syncKinds + Playlists.shared.syncKinds
            + SyncedSettings.shared.syncKinds + WebBookmarks.shared.syncKinds + TextSettingsStore.shared.syncKinds
            + AdBlock.shared.syncKinds  // 바뀜 (2026-11-12): 웹 탐색 광고 차단 규칙
        kinds.forEach(register)
        // 맥에서 받는 현황 (2026-11-09): 맥은 올리고, 아이폰·아이패드는 받아 본다
        #if os(macOS)
        WebDownloadStatus.shared.syncKinds.forEach(register)
        #else
        MacDownloads.shared.syncKinds.forEach(register)
        #endif
        // 폰 ↔ 맥 원격 웹 탐색 (2026-11-09): 맥 목록·명령·찾은 영상
        MacRemote.shared.syncKinds.forEach(register)
        start()
        #if os(macOS)
        WebDownloadStatus.shared.start()
        MacRemoteHost.shared.start()
        #endif
        // 등록한 다음에 옮겨야 바뀐 설정이 다른 기기로 간다
        FolderOptionsStore.shared.migrateToAddedFolders()
    }
}
