import Foundation
import RelocDeviceBridge

/// Full details of a validated Remote Pairing service. The port is used by the
/// accessory (NMEA) session; `identifier` + `authTag` are additionally required
/// by the system-level LocationSimulation session.
struct RemotePairingServiceInfo {
    let port: UInt16
    let host: String
    let identifier: String
    let authTag: String
}

/// Discovers the device's live Remote Pairing TCP port via Bonjour (`_remotepairing._tcp.`)
/// and validates the advertised `authTag` against the stored pairing record's `alt_irk`.
@MainActor
final class RemotePairingDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var continuation: CheckedContinuation<RemotePairingServiceInfo?, Never>?
    private var timeout: Task<Void, Never>?
    private let record: Data

    init(record: Data) {
        self.record = record
    }

    nonisolated static func matches(record: Data, identifier: String, authTag: String) -> Bool {
        record.withUnsafeBytes { bytes in
            identifier.withCString { id in
                authTag.withCString { tag in
                    rl_device_pairing_matches(
                        bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        bytes.count,
                        id,
                        tag
                    )
                }
            }
        }
    }

    static func discoverPort(record: Data) async -> UInt16? {
        let info = await discoverService(record: record)
        return info?.port
    }

    /// Full discovery result used by the system-level LocationSimulation session, which
    /// needs the service identifier and auth tag in addition to the TCP port.
    static func discoverService(record: Data) async -> RemotePairingServiceInfo? {
        guard let plist = try? PropertyListSerialization.propertyList(from: record, format: nil) as? [String: Any],
              (plist["alt_irk"] as? Data)?.count == 16 else {
            return nil
        }
        let discovery = RemotePairingDiscovery(record: record)
        return await discovery.run()
    }

    private func run() async -> RemotePairingServiceInfo? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            browser.delegate = self
            browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.finish(nil)
            }
        }
    }

    private func finish(_ info: RemotePairingServiceInfo?) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        browser.stop()
        browser.delegate = nil
        services.forEach {
            $0.delegate = nil
            $0.stop()
        }
        services = []
        continuation.resume(returning: info)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 4)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish(nil)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard (1...65535).contains(sender.port), let txtData = sender.txtRecordData() else { return }
        let txt = NetService.dictionary(fromTXTRecord: txtData)
        let identifier = txt["identifier"].flatMap { String(data: $0, encoding: .utf8) } ?? sender.name
        guard let tag = txt["authTag"].flatMap({ String(data: $0, encoding: .utf8) }),
              Self.matches(record: record, identifier: identifier, authTag: tag) else {
            return
        }
        // The Remote Pairing service is reached through the virtual loopback peer.
        // Prefer a resolved 10.7.0.x address; otherwise use the standard 10.7.0.1.
        var host = "10.7.0.1"
        if let addresses = sender.addresses {
            for addressData in addresses {
                // addresses are binary sockaddr structures; extract the dotted IP.
                let ip = Self.ipv4String(from: addressData)
                if ip.hasPrefix("10.7.0.") {
                    host = ip
                    break
                }
            }
        }
        finish(RemotePairingServiceInfo(
            port: UInt16(sender.port),
            host: host,
            identifier: identifier,
            authTag: tag
        ))
    }

    private static func ipv4String(from data: Data) -> String {
        var addr = sockaddr_in()
        withUnsafeMutableBytes(of: &addr) { dest in
            data.copyBytes(to: dest, count: min(data.count, dest.count))
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}
