import Foundation
import SQLite3

/// Attributed read-only database failure, so a source adapter can report *why*
/// a database was unreadable instead of a single generic sentence.
///
/// The Codex path passes no subject and keeps its historical wording verbatim.
struct SQLiteReadError: LocalizedError, Sendable {
    enum Kind: Sendable { case openFailed, schemaUnsupported, busy, unavailable }

    let kind: Kind
    let message: String

    var errorDescription: String? { message }

    var adapterFailure: AdapterFailure {
        switch kind {
        case .openFailed, .unavailable: .openFailed
        case .schemaUnsupported: .schemaUnsupported
        case .busy: .busy
        }
    }
}

/// Opens existing databases read-only; never creates files or performs migrations.
final class SQLiteReader {
    private var db: OpaquePointer?
    private var columnCache: [String: Set<String>] = [:]
    private var columnSchemaVersion: Int64?
    /// Nil keeps the Codex wording, which is what the existing call sites rely on.
    private let subject: String?

    init(url: URL, sourceLabel: String? = nil) throws {
        subject = sourceLabel
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            db = nil
            throw SQLiteReadError(kind: .openFailed, message: Self.message(
                "Unable to read the Codex database. Check the data directory and file permissions.",
                "Unable to read the %@ database. Check the data directory and file permissions.",
                subject: sourceLabel))
        }
        sqlite3_busy_timeout(db, 250)
    }
    deinit { sqlite3_close(db) }

    func rows(_ sql: String) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteReadError(kind: .schemaUnsupported, message: Self.message(
                "Unsupported Codex database schema. Update Veyra or check the data directory.",
                "Unsupported %@ database schema. Update Veyra or check the data directory.",
                subject: subject))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else {
                throw SQLiteReadError(kind: .busy, message: Self.message(
                    "The Codex database is busy. Retrying automatically shortly.",
                    "The %@ database is busy. Retrying automatically shortly.",
                    subject: subject))
            }
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
            throw SQLiteReadError(kind: .schemaUnsupported, message: Self.message(
                "Unable to check for Codex database updates.",
                "Unable to check for %@ database updates.",
                subject: subject))
        }
        return value
    }

    /// Picks the wording that matches the configured subject. The labelled and
    /// plain strings are both catalog keys; the subject is substituted after
    /// lookup so a formatted key is never searched for.
    private static func message(_ plain: String, _ labelled: String, subject: String?) -> String {
        guard let subject else { return L10n.text(String.LocalizationValue(plain)) }
        return String(format: L10n.text(String.LocalizationValue(labelled)), locale: .current, subject)
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

    func load(url: URL, sourceLabel: String? = nil,
              query: (SQLiteReader) throws -> Value) throws -> (value: Value, queried: Bool) {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = "\(url.path):\(attrs[.systemNumber] ?? 0):\(attrs[.systemFileNumber] ?? 0)"
        if identity != stamp { reset(); identity = stamp }
        if reader == nil { reader = try SQLiteReader(url: url, sourceLabel: sourceLabel) }
        guard let reader else {
            throw SQLiteReadError(kind: .unavailable, message: L10n.text("Unable to read the database."))
        }
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
