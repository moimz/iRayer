import Foundation
import iTunesLibrary

/// 맥 미디어 보관함에서 Apple TV 구입 영화를 읽는다 (아이폰·아이패드에는 이 방법이 없다)
enum AppleTVReader {
    static func read() async throws -> [(movie: AppleTVLibrary.Movie, artwork: Data?)] {
        try await Task.detached {
            let library = try ITLibrary(apiVersion: "1.1")
            // 상점 번호가 있는 영화 = Apple TV 에서 산 것 (직접 넣은 홈 비디오는 빼고)
            return library.allMediaItems.compactMap { item -> (movie: AppleTVLibrary.Movie, artwork: Data?)? in
                guard item.mediaKind == .kindMovie,
                      let storeID = (item.value(forProperty: "StoreItemID") as? NSNumber)?.intValue, storeID > 0 else { return nil }
                let movie = AppleTVLibrary.Movie(storeID: storeID, title: item.title,
                                                 year: item.releaseDate.map { Calendar.current.component(.year, from: $0) },
                                                 genre: item.genre)
                return (movie, item.hasArtworkAvailable ? item.artwork?.imageData : nil)
            }
        }.value
    }
}
