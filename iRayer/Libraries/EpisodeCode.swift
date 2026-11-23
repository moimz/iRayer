import Foundation

/// 파일 이름의 시즌·회차 표기 "S01E03" (2026-11-11, 사용자). 재생 제목은 읽기 편한 "S1E3" 그대로 (LibraryData.playTitle).
/// 회차 번호는 그 시즌의 가장 큰 회차 자릿수에 맞춘다 (두 자리 이상) — 100화가 넘는 시즌은 S01E001 … S01E102 로 이름 순서가 맞게.
/// 서버(Meta.php getSeriesTarget)도 같은 규칙.
nonisolated enum EpisodeCode {
    static func make(season: Int?, episode: Int, end: Int? = nil, maxEpisode: Int = 0) -> String {
        let width = max(2, String(max(maxEpisode, episode, end ?? 0)).count)
        var code = (season.map { String(format: "S%02d", $0) } ?? "") + "E" + String(format: "%0\(width)d", episode)
        if let end, end > episode { code += "-E" + String(format: "%0\(width)d", end) }
        return code
    }
}
