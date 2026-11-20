import AppKit
import CoreWLAN
import Foundation
import Network
import UserNotifications
import ServiceManagement
import WiFiMonitorCore

@MainActor
final class MonitorModel: ObservableObject {
    @Published private(set) var snapshot = MonitorSnapshot()
    @Published private(set) var availableInterfaces: [String] = []
    @Published private(set) var history: [DailyUsage] = []
    @Published private(set) var networkUsage: [NetworkUsageSummary] = []
    @Published private(set) var storageWarning: String?
    @Published var historyPeriod: HistoryPeriod { didSet { UserDefaults.standard.set(historyPeriod.rawValue, forKey: "historyPeriod") } }
    @Published var mode: MonitoringMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "monitoringMode"); snapshot.mode = mode; scopeDidChange() } }
    @Published var display: MenuBarDisplay { didSet { UserDefaults.standard.set(display.rawValue, forKey: "menuBarDisplay") } }
    @Published var selectedInterfaceName: String { didSet { UserDefaults.standard.set(selectedInterfaceName, forKey: "selectedInterface"); scopeDidChange() } }
    @Published var dailyLimitGB: Double { didSet { UserDefaults.standard.set(dailyLimitGB, forKey: "dailyLimitGB") } }
    @Published var weeklyLimitGB: Double { didSet { UserDefaults.standard.set(weeklyLimitGB, forKey: "weeklyLimitGB") } }
    @Published var monthlyLimitGB: Double { didSet { UserDefaults.standard.set(monthlyLimitGB, forKey: "monthlyLimitGB") } }
    @Published var notificationsEnabled: Bool { didSet {
        UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled")
        if notificationsEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error { NSLog("WiFi Monitor notification permission: %@", error.localizedDescription) }
            }
        }
    } }
    @Published var alertThresholds: String { didSet { UserDefaults.standard.set(alertThresholds, forKey: "alertThresholds") } }
    @Published var samplingInterval: Int { didSet {
        UserDefaults.standard.set(samplingInterval, forKey: "samplingInterval")
        start()
    } }
    @Published private(set) var startAtLogin = false
    @Published private(set) var loginItemStatusMessage = ""
    @Published private(set) var loginItemNeedsApproval = false

    private let store = UsageStore()
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "wifi.monitor.path", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var previous: [String: InterfaceCounters] = [:]
    private var previousDate: Date?
    private var previousMonotonicTime: TimeInterval?
    private var pendingDownload: Int64 = 0
    private var pendingUpload: Int64 = 0
    private var pendingNetworkUsage: [String: (downloaded: Int64, uploaded: Int64)] = [:]
    private var baseDownload: Int64 = 0
    private var baseUpload: Int64 = 0
    private var displayedDayKey = ""
    private var lastScopeKey = ""
    private var lastFlush = Date()
    private var lastAlertCheck = Date.distantPast
    private var rateSamples = 0
    private var downloadRateTotal = 0.0
    private var uploadRateTotal = 0.0
    private var isSleeping = false
    private var pathIsSatisfied = false
    private var pathUsesWiFi = false

    init() {
        mode = MonitoringMode(rawValue: UserDefaults.standard.string(forKey: "monitoringMode") ?? "") ?? .wifi
        historyPeriod = HistoryPeriod(rawValue: UserDefaults.standard.string(forKey: "historyPeriod") ?? "") ?? .month
        display = MenuBarDisplay(rawValue: UserDefaults.standard.string(forKey: "menuBarDisplay") ?? "") ?? .both
        selectedInterfaceName = UserDefaults.standard.string(forKey: "selectedInterface") ?? ""
        dailyLimitGB = UserDefaults.standard.double(forKey: "dailyLimitGB")
        weeklyLimitGB = UserDefaults.standard.double(forKey: "weeklyLimitGB")
        monthlyLimitGB = UserDefaults.standard.double(forKey: "monthlyLimitGB")
        notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
        alertThresholds = UserDefaults.standard.string(forKey: "alertThresholds") ?? "50, 75, 90, 100"
        let savedInterval = UserDefaults.standard.integer(forKey: "samplingInterval")
        samplingInterval = [2, 5, 10].contains(savedInterval) ? savedInterval : 5
        storageWarning = store.initializationError
        snapshot.mode = mode
        lastScopeKey = scopeKey
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.pathIsSatisfied = path.status == .satisfied
                self.pathUsesWiFi = path.usesInterfaceType(.wifi)
                if self.mode != .wifi { self.snapshot.isConnected = self.pathIsSatisfied }
            }
        }
        pathMonitor.start(queue: pathQueue)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pauseForSleep() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeAfterWake() }
        }
        let totals = store.totals(scope: scopeKey)
        baseDownload = totals.downloaded
        baseUpload = totals.uploaded
        displayedDayKey = store.dayKey()
        snapshot.downloadedToday = baseDownload
        snapshot.uploadedToday = baseUpload
        refreshHistory()
        refreshNetworkUsage()
        configureInitialLoginItemPreference()
        start()
    }

    deinit {
        timer?.cancel()
        pathMonitor.cancel()
    }

    var menuBarTitle: String {
        switch display {
        case .both: return "↓ \(ByteFormatter.rate(snapshot.downloadBytesPerSecond))  ↑ \(ByteFormatter.rate(snapshot.uploadBytesPerSecond))"
        case .download: return "↓ \(ByteFormatter.rate(snapshot.downloadBytesPerSecond))"
        case .upload: return "↑ \(ByteFormatter.rate(snapshot.uploadBytesPerSecond))"
        case .combined: return "↕ \(ByteFormatter.rate(snapshot.downloadBytesPerSecond + snapshot.uploadBytesPerSecond))"
        case .today: return "↕ \(ByteFormatter.bytes(snapshot.downloadedToday + snapshot.uploadedToday))"
        }
    }

    private func start() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "wifi.monitor.sample", qos: .utility))
        source.schedule(deadline: .now(), repeating: .seconds(samplingInterval), leeway: .seconds(1))
        source.setEventHandler { [weak self] in
            let current = NetworkInterfaceManager.shared.counters()
            let monotonicTime = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in self?.sample(current, monotonicTime: monotonicTime) }
        }
        timer = source
        source.resume()
    }

    private func sample(_ current: [String: InterfaceCounters], monotonicTime: TimeInterval) {
        guard !isSleeping else { return }
        let now = Date()
        let names = current.keys.sorted()
        if availableInterfaces != names { availableInterfaces = names }
        let eligible = current.filter { name, item in
            mode == .all || (mode == .wifi && item.isWiFi) || (mode == .manual && name == selectedInterfaceName)
        }
        let activeWiFiName = current.keys.sorted().compactMap { name -> String? in
            guard let item = current[name], item.isWiFi, let ssid = item.networkName, !ssid.isEmpty else { return nil }
            return ssid
        }.first
        let hasWiFiInterface = current.values.contains(where: { $0.isWiFi })
        snapshot.wifiConnected = activeWiFiName != nil || (hasWiFiInterface && pathIsSatisfied && pathUsesWiFi)
        var currentName = eligible.keys.sorted().first(where: { name in
            guard let item = eligible[name] else { return false }
            return item.received > 0 || item.sent > 0
        }) ?? eligible.keys.sorted().first
        snapshot.interfaceName = currentName
        snapshot.networkName = activeWiFiName
        snapshot.isConnected = mode == .wifi
            ? hasWiFiInterface && (snapshot.networkName != nil || (pathIsSatisfied && pathUsesWiFi))
            : pathIsSatisfied
        snapshot.measurementNotice = eligible.values.contains(where: { $0.counterSource == .getifaddrs32 })
            ? "Using 32-bit fallback counters. Very fast transfers may exceed their counter range."
            : nil

        guard previousDate != nil, let previousMonotonicTime else {
            self.previous = eligible
            self.previousDate = now
            self.previousMonotonicTime = monotonicTime
            updateToday()
            return
        }
        let elapsed = monotonicTime - previousMonotonicTime
        guard elapsed > 0, elapsed < 30 else {
            self.previous = eligible
            self.previousDate = now
            self.previousMonotonicTime = monotonicTime
            snapshot.downloadBytesPerSecond = 0
            snapshot.uploadBytesPerSecond = 0
            snapshot.measurementNotice = elapsed >= 30
                ? "Observation gap detected. Traffic during the gap is not included in the rate calculation."
                : "Invalid sampling interval; this measurement was skipped."
            updateToday()
            return
        }
        let counterReset = eligible.contains { name, item in
            guard let old = self.previous[name] else { return false }
            return item.received < old.received || item.sent < old.sent
        }
        if counterReset {
            snapshot.measurementNotice = "An interface counter reset was detected. The affected interval is excluded."
        }
        let delta = CounterDelta.between(self.previous, and: eligible)
        let received = delta.received
        let sent = delta.sent
        for (name, item) in eligible {
            guard item.isWiFi, let networkName = item.networkName, !networkName.isEmpty,
                  let old = self.previous[name], old.isWiFi, old.networkName == networkName else { continue }
            let down = item.received >= old.received ? Int64(clamping: item.received - old.received) : 0
            let up = item.sent >= old.sent ? Int64(clamping: item.sent - old.sent) : 0
            guard down > 0 || up > 0 else { continue }
            let existing = pendingNetworkUsage[networkName] ?? (0, 0)
            pendingNetworkUsage[networkName] = (existing.downloaded + down, existing.uploaded + up)
        }
        let trafficByInterface = eligible.compactMap { name, item -> (String, UInt64)? in
            guard let old = self.previous[name] else { return nil }
            let down = item.received >= old.received ? item.received - old.received : 0
            let up = item.sent >= old.sent ? item.sent - old.sent : 0
            return (name, down &+ up)
        }
        currentName = trafficByInterface.sorted { $0.1 > $1.1 }.first(where: { $0.1 > 0 })?.0 ?? currentName
        snapshot.interfaceName = currentName
        snapshot.networkName = activeWiFiName
        pendingDownload += Int64(clamping: received)
        pendingUpload += Int64(clamping: sent)
        let instantDownload = Double(received) / elapsed
        let instantUpload = Double(sent) / elapsed
        snapshot.downloadBytesPerSecond = snapshot.downloadBytesPerSecond * 0.35 + instantDownload * 0.65
        snapshot.uploadBytesPerSecond = snapshot.uploadBytesPerSecond * 0.35 + instantUpload * 0.65
        snapshot.peakDownloadSpeed = max(snapshot.peakDownloadSpeed, instantDownload)
        snapshot.peakUploadSpeed = max(snapshot.peakUploadSpeed, instantUpload)
        rateSamples += 1
        downloadRateTotal += instantDownload
        uploadRateTotal += instantUpload
        snapshot.averageDownloadSpeed = downloadRateTotal / Double(rateSamples)
        snapshot.averageUploadSpeed = uploadRateTotal / Double(rateSamples)
        self.previous = eligible
        self.previousDate = now
        self.previousMonotonicTime = monotonicTime
        updateToday()
        if now.timeIntervalSince(lastFlush) >= 15 { flush(at: now) }
        if now.timeIntervalSince(lastHistoryRefresh) >= 60 {
            refreshHistory()
            refreshNetworkUsage()
            lastHistoryRefresh = now
        }
        if now.timeIntervalSince(lastAlertCheck) >= 60 { checkUsageAlerts(at: now); lastAlertCheck = now }
    }

    private var lastHistoryRefresh = Date.distantPast

    private var scopeKey: String {
        switch mode {
        case .wifi: return "wifi"
        case .all: return "all"
        case .manual: return "interface:\(selectedInterfaceName)"
        }
    }

    private func scopeDidChange() {
        guard lastScopeKey != scopeKey else { return }
        flush(at: .now, scope: lastScopeKey)
        lastScopeKey = scopeKey
        let totals = store.totals(scope: scopeKey)
        baseDownload = totals.downloaded
        baseUpload = totals.uploaded
        resetBaseline()
        updateToday()
        refreshHistory()
    }

    func refreshHistory() {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        history = store.recentDays(limit: 370, scope: scopeKey).compactMap { record in
            guard let date = formatter.date(from: record.day) else { return nil }
            return DailyUsage(date: date, downloaded: record.downloaded, uploaded: record.uploaded)
        }.reversed()
        lastHistoryRefresh = .now
    }

    func refreshNetworkUsage() {
        networkUsage = store.networkSummaries()
    }

    func setStartAtLogin(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "startAtLoginEnabled")
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginItemStatus()
        } catch {
            refreshLoginItemStatus()
            loginItemStatusMessage = "Could not change the login setting: \(error.localizedDescription)"
            NSLog("WiFi Monitor login item update failed: %@", error.localizedDescription)
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func configureInitialLoginItemPreference() {
        let key = "startAtLoginEnabled"
        let savedPreference = UserDefaults.standard.object(forKey: key) as? Bool
        let shouldEnable = savedPreference ?? true
        if savedPreference == nil { UserDefaults.standard.set(true, forKey: key) }
        if shouldEnable && SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
            do {
                try SMAppService.mainApp.register()
            } catch {
                refreshLoginItemStatus()
                loginItemStatusMessage = "Could not register for login: \(error.localizedDescription)"
                NSLog("WiFi Monitor initial login registration failed: %@", error.localizedDescription)
                return
            }
        }
        refreshLoginItemStatus()
    }

    private func refreshLoginItemStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            startAtLogin = true
            loginItemNeedsApproval = false
            loginItemStatusMessage = "Enabled. WiFi Monitor will open when you sign in."
        case .requiresApproval:
            startAtLogin = true
            loginItemNeedsApproval = true
            loginItemStatusMessage = "Registered, but macOS needs your approval before it can start at login."
        case .notRegistered:
            startAtLogin = false
            loginItemNeedsApproval = false
            loginItemStatusMessage = "Disabled."
        case .notFound:
            startAtLogin = false
            loginItemNeedsApproval = false
            loginItemStatusMessage = "macOS could not find the login item. Keep the app in Applications and reopen it."
        @unknown default:
            startAtLogin = false
            loginItemNeedsApproval = false
            loginItemStatusMessage = "macOS returned an unknown login item status."
        }
    }

    func csvContents() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return (["date,downloaded_bytes,uploaded_bytes,total_bytes"] + history.map { day in
            "\(formatter.string(from: day.date)),\(day.downloaded),\(day.uploaded),\(day.total)"
        }).joined(separator: "\n") + "\n"
    }

    private func checkUsageAlerts(at date: Date) {
        guard notificationsEnabled else { return }
        let thresholds = alertThresholds.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .filter { (1...100).contains($0) }.sorted()
        guard !thresholds.isEmpty else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? today
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: date)
        let weekStart = weekInterval?.start ?? calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let windows: [(name: String, label: String, start: Date, limit: Double)] = [
            ("daily", "daily", today, dailyLimitGB),
            ("weekly", "weekly", weekStart, weeklyLimitGB),
            ("monthly", "monthly", monthStart, monthlyLimitGB)
        ]
        for window in windows where window.limit > 0 {
            let totals = store.total(from: window.start, through: date, scope: scopeKey)
            let used = Double(totals.downloaded + totals.uploaded + pendingDownload + pendingUpload)
            let limitBytes = window.limit * 1_000_000_000
            let windowKey = "\(window.name):\(store.dayKey(for: window.start))"
            let windowDefaultsKey = "alertWindow.\(window.name)"
            let thresholdsDefaultsKey = "alertedThresholds.\(window.name)"
            if UserDefaults.standard.string(forKey: windowDefaultsKey) != windowKey {
                UserDefaults.standard.set(windowKey, forKey: windowDefaultsKey)
                UserDefaults.standard.set("", forKey: thresholdsDefaultsKey)
            }
            var alerted = Set((UserDefaults.standard.string(forKey: thresholdsDefaultsKey) ?? "").split(separator: ",").map(String.init))
            for threshold in thresholds where used >= limitBytes * threshold / 100 {
                let key = String(Int(threshold))
                guard !alerted.contains(key) else { continue }
                alerted.insert(key)
                let content = UNMutableNotificationContent()
                content.title = "WiFi Monitor usage alert"
                content.body = "You have reached \(Int(threshold))% of your \(window.label) data limit."
                let request = UNNotificationRequest(identifier: "\(window.name)-\(key)-\(windowKey)", content: content,
                                                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
                UNUserNotificationCenter.current().add(request)
            }
            UserDefaults.standard.set(alerted.sorted().joined(separator: ","), forKey: thresholdsDefaultsKey)
        }
    }

    private func updateToday() {
        let key = store.dayKey()
        if key != displayedDayKey {
            displayedDayKey = key
            flush(at: previousDate ?? .now)
            let totals = store.totals(scope: scopeKey)
            baseDownload = totals.downloaded
            baseUpload = totals.uploaded
        }
        snapshot.downloadedToday = baseDownload + pendingDownload
        snapshot.uploadedToday = baseUpload + pendingUpload
        snapshot.mode = mode
    }

    private func flush(at date: Date, scope: String? = nil) {
        let targetScope = scope ?? scopeKey
        store.add(downloaded: pendingDownload, uploaded: pendingUpload, at: date, scope: targetScope)
        for (networkName, usage) in pendingNetworkUsage {
            store.addNetworkUsage(networkName: networkName, downloaded: usage.downloaded, uploaded: usage.uploaded, at: date)
        }
        pendingNetworkUsage.removeAll(keepingCapacity: true)
        if targetScope == scopeKey {
            baseDownload += pendingDownload
            baseUpload += pendingUpload
        }
        pendingDownload = 0
        pendingUpload = 0
        lastFlush = date
        updateToday()
    }

    private func resetBaseline() {
        previous = [:]
        previousDate = nil
        previousMonotonicTime = nil
        snapshot.downloadBytesPerSecond = 0
        snapshot.uploadBytesPerSecond = 0
    }

    private func pauseForSleep() { flush(at: .now); isSleeping = true }

    private func resumeAfterWake() {
        guard isSleeping else { return }
        isSleeping = false
        resetBaseline()
        snapshot.downloadBytesPerSecond = 0
        snapshot.uploadBytesPerSecond = 0
    }
}
