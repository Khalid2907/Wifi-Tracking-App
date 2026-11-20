// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WiFiMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WiFi Monitor", targets: ["WiFiMonitor"]),
        .executable(name: "WiFiMonitorChecks", targets: ["WiFiMonitorChecks"])
    ],
    targets: [
        .executableTarget(
            name: "WiFiMonitor",
            dependencies: ["WiFiMonitorCore"],
            path: "Sources/WiFiMonitor",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "WiFiMonitorCore", path: "Sources/WiFiMonitorCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "WiFiMonitorChecks", dependencies: ["WiFiMonitorCore"], path: "Tests/WiFiMonitorTests", linkerSettings: [.linkedLibrary("sqlite3")])
    ]
)
