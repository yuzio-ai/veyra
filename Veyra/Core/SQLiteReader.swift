import Foundation
import SQLite3

/// Opens existing databases read-only; never creates files or performs migrations.
final class SQLiteReader {
    private var db: OpaquePointer?
    private var columnCache: [String: Set<String>] = [:]
    private var columnSchemaVersion: Int64?
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
        let schema = try version("schema_version")
        if schema != columnSchemaVersion { columnCache = [:]; columnSchemaVersion = schema }
        if let cached = columnCache[table] { return cached }
        let columns = Set(try rows("PRAGMA table_info(\(table))").compactMap { $0["name"] })
        columnCache[table] = columns
        return columns
    }
    func version(_ name: String) throws -> Int64 {
        guard ["data_version", "schema_version"].contains(name),
              let raw = try rows("PRAGMA \(name)").first?[name], let value = Int64(raw) else {
            throw MonitorFailure("无法检查 Codex 数据库更新。")
        }
        return value
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

/// Actor-confined connection and result cache. Versions never cross connection lifetimes.
final class SQLiteReadCache<Value> {
    private var identity: String?
    private var reader: SQLiteReader?
    private var dataVersion: Int64?
    private var schemaVersion: Int64?
    private var value: Value?

    func load(url: URL, query: (SQLiteReader) throws -> Value) throws -> (value: Value, queried: Bool) {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = "\(url.path):\(attrs[.systemNumber] ?? 0):\(attrs[.systemFileNumber] ?? 0)"
        if identity != stamp { reset(); identity = stamp }
        if reader == nil { reader = try SQLiteReader(url: url) }
        guard let reader else { throw MonitorFailure("无法读取 Codex 数据库。") }
        let currentData = try reader.version("data_version")
        let currentSchema = try reader.version("schema_version")
        if dataVersion == currentData, schemaVersion == currentSchema, let value { return (value, false) }
        // Stamp BEFORE SELECT: a concurrent commit must invalidate the next read.
        let next = try query(reader)
        value = next; dataVersion = currentData; schemaVersion = currentSchema
        return (next, true)
    }
    func reset() {
        reader = nil; value = nil; identity = nil; dataVersion = nil; schemaVersion = nil
    }
}
