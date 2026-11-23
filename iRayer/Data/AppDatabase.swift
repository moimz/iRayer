import Foundation

/// 저장소: SQLite 파일 두 개 (AppPaths.support = Application Support/iRayer/)
/// - User.sqlite: 내 설정과 기록 (에이전트, 라이브러리 설정 …). 지키는 것.
/// - Library.sqlite: 라이브러리의 파일 목록과 에이전트가 준 메타정보. 버려도 에이전트에게 다시 받으면 되는 것.
/// 1.0 의 JSON·UserDefaults·iCloud 데이터는 건드리지 않는다.
enum AppDatabase {
    static let directory = AppPaths.support

    static let user: SQLiteDatabase = open("User.sqlite", userSchema)
    static let library: SQLiteDatabase = open("Library.sqlite", librarySchema)

    /// 라이브러리 데이터를 버리고 빈 파일로 다시 만든다 (라이브러리 구조를 크게 바꿨을 때)
    static func resetLibrary() throws {
        let tables = try library.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        try library.transaction {
            try library.execute("PRAGMA foreign_keys = OFF")
            for table in tables.compactMap({ $0.string("name") }) {
                try library.execute("DROP TABLE IF EXISTS \"\(table)\"")
            }
            try library.execute("PRAGMA user_version = 0")
        }
        try library.execute("PRAGMA foreign_keys = ON")
        try library.migrate(librarySchema)
    }

    private static func open(_ name: String, _ schema: [[String]]) -> SQLiteDatabase {
        do {
            let database = try SQLiteDatabase(url: directory.appending(path: name))
            try database.migrate(schema)
            return database
        } catch {
            fatalError("\(name): \(error.localizedDescription)")
        }
    }

    // MARK: - 스키마 (버전마다 한 묶음, 지나간 묶음은 고치지 않고 새 묶음을 더한다)

    private static let userSchema: [[String]] = [
        [
            """
            CREATE TABLE agents (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,          -- tmdb, custom
                name TEXT NOT NULL,
                url TEXT NOT NULL,
                version TEXT,
                kinds TEXT NOT NULL DEFAULT '[]', -- 받는 종류 [{id, name, type}]
                relocations INTEGER NOT NULL DEFAULT 0,
                sort INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE libraries (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                kind TEXT NOT NULL,          -- movie, drama, anime, docu, variety, etc
                server_id TEXT NOT NULL,     -- 저장소 (NetworkServer)
                root_url TEXT NOT NULL,      -- 라이브러리 폴더 주소
                sort INTEGER NOT NULL DEFAULT 0,
                scanned_at REAL,
                created_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE library_agents (
                library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
                sort INTEGER NOT NULL,
                agent_id TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
                agent_kind TEXT NOT NULL,    -- 그 에이전트의 종류 id
                PRIMARY KEY (library_id, sort)
            )
            """,
        ],
        [
            // 영상마다 기억하는 것: 키는 "#해시|크기" (라이브러리 밖 파일은 "파일명|크기"). 줄 하나가 나중에 iCloud 레코드 하나.
            "CREATE TABLE playback (key TEXT PRIMARY KEY, data TEXT NOT NULL, updated_at REAL NOT NULL)",
            "CREATE TABLE history (key TEXT PRIMARY KEY, data TEXT NOT NULL, updated_at REAL NOT NULL)",
            "CREATE INDEX history_updated ON history (updated_at)",
            """
            CREATE TABLE favorite_people (
                key TEXT PRIMARY KEY,        -- 정보출처:번호 (예: tmdb:21684). 에이전트가 달라도 같은 사람
                name TEXT NOT NULL,
                photo TEXT,
                created_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE playlists (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                sort INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE playlist_items (
                playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
                sort INTEGER NOT NULL,
                key TEXT NOT NULL,           -- 영상 키 "#해시|크기"
                title TEXT,
                PRIMARY KEY (playlist_id, sort)
            )
            """,
        ],
        [
            // 영화 라이브러리에 Apple TV 구입작을 함께 넣는다
            "ALTER TABLE libraries ADD COLUMN apple_tv INTEGER NOT NULL DEFAULT 0",
        ],
        [
            // 홈(이어보기·최근 추가·장르)에 이 라이브러리를 보여줄지
            "ALTER TABLE libraries ADD COLUMN home INTEGER NOT NULL DEFAULT 1",
        ],
        [
            // 사용자가 고른 아이콘 (SF Symbol 이름)
            "ALTER TABLE libraries ADD COLUMN icon TEXT",
        ],
        [
            // 홈에 이 라이브러리의 "최근 추가된 …" 포스터 줄을 둘지
            "ALTER TABLE libraries ADD COLUMN home_shelf INTEGER NOT NULL DEFAULT 1",
        ],
        [
            // 라이브러리 하나에 폴더 여러 개 (2026-11-07). 예전 폴더는 라이브러리 id 를 폴더 id 로 옮긴다
            // (Library.sqlite files.folder_id 도 같은 값으로 옮기므로 두 파일을 따로 옮겨도 맞는다)
            """
            CREATE TABLE library_folders (
                id TEXT PRIMARY KEY,
                library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
                server_id TEXT NOT NULL,     -- 저장소 (NetworkServer)
                root_url TEXT NOT NULL,      -- 폴더 주소
                sort INTEGER NOT NULL
            )
            """,
            "CREATE INDEX library_folders_library ON library_folders (library_id, sort)",
            "INSERT INTO library_folders (id, library_id, server_id, root_url, sort) SELECT id, id, server_id, root_url, 0 FROM libraries",
            "ALTER TABLE libraries DROP COLUMN server_id",
            "ALTER TABLE libraries DROP COLUMN root_url",
        ],
        [
            // 에이전트 종류를 네 가지로 (2026-11-07, reader 서버와 같이 바꿈): 영화 movie · TV 시리즈 tv · 자동 auto · 기타 etc.
            // 드라마·애니메이션·예능은 서버에서 모두 TV 시리즈와 같았고, 다큐멘터리는 자동이었다.
            "UPDATE library_agents SET agent_kind = 'tv' WHERE agent_kind IN ('drama', 'anime', 'variety')",
            "UPDATE library_agents SET agent_kind = 'auto' WHERE agent_kind = 'docu'",
            // 사용자 정의 에이전트(reader)가 알려 준 종류 목록도 새것으로 (다음에 에이전트 정보를 다시 받을 때까지)
            """
            UPDATE agents SET kinds = '[{"id":"movie","name":"영화","type":"MOVIE"},{"id":"tv","name":"TV 시리즈","type":"SERIES"},{"id":"auto","name":"자동 (영화·TV 시리즈)","type":"AUTO"},{"id":"etc","name":"기타","type":"MOVIE"}]'
            WHERE type = 'custom' AND kinds LIKE '%"drama"%'
            """,
        ],
    ]

    private static let librarySchema: [[String]] = [
        [
            """
            CREATE TABLE files (
                library_id TEXT NOT NULL,
                path TEXT NOT NULL,          -- 라이브러리 폴더 기준 경로 (NFC, 에이전트에 보내는 값)
                raw_path TEXT NOT NULL,      -- 저장소에 실제로 있는 그대로의 경로 (NAS 의 한글은 NFD 일 수 있다)
                hash TEXT,                   -- OpenSubtitles 해시
                size INTEGER NOT NULL,
                modified_at REAL,
                duration REAL,
                status TEXT NOT NULL DEFAULT 'new', -- new, matched, unmatched, excluded, error
                message TEXT,                -- 실패 이유
                agent_id TEXT,
                item_key TEXT,               -- items.key
                season INTEGER,
                episode INTEGER,
                episode_end INTEGER,
                target_folder TEXT,          -- 에이전트가 준 옮길 위치
                target_name TEXT,
                checked_at REAL,
                PRIMARY KEY (library_id, path)
            )
            """,
            "CREATE INDEX files_hash ON files (hash, size)",
            "CREATE INDEX files_item ON files (item_key)",
            """
            CREATE TABLE items (
                key TEXT PRIMARY KEY,        -- 에이전트id:작품id
                agent_id TEXT NOT NULL,
                id TEXT NOT NULL,
                type TEXT NOT NULL,          -- MOVIE, SERIES
                kind TEXT,
                source TEXT,
                source_id TEXT,
                title TEXT NOT NULL,
                title_origin TEXT,
                year INTEGER,
                date TEXT,
                summary TEXT,
                poster TEXT,
                backdrop TEXT,
                collection_id TEXT,
                collection_name TEXT,
                updated_at REAL NOT NULL
            )
            """,
            "CREATE INDEX items_source ON items (source, source_id)",
            """
            CREATE TABLE episodes (
                item_key TEXT NOT NULL,
                season INTEGER NOT NULL,
                episode INTEGER NOT NULL,
                title TEXT,
                summary TEXT,
                date TEXT,
                still TEXT,
                PRIMARY KEY (item_key, season, episode)
            )
            """,
            """
            CREATE TABLE people (
                key TEXT PRIMARY KEY,        -- 에이전트id:인물id
                agent_id TEXT NOT NULL,
                id TEXT NOT NULL,
                source TEXT,
                source_id TEXT,
                name TEXT NOT NULL,
                name_origin TEXT,
                photo TEXT
            )
            """,
            """
            CREATE TABLE credits (
                item_key TEXT NOT NULL,
                person_key TEXT NOT NULL,
                role TEXT NOT NULL,          -- ACTOR, DIRECTOR, WRITER
                character TEXT,
                sort INTEGER NOT NULL,
                PRIMARY KEY (item_key, person_key, role)
            )
            """,
            "CREATE INDEX credits_person ON credits (person_key)",
            """
            CREATE TABLE genres (
                item_key TEXT NOT NULL,
                name TEXT NOT NULL,
                PRIMARY KEY (item_key, name)
            )
            """,
            "CREATE INDEX genres_name ON genres (name)",
        ],
        [
            // 라이브러리에 처음 들어온 때 (홈의 최근 추가)
            "ALTER TABLE files ADD COLUMN added_at REAL",
            "UPDATE files SET added_at = modified_at",
        ],
        [
            // Apple TV 구입작: 라이브러리의 에이전트로 찾아 파일처럼 작품에 잇는다 (못 찾으면 "appletv:상점번호" 작품)
            """
            CREATE TABLE purchases (
                library_id TEXT NOT NULL,
                store_id INTEGER NOT NULL,   -- Apple 상점 번호
                title TEXT NOT NULL,
                year INTEGER,
                status TEXT NOT NULL DEFAULT 'new', -- new, matched, unmatched, error
                message TEXT,
                agent_id TEXT,
                item_key TEXT,               -- items.key
                added_at REAL,               -- 처음 넣을 때 한꺼번에 들어온 것은 비워 둔다 (홈의 최근 추가에 몰리지 않게)
                PRIMARY KEY (library_id, store_id)
            )
            """,
            "CREATE INDEX purchases_item ON purchases (item_key)",
            // 라이브러리에 든 작품 한 줄씩: 매칭된 파일 + 작품에 이은 구입작 (둘러보기·홈 등은 이것을 읽는다)
            """
            CREATE VIEW entries AS
                SELECT library_id, item_key, COALESCE(added_at, modified_at) AS added_at, 0 AS purchase
                FROM files WHERE status = 'matched'
                UNION ALL
                SELECT library_id, item_key, added_at, 1 AS purchase FROM purchases WHERE item_key IS NOT NULL
            """,
        ],
        [
            // 이미 받은 TV 전용 영어 장르를 나눠 한국어로 (LibraryData.genreNames 와 같은 표)
            "INSERT OR IGNORE INTO genres (item_key, name) SELECT item_key, '액션' FROM genres WHERE name = 'Action & Adventure'",
            "INSERT OR IGNORE INTO genres (item_key, name) SELECT item_key, '모험' FROM genres WHERE name = 'Action & Adventure'",
            "INSERT OR IGNORE INTO genres (item_key, name) SELECT item_key, 'SF' FROM genres WHERE name = 'Sci-Fi & Fantasy'",
            "INSERT OR IGNORE INTO genres (item_key, name) SELECT item_key, '판타지' FROM genres WHERE name = 'Sci-Fi & Fantasy'",
            "INSERT OR IGNORE INTO genres (item_key, name) SELECT item_key, '전쟁' FROM genres WHERE name = 'War & Politics'",
            "INSERT OR IGNORE INTO genres (item_key, name) SELECT item_key, '정치' FROM genres WHERE name = 'War & Politics'",
            "INSERT OR IGNORE INTO genres (item_key, name) SELECT item_key, '키즈' FROM genres WHERE name = 'Kids'",
            "INSERT OR IGNORE INTO genres (item_key, name) SELECT item_key, '뉴스' FROM genres WHERE name = 'News'",
            "INSERT OR IGNORE INTO genres (item_key, name) SELECT item_key, '리얼리티' FROM genres WHERE name = 'Reality'",
            "INSERT OR IGNORE INTO genres (item_key, name) SELECT item_key, '연속극' FROM genres WHERE name = 'Soap'",
            "INSERT OR IGNORE INTO genres (item_key, name) SELECT item_key, '토크쇼' FROM genres WHERE name = 'Talk'",
            "DELETE FROM genres WHERE name IN ('Action & Adventure', 'Sci-Fi & Fantasy', 'War & Politics', 'Kids', 'News', 'Reality', 'Soap', 'Talk')",
        ],
        [
            // 관람등급 "나라:등급" (에이전트가 준 것, NULL 은 아직 받지 않음): 성인 등급 숨기기
            "ALTER TABLE items ADD COLUMN rating TEXT",
        ],
        [
            // 라이브러리 하나에 폴더 여러 개 (2026-11-07): 파일은 폴더 기준 경로 + 폴더 id. 예전 파일의 폴더 id 는 라이브러리 id
            // (User.sqlite 에서 예전 폴더를 라이브러리 id 로 옮긴다). 다시 해시하지 않게 표를 새로 만들어 옮겨 담는다.
            "DROP VIEW entries",
            """
            CREATE TABLE files_new (
                library_id TEXT NOT NULL,
                folder_id TEXT NOT NULL,     -- 라이브러리 폴더 (User.sqlite library_folders.id)
                path TEXT NOT NULL,          -- 폴더 기준 경로 (NFC, 에이전트에 보내는 값)
                raw_path TEXT NOT NULL,      -- 저장소에 실제로 있는 그대로의 경로 (NAS 의 한글은 NFD 일 수 있다)
                hash TEXT,
                size INTEGER NOT NULL,
                modified_at REAL,
                duration REAL,
                status TEXT NOT NULL DEFAULT 'new',
                message TEXT,
                agent_id TEXT,
                item_key TEXT,
                season INTEGER,
                episode INTEGER,
                episode_end INTEGER,
                target_folder TEXT,
                target_name TEXT,
                checked_at REAL,
                added_at REAL,
                PRIMARY KEY (library_id, folder_id, path)
            )
            """,
            """
            INSERT INTO files_new (library_id, folder_id, path, raw_path, hash, size, modified_at, duration, status, message, agent_id,
                                   item_key, season, episode, episode_end, target_folder, target_name, checked_at, added_at)
            SELECT library_id, library_id, path, raw_path, hash, size, modified_at, duration, status, message, agent_id,
                   item_key, season, episode, episode_end, target_folder, target_name, checked_at, added_at FROM files
            """,
            "DROP TABLE files",
            "ALTER TABLE files_new RENAME TO files",
            "CREATE INDEX files_hash ON files (hash, size)",
            "CREATE INDEX files_item ON files (item_key)",
            """
            CREATE VIEW entries AS
                SELECT library_id, item_key, COALESCE(added_at, modified_at) AS added_at, 0 AS purchase
                FROM files WHERE status = 'matched'
                UNION ALL
                SELECT library_id, item_key, added_at, 1 AS purchase FROM purchases WHERE item_key IS NOT NULL
            """,
        ],
        [
            // 등급을 찾지 못한 작품(NR, US:NR 처럼 "등급 없음" 을 받은 것)은 한 번 다시 받는다 (2026-11-07 서버가 작품 나라의 등급도 보게 됨: 일본 드라마 등).
            // 켤 때 fillRatings 가 NULL 인 작품을 다시 묻는다
            "UPDATE items SET rating = NULL WHERE rating = 'NR' OR rating LIKE '%:NR'",
        ],
    ]
}
