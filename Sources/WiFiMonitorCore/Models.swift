import Foundation

public enum MonitoringMode: String, CaseIterable, Identifiable {
    case wifi = "Wi-Fi only"
    case all = "All interfaces"
    case manual = "Choose interface"
    public var id: String { rawValue }
}

public enum HistoryPeriod: String, CaseIterable, Identifiable {
    case week = "Week"
    case month = "Month"
    case year = "Year"
    public var id: String { rawValue }
    public var dayCount: Int { self == .week ? 7 : (self == .month ? 30 : 365) }
}

public struct DailyUsage: Identifiable, Sendable {
    public let date: Date
    public let downloaded: Int64
    public let uploaded: Int64
    public var id: Date { date }
    public var total: Int64 { downloaded + uploaded }
    public init(date: Date, downloaded: Int64, uploaded: Int64) { self.date = date; self.downloaded = downloaded; self.uploaded = uploaded }
}

public struct NetworkUsageSummary: Identifiable, Sendable {
    public let networkName: String
    public let downloaded: Int64
    public let uploaded: Int64
    public let todayDownloaded: Int64
    public let todayUploaded: Int64
    public let lastSeen: Date
    public var id: String { networkName }
    public var total: Int64 { downloaded + uploaded }
    public var todayTotal: Int64 { todayDownloaded + todayUploaded }
}

public struct CounterDelta: Equatable, Sendable {
    public let received: UInt64
    public let sent: UInt64

    public init(received: UInt64, sent: UInt64) { self.received = received; self.sent = sent }
    public static func between(_ previous: [String: InterfaceCounters], and current: [String: InterfaceCounters]) -> Self {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, value) in current {
            guard let old = previous[name] else { continue }
            if value.received >= old.received { received &+= value.received - old.received }
            if value.sent >= old.sent { sent &+= value.sent - old.sent }
        }
        return Self(received: received, sent: sent)
    }
}

public enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case both = "Both speeds"
    case download = "Download"
    case upload = "Upload"
    case combined = "Combined"
    case today = "Today's usage"
    public var id: String { rawValue }
}

public struct InterfaceCounters: Equatable, Sendable {
    public let name: String
    public let received: UInt64
    public let sent: UInt64
    public let isWiFi: Bool
    public let networkName: String?
    public let counterSource: CounterSource
    public init(name: String, received: UInt64, sent: UInt64, isWiFi: Bool, networkName: String?, counterSource: CounterSource = .getifaddrs32) {
        self.name = name; self.received = received; self.sent = sent; self.isWiFi = isWiFi; self.networkName = networkName; self.counterSource = counterSource
    }
}

public enum CounterSource: String, Sendable {
    case routeInterfaceList64
    case getifaddrs32
}

public struct MonitorSnapshot: Equatable {
    public var downloadBytesPerSecond: Double = 0
    public var uploadBytesPerSecond: Double = 0
    public var downloadedToday: Int64 = 0
    public var uploadedToday: Int64 = 0
    public var interfaceName: String?
    public var networkName: String?
    public var isConnected = false
    public var wifiConnected = false
    public var mode: MonitoringMode = .wifi
    public var peakDownloadSpeed: Double = 0
    public var peakUploadSpeed: Double = 0
    public var averageDownloadSpeed: Double = 0
    public var averageUploadSpeed: Double = 0
    public var measurementNotice: String?
    public init() {}
}

public enum ByteFormatter {
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        let units = [(1.0, "B/s"), (1_000.0, "KB/s"), (1_000_000.0, "MB/s"), (1_000_000_000.0, "GB/s")]
        let unit = units.last(where: { bytesPerSecond >= $0.0 }) ?? units[0]
        return String(format: "%.1f %@", bytesPerSecond / unit.0, unit.1)
    }
}
