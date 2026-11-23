import Foundation
import SQLite3

/// SQLite 파일 하나 (시스템 내장 SQLite 를 얇게 감싼다)
/// - 값은 `SQLiteValue` 로 넣고, 줄은 `SQLiteRow` 로 읽는다.
/// - 스키마는 `migrate` 로 버전(PRAGMA user_version)마다 한 번씩 올린다.
final class SQLiteDatabase {
    enum DatabaseError: LocalizedError {
        case open(String)
        case statement(String, sql: String)

        var errorDescription: String? {
            switch self {
            case .open(let message): "데이터베이스를 열지 못했습니다: \(message)"
            case .statement(let message, let sql): "\(message) (\(sql.prefix(80)))"
            }
        }
    }

    let url: URL
    private var handle: OpaquePointer?

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path(percentEncoded: false), &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "알 수 없음"
            sqlite3_close(handle)
            throw DatabaseError.open(message)
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close(handle)
    }

    // MARK: - 실행

    /// 결과가 없는 문장 (CREATE·INSERT·UPDATE·DELETE)
    func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw error(sql) }
    }

    /// 줄 목록
    func query(_ sql: String, _ values: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw error(sql) }
            rows.append(SQLiteRow(statement))
        }
        return rows
    }

    /// 첫 줄
    func first(_ sql: String, _ values: [SQLiteValue] = []) throws -> SQLiteRow? {
        try query(sql, values).first
    }

    /// 묶어서 실행 (중간에 실패하면 모두 되돌린다)
    func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try work()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// 스키마 버전을 올린다. `steps[i]` 는 버전 i 에서 i+1 로 가는 문장들.
    func migrate(_ steps: [[String]]) throws {
        let version = try first("PRAGMA user_version")?.int(0) ?? 0
        guard version < steps.count else { return }
        try transaction {
            for step in steps[version...] {
                for sql in step { try execute(sql) }
            }
            try execute("PRAGMA user_version = \(steps.count)")
        }
    }

    // MARK: - 내부

    private func prepare(_ sql: String, _ values: [SQLiteValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error(sql) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, position)
            case .int(let number): sqlite3_bind_int64(statement, position, number)
            case .double(let number): sqlite3_bind_double(statement, position, number)
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, Self.transient)
            }
        }
        return statement
    }

    private func error(_ sql: String) -> DatabaseError {
        .statement(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "알 수 없음", sql: sql)
    }

    /// 넘긴 글자를 SQLite 가 복사해 두게 한다
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

/// 문장에 넣는 값
enum SQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
}

extension SQLiteValue {
    static func of(_ text: String?) -> SQLiteValue { text.map { .text($0) } ?? .null }
    static func of(_ number: Int?) -> SQLiteValue { number.map { .int(Int64($0)) } ?? .null }
    static func of(_ number: Int64?) -> SQLiteValue { number.map { .int($0) } ?? .null }
    static func of(_ number: Double?) -> SQLiteValue { number.map { .double($0) } ?? .null }
    static func of(_ date: Date?) -> SQLiteValue { date.map { .double($0.timeIntervalSince1970) } ?? .null }
}

/// 결과 한 줄 (열 이름으로 읽는다)
struct SQLiteRow {
    private var values: [String: SQLiteValue] = [:]
    private var names: [String] = []

    fileprivate init(_ statement: OpaquePointer?) {
        for index in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, index))
            names.append(name)
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(statement, index))
            case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(statement, index)))
            default: values[name] = .null
            }
        }
    }

    func string(_ name: String) -> String? {
        switch values[name] {
        case .text(let text): text
        case .int(let number): String(number)
        case .double(let number): String(number)
        default: nil
        }
    }

    func int(_ name: String) -> Int? {
        switch values[name] {
        case .int(let number): Int(number)
        case .double(let number): Int(number)
        case .text(let text): Int(text)
        default: nil
        }
    }

    func int64(_ name: String) -> Int64? {
        switch values[name] {
        case .int(let number): number
        case .double(let number): Int64(number)
        case .text(let text): Int64(text)
        default: nil
        }
    }

    func double(_ name: String) -> Double? {
        switch values[name] {
        case .int(let number): Double(number)
        case .double(let number): number
        case .text(let text): Double(text)
        default: nil
        }
    }

    func date(_ name: String) -> Date? {
        double(name).map { Date(timeIntervalSince1970: $0) }
    }

    /// 열 순서로 (PRAGMA 처럼 이름이 정해지지 않은 결과)
    func int(_ index: Int) -> Int? {
        index < names.count ? int(names[index]) : nil
    }
}
