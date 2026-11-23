import Foundation

/// 라이브러리 폴더 정리: 에이전트가 정한 위치(target)와 지금 위치가 다른 파일을 옮긴다. (맥에서만 쓴다)
/// - 자막(같은 이름, 다른 확장자)도 함께 옮기고, 비게 된 폴더는 지운다.
/// - 옮긴 뒤 에이전트에게 새 경로를 알려 준다 (해시로 기억하는 에이전트가 위치를 갱신하도록).
enum LibraryOrganizer {
    struct Move: Identifiable, Hashable {
        let file: LibraryData.FileEntry
        /// 옮길 경로 (라이브러리 폴더 기준, 확장자 포함)
        let to: String
        var id: String { file.id }
    }

    static let subtitleExtensions: Set<String> = ["smi", "srt", "ass", "ssa", "sub", "idx", "vtt", "sup"]

    /// 옮길 파일: 마지막 매칭 때 받은 위치 + (지원하면) 에이전트가 지금 계산한 위치
    static func collect(_ library: LibraryRecord) async -> [Move] {
        let files = LibraryData.files(in: library.id, status: "matched")
        var moves: [String: Move] = [:]
        for file in files {
            guard let folder = file.targetFolder, let name = file.targetName else { continue }
            let to = destination(of: file, folder: folder, name: name)
            if to != file.path, !isShortened(file.path, of: to) { moves[file.id] = Move(file: file, to: to) }
        }
        // 컬렉션이 새로 생기거나 제목을 고친 것은 에이전트가 알려 준다
        for entry in library.agents {
            guard let agent = AgentStore.shared.agent(entry.agentID), agent.type == .custom, agent.relocations,
                  let found = try? await agent.customClient.relocations(kind: entry.kind) else { continue }
            for relocation in found {
                guard let file = files.first(where: { $0.hash == relocation.hash && $0.size == relocation.size }) else { continue }
                let to = destination(of: file, folder: relocation.target.folder, name: relocation.target.filename)
                moves[file.id] = to == file.path || isShortened(file.path, of: to) ? nil : Move(file: file, to: to)
            }
        }
        return moves.values.sorted { $0.file.path.localizedStandardCompare($1.file.path) == .orderedAscending }
    }

    /// 옮길 경로: 대상 폴더/이름 + 지금 이름의 꼬리(" - 확장판", " - part1") + 확장자
    private static func destination(of file: LibraryData.FileEntry, folder: String, name: String) -> String {
        let path = file.path as NSString
        let base = (path.lastPathComponent as NSString).deletingPathExtension
        let ext = path.pathExtension.lowercased()
        // 바뀜 (2026-11-07): 폴더 이름 뒤를 그대로 꼬리로 붙이던 것은 " - 확장판" 처럼 " - " 로 시작할 때만, 영화(회차 이름이 아닌 것)에만.
        // ("멜로가 체질/멜로가 체질.E01.190809.720p-NEXT" 의 ".E01.190809.720p-NEXT" 가 붙어 정리를 두 번 해야 했다)
        var tail = ""
        if let range = base.range(of: #" - (cd|pt|part)\d+$"#, options: [.regularExpression, .caseInsensitive]) {
            tail = String(base[range])
        } else if name.range(of: #" - S\d{2}E\d{2,}"#, options: .regularExpression) == nil {
            let currentFolder = (path.deletingLastPathComponent as NSString).lastPathComponent
            if !currentFolder.isEmpty, base.hasPrefix(currentFolder) {
                let rest = String(base.dropFirst(currentFolder.count))
                if rest.hasPrefix(" - ") { tail = rest }
            }
        }
        // 폴더가 비었으면 라이브러리 폴더 바로 안에 (하위 폴더 없이)
        let folder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return folder.isEmpty ? "\(name)\(tail).\(ext)" : "\(folder)/\(name)\(tail).\(ext)"
    }

    /// 옮기기. 하나씩 옮기고 결과를 알린다 (실패한 것은 이유와 함께).
    static func apply(_ moves: [Move], in library: LibraryRecord, progress: (Int, String?) -> Void) async {
        for (index, move) in moves.enumerated() {
            do {
                try await apply(move, in: library)
                progress(index + 1, nil)
            } catch {
                progress(index + 1, "\(move.file.name): \(error.localizedDescription)")
            }
        }
    }

    // 바뀜 (2026-11-07): 옮기기가 실패하면 회차 제목을 줄여 다시 해 본다. 줄여서 되면 파일 이름 길이 제한 때문이었던 것
    // (WebDAV·SMB 는 이름이 너무 길어도 403·권한 오류로 답해 "권한이 없다"로 보였다). 메타정보(회차 제목)는 그대로 둔다.
    // 바뀜 (2026-11-07): 라이브러리 폴더가 여럿 — 파일이 든 폴더 안에서만 옮긴다 (폴더 사이로 옮기지 않는다)
    private static func apply(_ move: Move, in library: LibraryRecord) async throws {
        guard let folder = library.folder(move.file.folderID) else { throw OrganizeError.noFolder }
        let server = folder.serverID
        let root = folder.rootURL
        let source = LibraryScanner.url(of: move.file, in: library)
        var path = move.to
        var target = root.appending(path: path, directoryHint: .notDirectory)
        // 바뀜 (2026-11-07): 이름이 너무 길면 있는지 묻기(PROPFIND)부터 403 이라 줄여 보기 전에 끝났다 →
        // 로그인·연결 오류가 아니면 모르는 것으로 두고 옮기기로 넘어간다 (옮기기는 덮어쓰지 않으므로 있던 파일은 안전)
        do {
            if try await item(at: target, serverID: server) != nil { throw OrganizeError.exists }
        } catch let error as RemoteAccess.AccessError {
            switch error {
            case .unauthorized, .unreachable: throw error
            default: break
            }
        }

        try await ensureDirectory(target.deletingLastPathComponent(), root: root, serverID: server)
        do {
            try await rename(source, to: target, serverID: server)
        } catch {
            switch error as? RemoteAccess.AccessError {
            case .unauthorized, .unreachable: throw error
            default: break
            }
            var renamed = false
            for shorter in shortenedPaths(move.to) {
                let candidate = root.appending(path: shorter, directoryHint: .notDirectory)
                if (try? await item(at: candidate, serverID: server)) != nil { continue }
                if (try? await rename(source, to: candidate, serverID: server)) != nil {
                    path = shorter
                    target = candidate
                    renamed = true
                    break
                }
            }
            if !renamed { throw error }
        }

        // 자막: 원래 이름과 같은 이름의 자막 파일을 새 이름으로
        let sourceFolder = source.deletingLastPathComponent()
        let oldBase = source.deletingPathExtension().lastPathComponent
        let newBase = target.deletingPathExtension().lastPathComponent
        let siblings = (try? await DirectoryLister.items(in: sourceFolder, serverID: server)) ?? []
        for sibling in siblings where !sibling.isDirectory {
            let ext = sibling.url.pathExtension.lowercased()
            let base = sibling.url.deletingPathExtension().lastPathComponent
            guard subtitleExtensions.contains(ext), base.precomposedStringWithCanonicalMapping == oldBase.precomposedStringWithCanonicalMapping else { continue }
            let destination = target.deletingLastPathComponent().appending(path: "\(newBase).\(ext)")
            if try await item(at: destination, serverID: server) == nil {
                try? await rename(sibling.url, to: destination, serverID: server)
            }
        }

        // 라이브러리 DB 와 에이전트의 경로
        try? AppDatabase.library.execute("UPDATE files SET path = ?, raw_path = ? WHERE library_id = ? AND folder_id = ? AND path = ?",
                                         [.text(path.precomposedStringWithCanonicalMapping), .text(path),
                                          .text(library.id), .text(move.file.folderID), .text(move.file.path)])
        if let hash = move.file.hash, let agentID = move.file.itemKey?.split(separator: ":").first.map(String.init),
           let agent = AgentStore.shared.agent(agentID), agent.type == .custom,
           let kind = library.agents.first(where: { $0.agentID == agentID })?.kind {
            _ = try? await agent.customClient.match(kind: kind, hash: hash, size: move.file.size, path: path, duration: nil)
        }

        // 비게 된 폴더 (숨김 파일만 남은 것) 지우기
        let remaining = (try? await DirectoryLister.items(in: sourceFolder, serverID: server)) ?? []
        if remaining.allSatisfy({ $0.url.lastPathComponent.hasPrefix(".") }),
           sourceFolder.standardizedFileURL != root.standardizedFileURL {
            try? await remove(sourceFolder, serverID: server)
        }
    }

    /// 이름 끝의 회차 제목 " (…)" 을 줄인 경로들 (긴 것부터): 이름을 255·200·143·100 바이트 안으로, 마지막은 제목 없이.
    /// 시놀로지·맥은 이름 255 바이트(한글 한 자 3 바이트), 시놀로지 암호화 공유 폴더는 143 바이트.
    static func shortenedPaths(_ path: String) -> [String] {
        let ns = path as NSString
        let folder = ns.deletingLastPathComponent
        let ext = ns.pathExtension
        let base = (ns.lastPathComponent as NSString).deletingPathExtension
        guard let open = base.range(of: " (", options: .backwards), base.hasSuffix(")") else { return [] }
        let head = String(base[..<open.lowerBound])
        // 시리즈 회차 이름("작품 - S01E01 (제목)")만. 영화 "제목 (연도)" 는 건드리지 않는다
        guard head.range(of: #" - S\d{2}E\d{2,}(-E\d{2,})?$"#, options: .regularExpression) != nil else { return [] }
        let title = String(base[open.upperBound..<base.index(before: base.endIndex)])
        let suffix = ext.isEmpty ? "" : "." + ext
        func join(_ name: String) -> String { folder.isEmpty ? name : folder + "/" + name }

        var result: [String] = []
        for limit in [255, 200, 143, 100] {
            // head + " (" + 제목 + "…)" + 확장자
            let budget = limit - head.utf8.count - suffix.utf8.count - " (…)".utf8.count
            guard budget >= 12 else { continue }
            var cut = ""
            for character in title {
                if cut.utf8.count + String(character).utf8.count > budget { break }
                cut.append(character)
            }
            cut = cut.trimmingCharacters(in: .whitespaces)
            guard !cut.isEmpty, cut.count < title.count else { continue }
            let candidate = join("\(head) (\(cut)…)\(suffix)")
            if !result.contains(candidate) { result.append(candidate) }
        }
        result.append(join(head + suffix))
        return result
    }

    /// 지금 경로가 목표 경로의 회차 제목만 줄인 것인지 (길이 제한으로 줄여 옮긴 파일은 다시 옮기지 않는다)
    static func isShortened(_ current: String, of target: String) -> Bool {
        let a = current as NSString, b = target as NSString
        guard a.deletingLastPathComponent == b.deletingLastPathComponent, a.pathExtension.lowercased() == b.pathExtension.lowercased() else { return false }
        let currentBase = (a.lastPathComponent as NSString).deletingPathExtension
        let targetBase = (b.lastPathComponent as NSString).deletingPathExtension
        guard let open = targetBase.range(of: " (", options: .backwards),
              targetBase[..<open.lowerBound].range(of: #" - S\d{2}E\d{2,}(-E\d{2,})?$"#, options: .regularExpression) != nil else { return false }
        if currentBase == String(targetBase[..<open.lowerBound]) { return true }
        guard currentBase.hasSuffix("…)") else { return false }
        return targetBase.hasPrefix(String(currentBase.dropLast(2)))
    }

    enum OrganizeError: LocalizedError {
        case exists
        /// 파일이 든 폴더가 라이브러리에서 빠졌다
        case noFolder
        var errorDescription: String? {
            switch self {
            case .exists: "옮길 위치에 이미 파일이 있습니다."
            case .noFolder: "라이브러리에서 빠진 폴더의 파일입니다. 다시 훑어 주세요."
            }
        }
    }

    // MARK: - 저장소별 동작

    private static func item(at url: URL, serverID: UUID) async throws -> (isDirectory: Bool, size: Int64)? {
        switch url.scheme {
        case "smb": try await SMBClient.shared.item(at: url, serverID: serverID)
        case "http", "https": try await WebDAVClient.item(at: url, serverID: serverID)
        default: throw RemoteAccess.AccessError.unsupported
        }
    }

    private static func rename(_ url: URL, to destination: URL, serverID: UUID) async throws {
        switch url.scheme {
        case "smb": try await SMBClient.shared.move(url, to: destination, serverID: serverID)
        case "http", "https": try await WebDAVClient.transfer(url, to: destination, isDirectory: false, copy: false, overwrite: false, serverID: serverID)
        default: throw RemoteAccess.AccessError.unsupported
        }
    }

    private static func remove(_ url: URL, serverID: UUID) async throws {
        switch url.scheme {
        case "smb": try await SMBClient.shared.remove(url, serverID: serverID)
        case "http", "https": try await WebDAVClient.remove(WebDAVClient.directoryURL(url), serverID: serverID)
        default: throw RemoteAccess.AccessError.unsupported
        }
    }

    /// 폴더가 없으면 위에서부터 차례로 만든다
    private static func ensureDirectory(_ url: URL, root: URL, serverID: UUID) async throws {
        if try await item(at: url, serverID: serverID) != nil { return }
        let parent = url.deletingLastPathComponent()
        if parent.path(percentEncoded: false).count > root.path(percentEncoded: false).count {
            try await ensureDirectory(parent, root: root, serverID: serverID)
        }
        switch url.scheme {
        case "smb": try await SMBClient.shared.createDirectory(url, serverID: serverID)
        case "http", "https": try await WebDAVClient.createDirectory(url, serverID: serverID)
        default: throw RemoteAccess.AccessError.unsupported
        }
    }
}
