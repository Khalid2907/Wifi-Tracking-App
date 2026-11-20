import Foundation
import SQLite3
import WiFiMonitorCore

@main enum WiFiMonitorChecks {
    static func main() throws {
        try counterDeltaIgnoresNewInterfacesAndCounterResets()
        try dailyUsagePersistsAndSeparatesCalendarDays()
        try legacyDatabaseMigratesToWifiScope()
        try rateFormattingUsesExpectedDecimalUnits()
        print("All WiFi Monitor checks passed.")
    }

    private static func counterDeltaIgnoresNewInterfacesAndCounterResets() throws {
        let old = [
            "en7": InterfaceCounters(name: "en7", received: 1_000, sent: 500, isWiFi: true, networkName: nil),
            "en8": InterfaceCounters(name: "en8", received: 100, sent: 100, isWiFi: false, networkName: nil)
        ]
        let current = [
            "en7": InterfaceCounters(name: "en7", received: 1_400, sent: 650, isWiFi: true, networkName: nil),
            "en8": InterfaceCounters(name: "en8", received: 20, sent: 20, isWiFi: false, networkName: nil),
            "en9": InterfaceCounters(name: "en9", received: 900, sent: 900, isWiFi: false, networkName: nil)
        ]

        try expect(CounterDelta.between(old, and: current) == CounterDelta(received: 400, sent: 150), "counter deltas and resets")
    }

    private static func dailyUsagePersistsAndSeparatesCalendarDays() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = Calendar(identifier: .gregorian)
        let dayOne = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        let dayTwo = calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 12))!

        do {
            let store = UsageStore(directoryURL: directory)
            store.add(downloaded: 2_000, uploaded: 300, at: dayOne, scope: "wifi")
            store.add(downloaded: 50_000, uploaded: 8_000, at: dayOne, scope: "all")
            store.add(downloaded: 400, uploaded: 100, at: dayTwo, scope: "wifi")
            try expect(store.totals(for: dayOne).downloaded == 2_000, "daily downloads")
            try expect(store.totals(for: dayOne, scope: "all").downloaded == 50_000, "scope separation")
            try expect(store.totals(for: dayTwo).uploaded == 100, "daily uploads")
        }
        let reopened = UsageStore(directoryURL: directory)
        try expect(reopened.totals(for: dayOne).uploaded == 300, "persisted uploads")
        try expect(reopened.totals(for: dayTwo).downloaded == 400, "persisted downloads")
    }

    private static func rateFormattingUsesExpectedDecimalUnits() throws {
        try expect(ByteFormatter.rate(999) == "999.0 B/s", "bytes per second formatting")
        try expect(ByteFormatter.rate(1_000) == "1.0 KB/s", "kilobytes per second formatting")
        try expect(ByteFormatter.rate(1_000_000) == "1.0 MB/s", "megabytes per second formatting")
    }

    private static func legacyDatabaseMigratesToWifiScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("usage.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw CheckFailure(description: "open legacy database") }
        let sql = "CREATE TABLE usage (day TEXT PRIMARY KEY, downloaded INTEGER NOT NULL, uploaded INTEGER NOT NULL); INSERT INTO usage VALUES('2026-01-01', 1234, 567);"
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        sqlite3_close(database)
        try expect(result == SQLITE_OK, "create legacy database")

        let store = UsageStore(directoryURL: directory)
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        try expect(store.totals(for: date).downloaded == 1_234, "migrated legacy Wi-Fi downloads")
        try expect(store.totals(for: date, scope: "all").downloaded == 0, "legacy scope migration")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw CheckFailure(description: label) }
    }

    private struct CheckFailure: Error, CustomStringConvertible {
        let description: String
        init(description: String) { self.description = description }
    }
}
