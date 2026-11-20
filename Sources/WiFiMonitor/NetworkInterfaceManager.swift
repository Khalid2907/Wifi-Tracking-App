import CoreWLAN
import Darwin
import Foundation
import WiFiMonitorCore

struct NetworkInterfaceManager: Sendable {
    static let shared = NetworkInterfaceManager()
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedWiFiDetails: [String: String] = [:]

    func counters() -> [String: InterfaceCounters] {
        let wifiDetails = Self.currentWiFiDetails()
        if let routeCounters = Self.routeInterfaceCounters() {
            return Self.makeCounters(routeCounters, wifiDetails: wifiDetails, source: .routeInterfaceList64)
        }
        return Self.getifaddrsCounters(wifiDetails: wifiDetails)
    }

    private static func makeCounters(
        _ rawCounters: [String: (received: UInt64, sent: UInt64, flags: Int32)],
        wifiDetails: [String: String],
        source: CounterSource
    ) -> [String: InterfaceCounters] {
        rawCounters.reduce(into: [:]) { result, pair in
            let (name, raw) = pair
            guard (raw.flags & Int32(IFF_LOOPBACK)) == 0 else { return }
            result[name] = InterfaceCounters(name: name, received: raw.received, sent: raw.sent,
                                             isWiFi: wifiDetails[name] != nil,
                                             networkName: wifiDetails[name].flatMap { $0.isEmpty ? nil : $0 },
                                             counterSource: source)
        }
    }

    /// Reads one route-list snapshot containing 64-bit per-interface counters.
    /// Returns nil on any sysctl or malformed-message failure so callers can use
    /// the explicitly lower-confidence getifaddrs fallback.
    private static func routeInterfaceCounters() -> [String: (received: UInt64, sent: UInt64, flags: Int32)]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        let sizeResult = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), nil, &length, nil, 0)
        }
        guard sizeResult == 0, length > 0, length < 64 * 1024 * 1024 else { return nil }

        var bytes = [UInt8](repeating: 0, count: length)
        let readResult = mib.withUnsafeMutableBufferPointer { mibBuffer in
            bytes.withUnsafeMutableBytes { storage in
                sysctl(mibBuffer.baseAddress, u_int(mibBuffer.count), storage.baseAddress, &length, nil, 0)
            }
        }
        guard readResult == 0, length <= bytes.count else { return nil }

        let dataOffset = MemoryLayout<if_msghdr2>.offset(of: \if_msghdr2.ifm_data) ?? MemoryLayout<if_msghdr2>.size
        let minimumLength = MemoryLayout<if_msghdr2>.size
        var result: [String: (received: UInt64, sent: UInt64, flags: Int32)] = [:]
        let parsed = bytes.withUnsafeBytes { storage -> Bool in
            guard let base = storage.baseAddress else { return false }
            var offset = 0
            while offset + MemoryLayout<UInt16>.size <= length {
                let messageLength = Int(base.advanced(by: offset).loadUnaligned(as: UInt16.self))
                guard messageLength >= MemoryLayout<UInt16>.size, offset + messageLength <= length else { return false }
                guard messageLength >= minimumLength else { offset += messageLength; continue }
                let header = base.advanced(by: offset).loadUnaligned(as: if_msghdr2.self)
                if header.ifm_type == UInt8(RTM_IFINFO2) {
                    guard messageLength >= dataOffset + MemoryLayout<if_data64>.size else { return false }
                    let index = UInt32(header.ifm_index)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    let resolvedName = nameBuffer.withUnsafeMutableBufferPointer { name in
                        if_indextoname(index, name.baseAddress)
                    }
                    if let resolvedName {
                        let name = String(cString: resolvedName)
                        let stats = base.advanced(by: offset + dataOffset).loadUnaligned(as: if_data64.self)
                        result[name] = (UInt64(stats.ifi_ibytes), UInt64(stats.ifi_obytes), Int32(header.ifm_flags))
                    }
                }
                offset += messageLength
            }
            return true
        }
        return parsed ? result : nil
    }

    private static func getifaddrsCounters(wifiDetails: [String: String]) -> [String: InterfaceCounters] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }

        var result: [String: InterfaceCounters] = [:]
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            let entry = item.pointee
            guard let rawName = entry.ifa_name, let data = entry.ifa_data,
                  (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: rawName)
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            let candidate = InterfaceCounters(name: name,
                                              received: UInt64(max(0, stats.ifi_ibytes)),
                                              sent: UInt64(max(0, stats.ifi_obytes)),
                                              isWiFi: wifiDetails[name] != nil,
                                              networkName: wifiDetails[name].flatMap { $0.isEmpty ? nil : $0 },
                                              counterSource: .getifaddrs32)
            if let existing = result[name] {
                result[name] = InterfaceCounters(name: name, received: max(candidate.received, existing.received),
                                                 sent: max(candidate.sent, existing.sent), isWiFi: candidate.isWiFi,
                                                 networkName: candidate.networkName, counterSource: .getifaddrs32)
            } else {
                result[name] = candidate
            }
        }
        return result
    }

    private static func currentWiFiDetails() -> [String: String] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let interfaces = CWWiFiClient.shared().interfaces() ?? []
        cachedWiFiDetails = Dictionary(uniqueKeysWithValues: interfaces.compactMap { interface in
            guard let name = interface.interfaceName else { return nil }
            return (name, interface.ssid() ?? "")
        })
        return cachedWiFiDetails
    }
}
