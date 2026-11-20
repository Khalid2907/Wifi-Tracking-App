import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers
import WiFiMonitorCore

@main
struct WiFiMonitorApp: App {
    @NSApplicationDelegateAdaptor(WiFiMonitorAppDelegate.self) private var appDelegate
    @StateObject private var model = MonitorModel()

    var body: some Scene {
        WindowGroup("WiFi Monitor", id: "dashboard") {
            DashboardView(model: model)
                .frame(minWidth: 700, minHeight: 520)
        }

        MenuBarExtra {
            MenuDashboard(model: model)
                .padding(16)
                .frame(width: 300)
        } label: {
            Text(model.menuBarTitle)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(width: 400)
                .padding(20)
        }
    }
}

@MainActor
private final class WiFiMonitorAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private struct MenuDashboard: View {
    @ObservedObject var model: MonitorModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("WiFi Monitor", systemImage: "wifi")
                    .font(.headline)
                Spacer()
                Circle().fill(model.snapshot.isConnected ? .green : .secondary).frame(width: 8, height: 8)
            }
            HStack(spacing: 12) {
                SpeedTile(title: "Download", symbol: "arrow.down", rate: model.snapshot.downloadBytesPerSecond, color: .blue)
                SpeedTile(title: "Upload", symbol: "arrow.up", rate: model.snapshot.uploadBytesPerSecond, color: .orange)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Downloaded today").foregroundStyle(.secondary)
                    Text(ByteFormatter.bytes(model.snapshot.downloadedToday)).fontWeight(.semibold)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Uploaded today").foregroundStyle(.secondary)
                    Text(ByteFormatter.bytes(model.snapshot.uploadedToday)).fontWeight(.semibold)
                }
            }.font(.subheadline)
            Label(model.snapshot.networkName ?? (model.snapshot.isConnected ? "Connected" : "Not connected"),
                  systemImage: model.snapshot.isConnected ? "wifi" : "wifi.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Dashboard") { openWindow(id: "dashboard") }
                Spacer()
                if #available(macOS 14.0, *) {
                    SettingsLink { Text("Settings") }
                } else {
                    Button("Settings") { NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            Text("Monitoring continues while this dashboard is closed. Choose Quit to stop monitoring.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct SpeedTile: View {
    let title: String
    let symbol: String
    let rate: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(ByteFormatter.rate(rate)).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DashboardView: View {
    @ObservedObject var model: MonitorModel

    private var chartRows: [DailyUsage] {
        let calendar = Calendar.current
        let now = Date.now
        switch model.historyPeriod {
        case .week:
            let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -6, to: now) ?? now)
            return dailyRows(from: start, through: now)
        case .month:
            let start = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
            return dailyRows(from: start, through: now)
        case .year:
            let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
            let start = calendar.date(byAdding: .month, value: -11, to: thisMonth) ?? thisMonth
            let filtered = model.history.filter { $0.date >= start }
            let grouped = Dictionary(grouping: filtered) { calendar.dateInterval(of: .month, for: $0.date)?.start ?? $0.date }
            return (0..<12).compactMap { offset in
                guard let month = calendar.date(byAdding: .month, value: offset, to: start) else { return nil }
                let days = grouped[month] ?? []
                return DailyUsage(date: month, downloaded: days.reduce(0) { $0 + $1.downloaded }, uploaded: days.reduce(0) { $0 + $1.uploaded })
            }
        }
    }

    private func dailyRows(from start: Date, through end: Date) -> [DailyUsage] {
        let calendar = Calendar.current
        let values = Dictionary(uniqueKeysWithValues: model.history.map { (calendar.startOfDay(for: $0.date), $0) })
        var rows: [DailyUsage] = []
        var day = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)
        while day <= lastDay {
            let usage = values[day]
            rows.append(DailyUsage(date: day, downloaded: usage?.downloaded ?? 0, uploaded: usage?.uploaded ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return rows
    }

    private var periodTotal: Int64 { chartRows.reduce(0) { $0 + $1.total } }
    private var periodAverage: Int64 {
        let elapsedPeriods = max(1, chartRows.filter { $0.total > 0 }.count)
        return periodTotal / Int64(elapsedPeriods)
    }
    private var peakPeriod: DailyUsage? { chartRows.max { $0.total < $1.total } }
    private var periodSummaryTitle: String {
        switch model.historyPeriod {
        case .week: return "Last 7 days"
        case .month: return Date.now.formatted(.dateTime.month(.wide))
        case .year: return "Last 12 months"
        }
    }
    private var averageLabel: String { model.historyPeriod == .year ? "Average active month" : "Average active day" }
    private var peakLabel: String { model.historyPeriod == .year ? "Highest month" : "Highest day" }
    private func periodLabel(for usage: DailyUsage) -> String {
        usage.date.formatted(model.historyPeriod == .year ? .dateTime.month(.abbreviated).year() : .dateTime.month(.abbreviated).day())
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Network overview").font(.largeTitle.bold())
                    Text("Passive interface statistics, stored on this Mac").foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.snapshot.networkName ?? (model.snapshot.isConnected ? "Connected" : "Offline"),
                      systemImage: model.snapshot.isConnected ? "wifi" : "wifi.slash")
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.quaternary, in: Capsule())
            }

            HStack(spacing: 16) {
                MetricCard(title: "Download speed", value: ByteFormatter.rate(model.snapshot.downloadBytesPerSecond), symbol: "arrow.down", tint: .blue)
                MetricCard(title: "Upload speed", value: ByteFormatter.rate(model.snapshot.uploadBytesPerSecond), symbol: "arrow.up", tint: .orange)
                MetricCard(title: "Used today", value: ByteFormatter.bytes(model.snapshot.downloadedToday + model.snapshot.uploadedToday), symbol: "chart.bar", tint: .purple)
            }

            if let notice = model.snapshot.measurementNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if let warning = model.storageWarning {
                Label("History storage unavailable: \(warning)", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            GroupBox("Today") {
                VStack(spacing: 14) {
                    UsageRow(title: "Downloaded", value: model.snapshot.downloadedToday, tint: .blue)
                    UsageRow(title: "Uploaded", value: model.snapshot.uploadedToday, tint: .orange)
                    Divider()
                    HStack { Text("Combined").fontWeight(.semibold); Spacer(); Text(ByteFormatter.bytes(model.snapshot.downloadedToday + model.snapshot.uploadedToday)).fontWeight(.semibold) }
                }.padding(.top, 8)
            }

            GroupBox("Speed summary this session") {
                HStack(spacing: 28) {
                    LabeledContent("Peak download", value: ByteFormatter.rate(model.snapshot.peakDownloadSpeed))
                    LabeledContent("Peak upload", value: ByteFormatter.rate(model.snapshot.peakUploadSpeed))
                    LabeledContent("Average down / up", value: "\(ByteFormatter.rate(model.snapshot.averageDownloadSpeed)) / \(ByteFormatter.rate(model.snapshot.averageUploadSpeed))")
                }.padding(.top, 8)
            }

            GroupBox("Usage comparison") {
                VStack(spacing: 10) {
                    comparisonRow("This week", current: usage(since: .weekOfYear, offset: 0), previous: usage(since: .weekOfYear, offset: -1))
                    comparisonRow("This month", current: usage(since: .month, offset: 0), previous: usage(since: .month, offset: -1))
                }.padding(.top, 8)
            }

            GroupBox("Wi-Fi networks used") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Separate usage for each Wi-Fi name observed by the app.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.networkUsage.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: model.snapshot.wifiConnected ? "wifi" : "chart.bar")
                                .font(.title2).foregroundStyle(.secondary)
                            Text(model.snapshot.wifiConnected && model.snapshot.networkName == nil
                                 ? "Wi-Fi network name unavailable"
                                 : "No Wi-Fi network history yet")
                                .font(.headline)
                            Text(model.snapshot.wifiConnected && model.snapshot.networkName == nil
                                 ? "The connection is active, but macOS did not provide its SSID. Per-network usage will appear when the network name is available."
                                 : "Usage appears after the monitor observes traffic on a named Wi-Fi network.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 100)
                    } else {
                        ForEach(model.networkUsage) { network in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Label(network.networkName, systemImage: "wifi")
                                        .font(.headline)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("Today \(ByteFormatter.bytes(network.todayTotal))")
                                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                                }
                                HStack(spacing: 14) {
                                    Text("↓ \(ByteFormatter.bytes(network.downloaded))")
                                    Text("↑ \(ByteFormatter.bytes(network.uploaded))")
                                    Spacer()
                                    Text("Lifetime \(ByteFormatter.bytes(network.total))")
                                        .fontWeight(.medium)
                                }
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                Text("Last used \(network.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 8)
                            if network.id != model.networkUsage.last?.id { Divider() }
                        }
                    }
                    Text("Usage near network changes may be omitted from these per-network totals. Networks sharing the same Wi-Fi name are grouped together.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Usage history").font(.headline)
                            Text(model.historyPeriod == .month ? "Daily download and upload · \(periodSummaryTitle)" : "Download and upload over time")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Export CSV") { exportCSV() }
                        Picker("History range", selection: $model.historyPeriod) {
                            ForEach(HistoryPeriod.allCases) { period in Text(period.rawValue).tag(period) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                    HStack(spacing: 10) {
                        MetricCard(title: periodSummaryTitle, value: ByteFormatter.bytes(periodTotal), symbol: "sum", tint: .purple)
                        MetricCard(title: averageLabel, value: ByteFormatter.bytes(periodAverage), symbol: "divide", tint: .teal)
                        MetricCard(title: peakLabel, value: peakPeriod.map { ByteFormatter.bytes($0.total) } ?? ByteFormatter.bytes(0), symbol: "arrow.up.right", tint: .orange)
                    }
                    if let peakPeriod {
                        Text("Peak: \(periodLabel(for: peakPeriod)) · ↓ \(ByteFormatter.bytes(peakPeriod.downloaded)) · ↑ \(ByteFormatter.bytes(peakPeriod.uploaded))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if chartRows.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "chart.bar").font(.title2).foregroundStyle(.secondary)
                            Text("No history yet").font(.headline)
                            Text("Usage appears after the monitor records traffic.").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        Chart {
                            ForEach(chartRows) { day in
                                BarMark(x: .value("Date", day.date, unit: model.historyPeriod == .year ? .month : .day),
                                        y: .value("Usage", day.downloaded))
                                    .foregroundStyle(by: .value("Direction", "Downloaded"))
                                    .position(by: .value("Direction", "Downloaded"))
                                BarMark(x: .value("Date", day.date, unit: model.historyPeriod == .year ? .month : .day),
                                        y: .value("Usage", day.uploaded))
                                    .foregroundStyle(by: .value("Direction", "Uploaded"))
                                    .position(by: .value("Direction", "Uploaded"))
                            }
                        }
                        .chartForegroundStyleScale(domain: ["Downloaded", "Uploaded"], range: [.blue, .orange])
                        .chartLegend(position: .bottom)
                        .chartYAxis { AxisMarks { value in
                            AxisGridLine().foregroundStyle(.quaternary)
                            AxisValueLabel { if let bytes = value.as(Int64.self) { Text(ByteFormatter.bytes(bytes)) } }
                        } }
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: model.historyPeriod == .month ? 8 : 6)) { value in
                                AxisGridLine().foregroundStyle(.quaternary)
                                AxisValueLabel(format: model.historyPeriod == .year ? .dateTime.month(.abbreviated) : .dateTime.day())
                            }
                        }
                        .frame(height: 230)
                    }
                    if model.historyPeriod == .month {
                        Text("Each bar pair represents one calendar day. Days without saved usage show zero and may include periods when the app was not observing.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }

            GroupBox("Connection") {
                HStack(spacing: 30) {
                    LabeledContent("Status", value: model.snapshot.isConnected ? "Connected" : "Offline")
                    LabeledContent("Interface", value: model.snapshot.interfaceName ?? "—")
                    LabeledContent("Network", value: model.snapshot.networkName ?? (model.snapshot.isConnected ? "SSID unavailable" : "—"))
                }.padding(.top, 8)
            }
        }
        .padding(28)
        }
        .onAppear { model.refreshHistory(); model.refreshNetworkUsage() }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "wifi-usage.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.csvContents().write(to: url, atomically: true, encoding: .utf8) }
        catch { NSLog("WiFi Monitor CSV export failed: %@", error.localizedDescription) }
    }

    private func usage(since component: Calendar.Component, offset: Int) -> Int64 {
        let calendar = Calendar.current
        let interval = calendar.dateInterval(of: component, for: .now)
        guard let interval else { return 0 }
        let start: Date
        let end: Date
        if offset == 0 { start = interval.start; end = interval.end }
        else {
            let shifted = calendar.date(byAdding: component, value: offset, to: interval.start) ?? interval.start
            start = shifted
            end = interval.start
        }
        return model.history.filter { $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.total }
    }

    private func comparisonRow(_ title: String, current: Int64, previous: Int64) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(ByteFormatter.bytes(current)).fontWeight(.semibold)
            Text("prior: \(ByteFormatter.bytes(previous))").foregroundStyle(.secondary)
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct UsageRow: View {
    let title: String
    let value: Int64
    let tint: Color

    var body: some View {
        HStack {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(title)
            Spacer()
            Text(ByteFormatter.bytes(value)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        Form {
            Section("Monitoring") {
                Picker("Sampling interval", selection: $model.samplingInterval) {
                    Text("2 seconds").tag(2)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                Picker("Interfaces", selection: $model.mode) {
                    ForEach(MonitoringMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                if model.mode == .manual {
                    Picker("Interface", selection: $model.selectedInterfaceName) {
                        ForEach(model.availableInterfaces, id: \.self) { name in Text(name).tag(name) }
                    }
                }
                Text("All interfaces can include VPN or virtual adapters. Wi-Fi mode counts only detected Wi-Fi interfaces.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Picker("Display", selection: $model.display) {
                    ForEach(MenuBarDisplay.allCases) { item in Text(item.rawValue).tag(item) }
                }
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.startAtLogin },
                    set: { model.setStartAtLogin($0) }
                ))
                Text(model.loginItemStatusMessage)
                    .font(.caption).foregroundStyle(.secondary)
                if model.loginItemNeedsApproval {
                    Button("Open Login Items Settings") { model.openLoginItemsSettings() }
                }
                Text("WiFi Monitor runs in your signed-in macOS session. Closing its window keeps the menu bar monitor active; Quit stops it until the next login.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Usage limits") {
                TextField("Daily limit (GB; 0 disables)", value: $model.dailyLimitGB, format: .number)
                TextField("Weekly limit (GB; 0 disables)", value: $model.weeklyLimitGB, format: .number)
                TextField("Monthly limit (GB; 0 disables)", value: $model.monthlyLimitGB, format: .number)
                Toggle("Send usage notifications", isOn: $model.notificationsEnabled)
                TextField("Thresholds (%)", text: $model.alertThresholds)
                Text("Enter comma-separated percentages from 1 to 100. Alerts are checked once per minute while the monitor samples.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Statistics stay in local application support storage. WiFi Monitor does not inspect packets or send usage data over the internet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
