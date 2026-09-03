import Foundation
import SQLite3

/// Opens existing databases read-only; never creates files or performs migrations.
final class SQLiteReader {
    private var db: OpaquePointer?
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            db = nil
            throw MonitorFailure("无法读取 Codex 数据库，请检查数据目录和文件权限。")
        }
        sqlite3_busy_timeout(db, 250)
    }
    deinit { sqlite3_close(db) }

    func rows(_ sql: String) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MonitorFailure("Codex 数据库结构暂不兼容，请更新应用或检查数据目录。")
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw MonitorFailure("Codex 数据库正忙，稍后将自动重试。") }
            var row: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                      let name = sqlite3_column_name(statement, column), let value = sqlite3_column_text(statement, column) else { continue }
                row[String(cString: name)] = String(cString: value)
            }
            rows.append(row)
        }
    }
    func columns(in table: String) throws -> Set<String> {
        Set(try rows("PRAGMA table_info(\(table))").compactMap { $0["name"] })
    }

    static func database(named prefix: String, in home: URL) -> URL? {
        for folder in [home, home.appendingPathComponent("sqlite")] {
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let matches = urls.compactMap { url -> (Int, URL)? in
                let name = url.deletingPathExtension().lastPathComponent
                guard url.pathExtension == "sqlite", name.hasPrefix(prefix + "_"),
                      let version = Int(name.dropFirst(prefix.count + 1)) else { return nil }
                return (version, url)
            }
            if let url = matches.max(by: { $0.0 < $1.0 })?.1 { return url }
        }
        return nil
    }
}
