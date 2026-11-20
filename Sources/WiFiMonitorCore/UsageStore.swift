import Foundation
import SQLite3

public struct UsageDayRecord: Sendable {
    public let day: String
    public let downloaded: Int64
    public let uploaded: Int64
}

public final class UsageStore {
    private var database: OpaquePointer?
    private let lock = NSLock()
    public private(set) var initializationError: String?
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public init(directoryURL: URL? = nil) {
        do {
            let directory: URL
            if let directoryURL { directory = directoryURL }
            else {
                directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true)
                    .appendingPathComponent("WiFi Monitor", isDirectory: true)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("usage.sqlite")
            guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw StoreError.open }
            try execute("PRAGMA journal_mode=WAL;")
            try execute("CREATE TABLE IF NOT EXISTS usage (day TEXT NOT NULL, scope TEXT NOT NULL, downloaded INTEGER NOT NULL, uploaded INTEGER NOT NULL, PRIMARY KEY(day, scope));")
            try execute("CREATE TABLE IF NOT EXISTS network_usage (network_name TEXT NOT NULL, day TEXT NOT NULL, downloaded INTEGER NOT NULL, uploaded INTEGER NOT NULL, last_seen_utc REAL NOT NULL, PRIMARY KEY(network_name, day));")
            if !hasScopeColumn() {
                try execute("ALTER TABLE usage RENAME TO usage_legacy; CREATE TABLE usage (day TEXT NOT NULL, scope TEXT NOT NULL, downloaded INTEGER NOT NULL, uploaded INTEGER NOT NULL, PRIMARY KEY(day, scope)); INSERT INTO usage(day, scope, downloaded, uploaded) SELECT day, 'wifi', downloaded, uploaded FROM usage_legacy; DROP TABLE usage_legacy;")
            }
        } catch {
            initializationError = error.localizedDescription
            if let database { sqlite3_close(database); self.database = nil }
            NSLog("WiFi Monitor storage unavailable: %@", String(describing: error))
        }
    }

    deinit { sqlite3_close(database) }

    public func totals(for date: Date = .now, scope: String = "wifi") -> (downloaded: Int64, uploaded: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let database else { return (0, 0) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT downloaded, uploaded FROM usage WHERE day = ?1 AND scope = ?2", -1, &statement, nil) == SQLITE_OK else { return (0, 0) }
        defer { sqlite3_finalize(statement) }
        bind(dayKey(date), to: 1, in: statement)
        bind(scope, to: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return (0, 0) }
        return (sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1))
    }

    public func dayKey(for date: Date = .now) -> String {
        lock.lock(); defer { lock.unlock() }
        return dayKey(date)
    }

    public func networkSummaries(at date: Date = .now) -> [NetworkUsageSummary] {
        lock.lock(); defer { lock.unlock() }
        guard let database else { return [] }
        let today = dayKey(date)
        let sql = "SELECT network_name, SUM(downloaded), SUM(uploaded), SUM(CASE WHEN day = ?1 THEN downloaded ELSE 0 END), SUM(CASE WHEN day = ?1 THEN uploaded ELSE 0 END), MAX(last_seen_utc) FROM network_usage GROUP BY network_name ORDER BY SUM(downloaded + uploaded) DESC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(today, to: 1, in: statement)
        var result: [NetworkUsageSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0) else { continue }
            result.append(NetworkUsageSummary(
                networkName: String(cString: name), downloaded: sqlite3_column_int64(statement, 1),
                uploaded: sqlite3_column_int64(statement, 2), todayDownloaded: sqlite3_column_int64(statement, 3),
                todayUploaded: sqlite3_column_int64(statement, 4), lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            ))
        }
        return result
    }

    public func addNetworkUsage(networkName: String, downloaded: Int64, uploaded: Int64, at date: Date = .now) {
        guard !networkName.isEmpty, downloaded > 0 || uploaded > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard let database else { return }
        let sql = "INSERT INTO network_usage(network_name, day, downloaded, uploaded, last_seen_utc) VALUES(?1, ?2, ?3, ?4, ?5) ON CONFLICT(network_name, day) DO UPDATE SET downloaded=downloaded+excluded.downloaded, uploaded=uploaded+excluded.uploaded, last_seen_utc=MAX(last_seen_utc, excluded.last_seen_utc)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(networkName, to: 1, in: statement)
        bind(dayKey(date), to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, downloaded)
        sqlite3_bind_int64(statement, 4, uploaded)
        sqlite3_bind_double(statement, 5, date.timeIntervalSince1970)
        if sqlite3_step(statement) != SQLITE_DONE { NSLog("WiFi Monitor could not persist per-network usage") }
    }

    public func recentDays(limit: Int, scope: String) -> [UsageDayRecord] {
        lock.lock(); defer { lock.unlock() }
        guard let database else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT day, downloaded, uploaded FROM usage WHERE scope = ?1 ORDER BY day DESC LIMIT ?2", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(scope, to: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(clamping: limit))
        var result: [UsageDayRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            result.append(UsageDayRecord(day: String(cString: text), downloaded: sqlite3_column_int64(statement, 1), uploaded: sqlite3_column_int64(statement, 2)))
        }
        return result
    }

    public func total(from start: Date, through end: Date, scope: String) -> (downloaded: Int64, uploaded: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let database else { return (0, 0) }
        var statement: OpaquePointer?
        let sql = "SELECT COALESCE(SUM(downloaded),0), COALESCE(SUM(uploaded),0) FROM usage WHERE day >= ?1 AND day <= ?2 AND scope = ?3"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return (0, 0) }
        defer { sqlite3_finalize(statement) }
        bind(dayKey(start), to: 1, in: statement)
        bind(dayKey(end), to: 2, in: statement)
        bind(scope, to: 3, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return (0, 0) }
        return (sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1))
    }

    public func add(downloaded: Int64, uploaded: Int64, at date: Date = .now, scope: String) {
        guard downloaded > 0 || uploaded > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard let database else { return }
        var statement: OpaquePointer?
        let sql = "INSERT INTO usage(day, scope, downloaded, uploaded) VALUES(?1, ?2, ?3, ?4) ON CONFLICT(day, scope) DO UPDATE SET downloaded=downloaded+excluded.downloaded, uploaded=uploaded+excluded.uploaded"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(dayKey(date), to: 1, in: statement)
        bind(scope, to: 2, in: statement)
        sqlite3_bind_int64(statement, 3, downloaded)
        sqlite3_bind_int64(statement, 4, uploaded)
        if sqlite3_step(statement) != SQLITE_DONE { NSLog("WiFi Monitor could not persist usage") }
    }

    private func dayKey(_ date: Date) -> String {
        dayFormatter.timeZone = .current
        return dayFormatter.string(from: date)
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer?) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }

    private func execute(_ sql: String) throws {
        guard let database, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.execute }
    }

    private func hasScopeColumn() -> Bool {
        guard let database else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(usage)", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == "scope" { return true }
        }
        return false
    }

    private enum StoreError: LocalizedError {
        case open
        case execute
        var errorDescription: String? {
            switch self {
            case .open: return "The local usage database could not be opened."
            case .execute: return "The local usage database could not be initialized."
            }
        }
    }
}
