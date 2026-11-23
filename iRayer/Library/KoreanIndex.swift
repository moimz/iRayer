import Foundation

/// 한글 초성 색인: ㄱ~ㅎ → A~Z → #
enum KoreanIndex {
    private static let initials: [Character] = ["ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]
    /// 쌍자음은 기본 자음으로
    private static let merged: [Character: Character] = ["ㄲ": "ㄱ", "ㄸ": "ㄷ", "ㅃ": "ㅂ", "ㅆ": "ㅅ", "ㅉ": "ㅈ"]
    private static let consonants = "ㄱㄴㄷㄹㅁㅂㅅㅇㅈㅊㅋㅌㅍㅎ".map(String.init)

    static func group(of title: String) -> String {
        // 서버에 따라 한글이 NFD(자모 분리)로 온다 (NAS 파일명 등) → 완성형으로 합친 뒤 본다
        let normalized = title.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces)
        guard let first = normalized.unicodeScalars.first else { return "#" }
        if (0xAC00...0xD7A3).contains(first.value) {
            let initial = initials[Int(first.value - 0xAC00) / 588]
            return String(merged[initial] ?? initial)
        }
        // 합쳐지지 않은 첫 자모(초성 U+1100~1112)
        if (0x1100...0x1112).contains(first.value) {
            let initial = initials[Int(first.value - 0x1100)]
            return String(merged[initial] ?? initial)
        }
        let character = Character(first)
        if let base = merged[character] { return String(base) }
        if consonants.contains(String(character)) { return String(character) }
        if first.isASCII, character.isLetter { return character.uppercased() }
        return "#"
    }

    /// 글자마다 초성으로 바꾼 것 ("범죄와의 전쟁" → "ㅂㅈㅇㅇㅈㅈ"). 한글이 아닌 글자는 소문자로 남기고 공백은 뺀다.
    static func choseong(of text: String) -> String {
        var result = ""
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars where !scalar.properties.isWhitespace {
            if (0xAC00...0xD7A3).contains(scalar.value) {
                result.append(initials[Int(scalar.value - 0xAC00) / 588])
            } else {
                result += String(scalar).lowercased()
            }
        }
        return result
    }

    /// 검색어가 글에 들어 있는지: 공백·대소문자를 무시하고 단어 중간도 찾는다. 검색어가 초성(ㄱ~ㅎ)뿐이면 초성으로 맞춘다.
    static func matches(_ query: String, in text: String) -> Bool {
        let query = query.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }
        guard !query.isEmpty else { return false }
        if query.unicodeScalars.allSatisfy({ (0x3131...0x314E).contains($0.value) }) {
            return choseong(of: text).contains(query)
        }
        let text = text.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }
        return text.localizedStandardContains(query)
    }

    /// 색인 순서(ㄱ~ㅎ → A~Z → #)로 lhs 가 앞인지. 같은 색인 안에서는 이름순.
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        let l = order(of: group(of: lhs)), r = order(of: group(of: rhs))
        guard l == r else { return l < r }
        return lhs.precomposedStringWithCanonicalMapping
            .localizedStandardCompare(rhs.precomposedStringWithCanonicalMapping) == .orderedAscending
    }

    static func order(of group: String) -> Int {
        if let index = consonants.firstIndex(of: group) { return index }
        if let scalar = group.unicodeScalars.first, group.count == 1, ("A"..."Z").contains(group) {
            return 100 + Int(scalar.value)
        }
        return 1000
    }
}
