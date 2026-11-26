import CoreLocation
import Foundation
import MapKit
import Network
import SwiftUI

/// Cellular connection guidance, mirroring WrapPin Standard's mobile-data
/// workaround. On a pure cellular path iOS mDNSResponder does not answer local
/// Bonjour queries, so the on-device Remote Pairing service cannot be found.
/// Turning mobile data off briefly lets the local service resolve again.
///
/// Flow mirrors the original app (WrapPin Standard), verified against its
/// source and official Chinese manual. It keeps only three guidance states
/// (plus `none`), exactly like WrapPin's `MobileDataGuidance`:
///   turnOffData    -> detected cellular; card stays up asking to switch mobile
///                     data OFF while a discovery loop probes in the background.
///                     Returning to foreground or tapping "开始定位" probes now.
///   turnBackOnData -> session established; card asks to restore mobile data.
///   connectionHelp -> reserved; not entered by the current flow. Failure states
///                     stay on `turnOffData` so only one card can ever be shown.
public enum CellularGuidance: Equatable, Sendable {
    case none
    case turnOffData
    case turnBackOnData
    case connectionHelp
}

@MainActor
public final class RelocViewModel: ObservableObject {
    public let store = CredentialStore()
    public let coreLocation = LiveCoreLocationMonitor()
    private let keepAlive = BackgroundKeepAlive()
    private let geocoder = CLGeocoder()

    // MARK: - Loopback & Connection Settings
    @Published public var host: String {
        didSet {
            store.host = host
            invalidateDeviceConnection()
        }
    }
    @Published public var remotePort: UInt16 {
        didSet {
            store.remotePort = remotePort
            invalidateDeviceConnection()
        }
    }
    @Published public var lockdownPort: UInt16 {
        didSet {
            store.lockdownPort = lockdownPort
            invalidateDeviceConnection()
        }
    }
    @Published public var serviceName: String {
        didSet { store.serviceName = serviceName }
    }
    @Published public var intervalSeconds: Double {
        didSet { store.intervalSeconds = intervalSeconds }
    }
    @Published public var durationSeconds: Double {
        didSet { store.durationSeconds = durationSeconds }
    }
    @Published public var gcj02CorrectionEnabled: Bool {
        didSet { store.gcj02CorrectionEnabled = gcj02CorrectionEnabled }
    }
    @Published public var backgroundKeepAliveEnabled: Bool {
        didSet {
            store.backgroundKeepAliveEnabled = backgroundKeepAliveEnabled
            if snapshot.isRunning {
                keepAlive.start(useSilentAudio: backgroundKeepAliveEnabled)
            }
        }
    }
    @Published public var microJitterEnabled: Bool {
        didSet {
            store.microJitterEnabled = microJitterEnabled
            if snapshot.isRunning {
                if microJitterEnabled {
                    startJitterTimer()
                } else {
                    stopJitterTimer()
                    pushLocationToSession()
                }
            }
        }
    }
    @Published public var locationMode: LocationMode {
        didSet { store.locationMode = locationMode }
    }
    @Published public var appearanceMode: AppAppearanceMode {
        didSet { store.appearanceMode = appearanceMode }
    }
    @Published public var mapStyle: MapDisplayStyle {
        didSet { store.mapStyle = mapStyle }
    }

    // MARK: - Target & Selected Location (WGS-84)
    /// The location currently being sent to the iPhone (or ready to send).
    @Published public var targetLocation: TargetLocation {
        didSet {
            store.lastTargetLocation = targetLocation
            pushLocationToSession()
        }
    }
    /// Candidate pin dropped on the map while a session is already active (allows browsing before tapping "更新到此位置").
    @Published public var pendingLocation: TargetLocation?
    @Published public var selectedPlaceName: String = "选中位置"
    @Published public var selectedPlaceAddress: String = ""

    // MARK: - Favorites, Recents (30), & Recovery
    @Published public var favorites: [FavoriteLocation] = []
    @Published public var recents: [RecentLocation] = []
    @Published public var interruptedSession: InterruptedSessionRecord?

    // MARK: - Device Pairing & Verification State
    @Published public var pairingStatus: PairingStatus
    @Published public var deviceUDID: String
    @Published public var connectionVerified = false
    @Published public var isVerifyingConnection = false
    @Published public var connectionCheckFailed = false
    @Published public var deviceConnectionStatus = "请先配对这台 iPhone"
    @Published public var discoveredDevicePort: UInt16?

    // MARK: - Session & Diagnostics
    @Published public var snapshot = SessionSnapshot()
    @Published public var events: [ProtocolEvent] = []
    @Published public var alertMessage: String?
    /// One-shot request from the start-flow to open the system Location Services settings screen.
    @Published public var requestOpenLocationSettings = false

    // MARK: - Cellular (mobile data) guidance state
    /// Current mobile-data guidance step for the system-level simulation session.
    @Published public var cellularGuidance: CellularGuidance = .none
    /// Whether a WiFi interface currently satisfies an internet path. `nil` until
    /// NWPathMonitor delivers its first update, so startup can wait briefly.
    @Published public var isWiFiSatisfied: Bool?
    /// Human-readable discovery status shown in the guidance card.
    @Published public var cellularDiscoveryStatus = ""

    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let wifiMonitorQueue = DispatchQueue(label: "reloc.wifi.path", qos: .utility)
    private var cellularDiscoveryLoopTask: Task<Void, Never>?
    private var pendingSystemPairingData: Data?

    private var savedPairing: SavedPairing?
    private var mfiSigner: RLMFiSigner?
    private var session: AccessoryLocationSession?
    private var systemSession: SystemLocationSession?
    /// Tracks whether the system session ever reported "running". Early
    /// snapshots arrive with isRunning == false; without this guard the UI
    /// would treat startup as a disconnect and swap cards immediately.
    private var systemSessionWasRunning = false
    /// Set when the user stops the session on purpose. The stop path emits the
    /// same isRunning == false snapshot as a crash, so without this the guidance
    /// card would pop up right after the user pressed stop.
    private var systemSessionStopRequested = false
    /// Bumped on every start and on every stop. Callbacks carry the token they
    /// were created with, so a late snapshot from a previous session can never
    /// reopen the guidance card after the user stopped or restarted.
    private var systemSessionToken = 0
    /// Bounds automatic reconnects so a session that fails instantly cannot spin.
    private var systemSessionRestartCount = 0
    private var jitterTimer: Timer?

    public init() {
        self.host = store.host
        self.remotePort = store.remotePort
        self.lockdownPort = store.lockdownPort
        self.serviceName = store.serviceName
        self.intervalSeconds = store.intervalSeconds
        self.durationSeconds = store.durationSeconds
        self.gcj02CorrectionEnabled = store.gcj02CorrectionEnabled
        self.backgroundKeepAliveEnabled = store.backgroundKeepAliveEnabled
        self.microJitterEnabled = store.microJitterEnabled
        self.locationMode = store.locationMode
        self.appearanceMode = store.appearanceMode
        self.mapStyle = store.mapStyle
        self.targetLocation = store.lastTargetLocation
        self.favorites = store.loadFavorites()
        self.recents = store.loadRecents()
        self.interruptedSession = store.loadInterruptedSession()
        self.deviceUDID = store.deviceUDID

        self.mfiSigner = store.loadMFiSigner()

        let (pairing, pairStat) = store.loadPairing()
        self.savedPairing = pairing
        self.pairingStatus = pairStat
        self.deviceConnectionStatus = pairStat.isLoaded ? "配对记录已保存，等待连接验证" : "请先配对这台 iPhone"

        self.keepAlive.onDiagnostic = { [weak self] event, details in
            guard let self else { return }
            var payload = details
            payload["event"] = event
            let detailText: String
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                detailText = str
            } else {
                detailText = "{\"event\":\"\(event)\"}"
            }
            self.events.append(ProtocolEvent(name: event, detail: detailText))
            if self.events.count > 500 {
                self.events.removeFirst(self.events.count - 500)
            }
        }

        // Track WiFi availability so the system-level session can detect the
        // pure-cellular case and offer the WrapPin-style mobile-data workaround.
        wifiMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isWiFiSatisfied = satisfied
            }
        }
        wifiMonitor.start(queue: wifiMonitorQueue)

        reverseGeocode(wgsLocation: targetLocation)
    }

    // MARK: - Coordinate Mapping Helpers

    public func toMapCoordinate(_ wgs: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if gcj02CorrectionEnabled {
            return CoordinateTransform.wgs84ToGCJ02(lat: wgs.latitude, lon: wgs.longitude)
        }
        return wgs
    }

    public func fromMapCoordinate(_ mapCoord: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if gcj02CorrectionEnabled {
            return CoordinateTransform.gcj02ToWGS84(lat: mapCoord.latitude, lon: mapCoord.longitude)
        }
        return mapCoord
    }

    public var activeMapCoordinate: CLLocationCoordinate2D {
        toMapCoordinate(CLLocationCoordinate2D(latitude: targetLocation.latitude, longitude: targetLocation.longitude))
    }

    public var pendingMapCoordinate: CLLocationCoordinate2D? {
        guard let pending = pendingLocation else { return nil }
        return toMapCoordinate(CLLocationCoordinate2D(latitude: pending.latitude, longitude: pending.longitude))
    }

    /// Coordinate currently highlighted in the bottom card (pending selection if browsing, else active target).
    public var inspectedLocation: TargetLocation {
        pendingLocation ?? targetLocation
    }

    public var isCurrentInspectedFavorite: Bool {
        let loc = inspectedLocation
        return favorites.contains {
            abs($0.latitude - loc.latitude) < 1e-4 && abs($0.longitude - loc.longitude) < 1e-4
        }
    }

    public func selectLocationFromMap(_ mapCoord: CLLocationCoordinate2D, name: String? = nil, address: String? = nil) {
        let wgs = fromMapCoordinate(mapCoord)
        selectWGSLocation(
            TargetLocation(latitude: wgs.latitude, longitude: wgs.longitude, altitude: inspectedLocation.altitude),
            name: name,
            address: address
        )
    }

    public func selectWGSLocation(_ wgsLoc: TargetLocation, name: String? = nil, address: String? = nil) {
        if snapshot.isRunning {
            // Keep active reported location unchanged until user taps "更新到此位置".
            pendingLocation = wgsLoc
        } else {
            pendingLocation = nil
            targetLocation = wgsLoc
        }

        if let name, !name.isEmpty {
            selectedPlaceName = name
            selectedPlaceAddress = address ?? String(format: "%.5f, %.5f", wgsLoc.latitude, wgsLoc.longitude)
        } else {
            selectedPlaceName = String(format: "%.5f, %.5f", wgsLoc.latitude, wgsLoc.longitude)
            selectedPlaceAddress = "正在解析地名…"
            reverseGeocode(wgsLocation: wgsLoc)
        }
    }

    public func clearPendingSelection() {
        pendingLocation = nil
        reverseGeocode(wgsLocation: targetLocation)
    }

    public func applyPendingLocationUpdate() {
        guard let pending = pendingLocation else { return }
        targetLocation = pending
        pendingLocation = nil
        recordRecent(name: selectedPlaceName, subtitle: selectedPlaceAddress, location: targetLocation)
        persistRecoveryRecord()
    }

    private func reverseGeocode(wgsLocation: TargetLocation) {
        geocoder.cancelGeocode()
        let displayCoord = toMapCoordinate(CLLocationCoordinate2D(latitude: wgsLocation.latitude, longitude: wgsLocation.longitude))
        let clLoc = CLLocation(latitude: displayCoord.latitude, longitude: displayCoord.longitude)
        geocoder.reverseGeocodeLocation(clLoc) { [weak self] placemarks, _ in
            Task { @MainActor in
                guard let self, let pm = placemarks?.first else { return }
                let title = pm.name ?? pm.locality ?? pm.administrativeArea ?? String(format: "%.5f, %.5f", wgsLocation.latitude, wgsLocation.longitude)
                let parts = [pm.administrativeArea, pm.locality, pm.subLocality, pm.thoroughfare, pm.subThoroughfare]
                    .compactMap { $0 }
                    .reduce(into: [String]()) { acc, item in
                        if !acc.contains(item) { acc.append(item) }
                    }
                self.selectedPlaceName = title
                self.selectedPlaceAddress = parts.isEmpty
                    ? String(format: "%.5f, %.5f", wgsLocation.latitude, wgsLocation.longitude)
                    : parts.joined(separator: " ")
            }
        }
    }

    // MARK: - Optional Stationary Micro-Jitter

    private func startJitterTimer() {
        stopJitterTimer()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.microJitterEnabled, self.snapshot.isRunning else { return }
                self.pushLocationToSession()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        jitterTimer = timer
    }

    private func stopJitterTimer() {
        jitterTimer?.invalidate()
        jitterTimer = nil
    }

    private func pushLocationToSession() {
        let outgoing = microJitterEnabled
            ? CoordinateTransform.applyMicroJitter(to: targetLocation)
            : targetLocation
        session?.locationBox.set(outgoing)
        systemSession?.locationBox.set(outgoing)
    }

    // MARK: - Interrupted Session Recovery

    public func resumeInterruptedSession() {
        guard let record = interruptedSession else { return }
        interruptedSession = nil
        store.saveInterruptedSession(nil)

        targetLocation = TargetLocation(latitude: record.latitude, longitude: record.longitude, altitude: record.altitude)
        selectedPlaceName = record.placeName
        pendingLocation = nil
        start(mode: .send)
    }

    public func dismissInterruptedSession() {
        interruptedSession = nil
        store.saveInterruptedSession(nil)
    }

    private func persistRecoveryRecord() {
        let rec = InterruptedSessionRecord(
            placeName: selectedPlaceName,
            latitude: targetLocation.latitude,
            longitude: targetLocation.longitude,
            altitude: targetLocation.altitude
        )
        store.saveInterruptedSession(rec)
    }

    // MARK: - Device Pairing & Loopback Verification

    public var canStartSession: Bool {
        guard savedPairing != nil, !snapshot.isRunning else { return false }
        // Accessory NMEA injection needs an MFi signer; system-level simulation does not.
        return locationMode.requiresMFiCredential ? mfiSigner != nil : true
    }

    /// True when "开始定位" is disabled and the reason is a missing MFi credential
    /// in accessory mode (used by the UI to show an actionable hint).
    public var isBlockedByMissingMFiCredential: Bool {
        locationMode.requiresMFiCredential && mfiSigner == nil && savedPairing != nil
    }

    public var hasMFiCredential: Bool { mfiSigner != nil }

    /// Bumped by `reloadMFiCredential()` so SwiftUI re-evaluates the computed
    /// credential properties even though `mfiSigner` itself is not @Published.
    @Published public var mfiReloadToken: Int = 0

    public var mFiCredentialSummary: String {
        mfiSigner?.leafSubjectSummary ?? "未导入"
    }

    /// Where the credential came from (or why loading failed), shown under the
    /// MFi row in Settings. Without this the UI can only say "未导入", which
    /// hides whether the cause is a missing file or an unparsable one.
    public var mFiCredentialDiagnostic: String {
        CredentialStore.lastMFiDiagnostic
    }

    /// Injected by CI into Info.plist so the running build can be identified
    /// from inside the app — otherwise "I installed the new one" is unverifiable.
    public var buildStamp: String {
        (Bundle.main.infoDictionary?["RelocBuildStamp"] as? String) ?? "未注入（本地构建）"
    }

    /// Re-reads the credential from disk/bundle/binary without restarting.
    public func reloadMFiCredential() {
        mfiSigner = store.loadMFiSigner()
        // `mfiSigner` is not @Published, so bump a token to force a re-render.
        mfiReloadToken &+= 1
    }

    public func importMFiCredentials(certificateURL: URL, privateKeyURL: URL) {
        let certAccessed = certificateURL.startAccessingSecurityScopedResource()
        let keyAccessed = privateKeyURL.startAccessingSecurityScopedResource()
        defer {
            if certAccessed { certificateURL.stopAccessingSecurityScopedResource() }
            if keyAccessed { privateKeyURL.stopAccessingSecurityScopedResource() }
        }
        do {
            let certData = try Data(contentsOf: certificateURL)
            let keyData = try Data(contentsOf: privateKeyURL)
            mfiSigner = try store.importMFiCredentials(certificateData: certData, privateKeyData: keyData)
            alertMessage = "MFi 凭据已导入：\(mFiCredentialSummary)"
            events.append(ProtocolEvent(
                name: "mfi_credentials_imported",
                detail: "{\"event\":\"mfi_credentials_imported\"}"
            ))
        } catch {
            alertMessage = "MFi 凭据导入失败：\(error.localizedDescription)"
        }
    }

    public func invalidateDeviceConnection() {
        connectionVerified = false
        discoveredDevicePort = nil
        connectionCheckFailed = false
        deviceConnectionStatus = pairingStatus.isLoaded ? "配对记录已保存，等待连接验证" : "请先配对这台 iPhone"
    }

    public func startDevicePairing() {
        guard !snapshot.isRunning, !isVerifyingConnection else { return }
        DevicePairingCoordinator.shared.start { [weak self] rawRecord, hostIRK, udid in
            guard let self else { return }
            _ = try self.store.saveOnDevicePairedIdentity(rawRecord, hostIRK: hostIRK, udid: udid)
            self.reloadPairing()
            self.invalidateDeviceConnection()
            self.testConnection(silent: true)
        }
    }

    public func importDiscoveredPairing() {
        guard !snapshot.isRunning, !DevicePairingCoordinator.shared.isRunning else { return }
        if store.importDiscoveredPairingInDocuments() != nil {
            reloadPairing()
            invalidateDeviceConnection()
            events.append(ProtocolEvent(name: "pairing_auto_imported", detail: "{\"event\":\"pairing_auto_imported\"}"))
        }
    }

    public func verifyConnectionIfNeeded() async {
        guard pairingStatus.isLoaded,
              !connectionVerified,
              !isVerifyingConnection,
              !snapshot.isRunning,
              !DevicePairingCoordinator.shared.isRunning else {
            return
        }
        testConnection(silent: true)
    }

    public func testConnection(silent: Bool = false) {
        guard !isVerifyingConnection, !snapshot.isRunning else { return }
        guard let pairing = savedPairing else {
            deviceConnectionStatus = "请先配对这台 iPhone 或导入配对文件"
            return
        }

        let currentHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bonjour mDNS only traverses the local WiFi link. On cellular data the
        // dynamic Remote Pairing port cannot be discovered, so reuse the last
        // port that was successfully found on WiFi before falling back to the
        // configured default.
        let currentRemotePort = store.lastDiscoveredRemotePort ?? remotePort
        let currentLockdownPort = lockdownPort

        isVerifyingConnection = true
        connectionVerified = false
        connectionCheckFailed = false
        deviceConnectionStatus = "正在发现服务并验证配对身份…"

        Task {
            defer { isVerifyingConnection = false }
            do {
                let result = try await AccessoryLocationSession.verifyConnection(
                    host: currentHost,
                    remotePort: currentRemotePort,
                    lockdownPort: currentLockdownPort,
                    pairing: pairing
                )
                guard self.host.trimmingCharacters(in: .whitespacesAndNewlines) == currentHost,
                      self.remotePort == currentRemotePort,
                      self.lockdownPort == currentLockdownPort else {
                    self.invalidateDeviceConnection()
                    return
                }
                if !result.udid.isEmpty {
                    self.deviceUDID = result.udid
                    self.store.deviceUDID = result.udid
                }
                self.discoveredDevicePort = result.port
                self.store.lastDiscoveredRemotePort = result.port
                self.connectionVerified = true
                self.deviceConnectionStatus = "设备身份与回环连接已验证"
                self.events.append(ProtocolEvent(
                    name: "connection_verified",
                    detail: "{\"event\":\"connection_verified\",\"port\":\(result.port),\"service\":\"\(result.carkitService ?? "lockdown")\"}"
                ))
            } catch {
                self.connectionVerified = false
                self.connectionCheckFailed = true
                self.deviceConnectionStatus = error.localizedDescription
                self.events.append(ProtocolEvent(
                    name: "connection_check_failed",
                    detail: "{\"event\":\"connection_check_failed\",\"detail\":\"\(error.localizedDescription)\"}",
                    isError: true
                ))
                if !silent {
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Location Injection Session

    public func start(mode: SessionMode) {
        guard !snapshot.isRunning else { return }
        guard let pairing = savedPairing else {
            alertMessage = "请先在「设备连接」页面完成本机配对或导入配对文件，并确保外部代理已启用 10.7.0.1 回环映射。"
            return
        }

        // Only Remote Pairing records carry the identifier/authTag needed by the
        // system-level simulation engine; Lockdown records do not.
        guard case .remotePairing(let pairingData, _) = pairing else {
            alertMessage = "系统级模拟需要 Remote Pairing 配对记录；请重新配对或导入 RPPairing 文件。"
            return
        }
        if locationMode.requiresMFiCredential && mfiSigner == nil {
            alertMessage = "配件注入模式需要 MFi 凭据，请在「设备连接 → 配件认证」导入，或切换到「系统级模拟」模式。"
            return
        }

        if let pending = pendingLocation {
            targetLocation = pending
            pendingLocation = nil
        }

        recordRecent(name: selectedPlaceName, subtitle: selectedPlaceAddress, location: targetLocation)
        persistRecoveryRecord()
        if microJitterEnabled {
            startJitterTimer()
        }

        keepAlive.start(useSilentAudio: backgroundKeepAliveEnabled)
        coreLocation.requestAndStart()

        switch locationMode {
        case .accessory:
            startAccessorySession(
                mode: mode,
                pairing: pairing,
                pairingData: pairingData
            )
        case .system:
            startSystemSession(pairingData: pairingData)
        }
    }

    /// iAP2 / MFi-v3 / NMEA injection via the external loopback proxy.
    private func startAccessorySession(
        mode: SessionMode,
        pairing: SavedPairing,
        pairingData: Data
    ) {
        guard let mfiSigner else { return }
        let config = SessionConfiguration(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            remotePort: store.lastDiscoveredRemotePort ?? remotePort,
            lockdownPort: lockdownPort,
            serviceName: serviceName.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: mode,
            intervalSeconds: intervalSeconds,
            durationSeconds: mode == .probe ? max(20.0, durationSeconds) : durationSeconds
        )

        let newSession = AccessoryLocationSession(
            initialLocation: targetLocation,
            onEvent: { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    self.events.append(event)
                    if self.events.count > 500 {
                        self.events.removeFirst(self.events.count - 500)
                    }
                }
            },
            onSnapshot: { [weak self] snap in
                Task { @MainActor in
                    guard let self else { return }
                    self.snapshot = snap
                    if !snap.isRunning {
                        self.stopJitterTimer()
                        self.keepAlive.stop()
                        self.coreLocation.stop()
                        self.session = nil
                    }
                }
            },
            onSubscriptionRestarted: { [weak self] in
                Task { @MainActor in
                    self?.keepAlive.refreshAfterLocationToggle()
                }
            }
        )
        self.session = newSession
        newSession.start(
            configuration: config,
            pairing: pairing,
            discoveredRemotePort: discoveredDevicePort,
            mfiSigner: mfiSigner
        )

        if case .send = mode {
            // Opening Settings immediately backgrounds the app during the iAP2/NMEA
            // handshake and can prevent the injection session from taking effect.
            // Only offer the jump after the session is confirmed running.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self, self.snapshot.isRunning else { return }
                self.requestOpenLocationSettings = true
            }
        }
        _ = pairingData
    }

    /// System-level LocationSimulation via the WrapPin native bridge. Needs the
    /// full Bonjour service info (identifier + authTag). On a pure cellular path
    /// iOS does not answer local Bonjour queries, so we replicate WrapPin
    /// Standard's mobile-data workaround: detect cellular, ask the user to switch
    /// mobile data off briefly, and keep re-running discovery until the local
    /// device service resolves again.
    private func startSystemSession(pairingData: Data) {
        pendingSystemPairingData = pairingData
        systemSessionRestartCount = 0
        cellularDiscoveryStatus = "正在检测网络…"
        Task { @MainActor in
            // Let NWPathMonitor deliver its first path update before deciding.
            if self.isWiFiSatisfied == nil {
                try? await Task.sleep(for: .milliseconds(600))
            }
            if self.isWiFiSatisfied == true {
                // WiFi: try one quiet discovery first — no guidance card if it works.
                let service = await RemotePairingDiscovery.discoverService(record: pairingData)
                if let service, !service.identifier.isEmpty, !service.authTag.isEmpty {
                    self.cellularDiscoveryStatus = ""
                    self.cellularGuidance = .none
                    self.launchSystemSession(pairingData: pairingData, service: service)
                    return
                }
            }
            // Cellular, unknown network, or a failed first discovery: whenever
            // the location is not established, the card must ask the user to
            // switch mobile data OFF first, then keep probing in the background
            // (original app behaviour). Once data is off mDNS resolves and we connect.
            self.cellularGuidance = .turnOffData
            self.cellularDiscoveryStatus = "请先关闭这台 iPhone 的蜂窝网络（保持代理 10.7.0.1 隧道连接）；正在检测这台 iPhone…"
            self.startCellularDiscoveryLoop(pairingData: pairingData)
        }
    }

    /// WrapPin-style loop: while the "turn data off" card is up, keep re-running
    /// local Bonjour discovery every few seconds. The card stays visible the
    /// whole time (no intermediate "start" step) — once data is off, mDNSResponder
    /// resolves the on-device service and we establish the session immediately.
    private func startCellularDiscoveryLoop(pairingData: Data, silent: Bool = false) {
        cellularDiscoveryLoopTask?.cancel()
        if !silent {
            cellularGuidance = .turnOffData
        }
        cellularDiscoveryLoopTask = Task { @MainActor in
            // Bound the wait so a stuck device cannot spin forever.
            for attempt in 1...45 {
                guard !Task.isCancelled,
                      self.pendingSystemPairingData != nil,
                      silent || self.cellularGuidance == .turnOffData else { return }
                if !silent {
                    self.cellularDiscoveryStatus = "正在检测这台 iPhone…（第 \(attempt) 次）\n请先关闭蜂窝网络，保持代理 10.7.0.1 隧道连接。"
                }
                let service = await RemotePairingDiscovery.discoverService(record: pairingData)
                guard !Task.isCancelled, silent || self.cellularGuidance == .turnOffData else { return }
                if let service, !service.identifier.isEmpty, !service.authTag.isEmpty {
                    self.cellularDiscoveryLoopTask = nil
                    // Stay on the "turn data off" card until the native session
                    // actually reports running. Switching to "you may restore
                    // data" here would claim success before the session exists.
                    if !silent {
                        self.cellularDiscoveryStatus = "已发现设备，正在建立定位模拟…"
                    }
                    self.launchSystemSession(pairingData: pairingData, service: service)
                    return
                }
                try? await Task.sleep(for: .milliseconds(1200))
            }
            guard !Task.isCancelled else { return }
            if silent {
                // The silent reconnect failed; only now is a card justified.
                self.cellularGuidance = .turnOffData
            }
            // Keep the same card. The location is still not established, so the
            // only message allowed is "turn mobile data off" plus a retry hint —
            // never a second panel that would cover it.
            self.cellularDiscoveryStatus = "多次尝试仍未发现设备。请确认代理隧道已连接、蜂窝数据已关闭，然后点「继续」。"
            self.abortSystemStart()
        }
    }

    /// Build and start the actual WrapPin native location session.
    private func launchSystemSession(pairingData: Data, service: RemotePairingServiceInfo) {
        // Exactly one system session may exist; otherwise a stale session keeps
        // reporting snapshots and the guidance state flips back and forth.
        systemSession?.stop()
        systemSession = nil
        systemSessionWasRunning = false
        systemSessionStopRequested = false
        systemSessionToken &+= 1
        let sessionToken = systemSessionToken
        let newSession = SystemLocationSession(
            initialLocation: self.targetLocation,
            onEvent: { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    self.events.append(event)
                    if self.events.count > 500 {
                        self.events.removeFirst(self.events.count - 500)
                    }
                }
            },
            onSnapshot: { [weak self] snap in
                Task { @MainActor in
                    guard let self else { return }
                    // Ignore anything from a superseded session: after a stop or
                    // a restart the old session's terminal snapshot must not be
                    // able to bring the guidance card back.
                    guard self.systemSessionToken == sessionToken else { return }
                    self.snapshot = snap
                    // A stop the user asked for is not a failure: ignore its
                    // terminal snapshot so no guidance card reappears.
                    guard !self.systemSessionStopRequested else { return }
                    if snap.isRunning {
                        self.systemSessionWasRunning = true
                        // Only now is the location genuinely established, so this
                        // is the only place allowed to ask for mobile data back.
                        if self.cellularGuidance == .turnOffData {
                            self.cellularDiscoveryStatus = ""
                            self.cellularGuidance = .turnBackOnData
                        }
                        return
                    }
                    // A session that already ran, or one that reported an error,
                    // counts as a failure. A silent start-up snapshot does not.
                    let hadError = !(snap.lastError?.isEmpty ?? true)
                    guard self.systemSessionWasRunning || hadError else { return }
                    self.systemSessionWasRunning = false
                    self.stopJitterTimer()
                    self.keepAlive.stop()
                    self.coreLocation.stop()
                    self.systemSession = nil
                    // The card must never branch into a second message: as long as
                    // the location is not established the only card is
                    // "turn mobile data off". So fall back to that state and
                    // resume discovery instead of showing a separate
                    // "session interrupted" panel on top of it.
                    if let data = self.pendingSystemPairingData, self.systemSessionRestartCount < 2 {
                        self.systemSessionRestartCount += 1
                        // It had already worked once: reconnect quietly instead of
                        // shoving a "turn data off" card at the user.
                        self.cellularGuidance = .none
                        self.cellularDiscoveryStatus = ""
                        self.startCellularDiscoveryLoop(pairingData: data, silent: true)
                    } else {
                        self.cellularGuidance = .turnOffData
                        self.cellularDiscoveryStatus = "定位模拟多次中断。请确认代理隧道与配对记录后，点「继续」重试。"
                    }
                }
            }
        )
        self.systemSession = newSession
        newSession.start(
            pairingData: pairingData,
            service: service,
            initialLocation: self.targetLocation
        )
    }

    private func abortSystemStart() {
        stopJitterTimer()
        keepAlive.stop()
        coreLocation.stop()
    }

    // MARK: - Cellular guidance user actions

    /// Original app's "Continue" fallback: the loop is already probing in the
    /// background, but tapping this issues an immediate fresh pass.
    public func confirmCellularStart() {
        guard cellularGuidance == .turnOffData, let data = pendingSystemPairingData else { return }
        startCellularDiscoveryLoop(pairingData: data)
    }

    /// Retry from the connection-help state — go back to the turn-off card so
    /// the whole turn-off -> auto-discover -> restore sequence is repeated.
    public func retryCellularConnection() {
        cellularGuidance = .none
        guard let data = pendingSystemPairingData else { return }
        let onCellular = isWiFiSatisfied == false
        if onCellular {
            cellularGuidance = .turnOffData
            cellularDiscoveryStatus = "请先关闭这台 iPhone 的蜂窝网络（保持代理 10.7.0.1 隧道连接）；正在检测这台 iPhone…"
            startCellularDiscoveryLoop(pairingData: data)
        } else {
            Task { @MainActor in
                let service = await RemotePairingDiscovery.discoverService(record: data)
                guard let service, !service.identifier.isEmpty, !service.authTag.isEmpty else {
                    self.cellularGuidance = .turnOffData
                    self.cellularDiscoveryStatus = "未发现本机配对服务。请确认代理隧道已连接 10.7.0.1 回环，然后点「继续」。"
                    self.abortSystemStart()
                    return
                }
                self.cellularGuidance = .none
                self.launchSystemSession(pairingData: data, service: service)
            }
        }
    }

    /// Dismiss the guidance card (e.g. after the user restores mobile data).
    public func dismissCellularGuidance() {
        cellularGuidance = .none
        cellularDiscoveryStatus = ""
    }

    /// Called when the app returns to the foreground. The original app restarts
    /// its discovery loop here, so switching data off in Control Center and
    /// coming back connects without any extra tap.
    public func appDidBecomeActive() {
        guard cellularGuidance == .turnOffData, let data = pendingSystemPairingData else { return }
        startCellularDiscoveryLoop(pairingData: data)
    }

    public func stopAndRestore() {
        stopJitterTimer()
        cellularDiscoveryLoopTask?.cancel()
        cellularDiscoveryLoopTask = nil
        pendingSystemPairingData = nil
        // Mark intent before stopping: the session emits a terminal snapshot and
        // it must not be mistaken for a dropped connection.
        systemSessionStopRequested = true
        systemSessionWasRunning = false
        systemSessionRestartCount = 0
        // Invalidate every callback bound to the session we are stopping.
        systemSessionToken &+= 1
        cellularGuidance = .none
        cellularDiscoveryStatus = ""
        session?.stop()
        systemSession?.stop()
        systemSession = nil
        keepAlive.stop()
        coreLocation.stop()
        store.saveInterruptedSession(nil)
        interruptedSession = nil

        // Accessory injection persists in the system location stack until the
        // Location Services master switch is cycled, so guide the user there.
        // System-level simulation is cleared by the FFI on stop; no jump needed.
        if locationMode.requiresMFiCredential {
            requestOpenLocationSettings = true
        }
    }

    // MARK: - Pairing & Places Management

    public func reloadPairing() {
        let (pairing, pairStat) = store.loadPairing()
        self.savedPairing = pairing
        self.pairingStatus = pairStat
        self.deviceUDID = store.deviceUDID
    }

    public func importPairingFile(url: URL) {
        do {
            _ = try store.importPairingFile(from: url)
            reloadPairing()
            invalidateDeviceConnection()
            events.append(ProtocolEvent(name: "pairing_imported", detail: "{\"event\":\"pairing_imported\"}"))
            testConnection(silent: true)
        } catch {
            alertMessage = "配对文件导入失败：\(error.localizedDescription)"
        }
    }

    public func removePairingFile() {
        store.removePairingFile()
        store.lastDiscoveredRemotePort = nil
        reloadPairing()
        invalidateDeviceConnection()
    }

    /// Imports an XML plist pairing file pasted from the clipboard.
    public func importPairingText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alertMessage = "剪贴板中没有可导入的文本。"
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            alertMessage = "剪贴板内容无法转换为文本。"
            return
        }
        do {
            _ = try store.importPairingData(data)
            reloadPairing()
            invalidateDeviceConnection()
            events.append(ProtocolEvent(
                name: "pairing_imported_from_clipboard",
                detail: "{\"event\":\"pairing_imported_from_clipboard\"}"
            ))
            alertMessage = "配对文件已从剪贴板导入。"
            testConnection(silent: true)
        } catch {
            alertMessage = "剪贴板配对内容导入失败：\(error.localizedDescription)"
        }
    }

    public func toggleFavoriteForInspected() {
        let loc = inspectedLocation
        if let idx = favorites.firstIndex(where: { abs($0.latitude - loc.latitude) < 1e-4 && abs($0.longitude - loc.longitude) < 1e-4 }) {
            favorites.remove(at: idx)
        } else {
            favorites.insert(
                FavoriteLocation(
                    name: selectedPlaceName,
                    subtitle: selectedPlaceAddress,
                    latitude: loc.latitude,
                    longitude: loc.longitude,
                    altitude: loc.altitude
                ),
                at: 0
            )
        }
        store.saveFavorites(favorites)
    }

    public func saveCurrentAsFavorite(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let loc = inspectedLocation
        favorites.insert(
            FavoriteLocation(
                name: trimmed,
                subtitle: selectedPlaceAddress,
                latitude: loc.latitude,
                longitude: loc.longitude,
                altitude: loc.altitude
            ),
            at: 0
        )
        store.saveFavorites(favorites)
    }

    public func renameFavorite(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = favorites.firstIndex(where: { $0.id == id }) else { return }
        favorites[idx].name = trimmed
        store.saveFavorites(favorites)
    }

    public func deleteFavorite(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        store.saveFavorites(favorites)
    }

    public func deleteFavorite(id: UUID) {
        favorites.removeAll { $0.id == id }
        store.saveFavorites(favorites)
    }

    public func recordRecent(name: String, subtitle: String?, location: TargetLocation) {
        recents.removeAll {
            abs($0.latitude - location.latitude) < 1e-4 && abs($0.longitude - location.longitude) < 1e-4
        }
        recents.insert(
            RecentLocation(
                name: name.isEmpty ? String(format: "%.5f, %.5f", location.latitude, location.longitude) : name,
                subtitle: subtitle,
                latitude: location.latitude,
                longitude: location.longitude,
                altitude: location.altitude
            ),
            at: 0
        )
        if recents.count > 30 {
            recents = Array(recents.prefix(30))
        }
        store.saveRecents(recents)
    }

    public func deleteRecent(id: UUID) {
        recents.removeAll { $0.id == id }
        store.saveRecents(recents)
    }

    public func clearRecents() {
        recents.removeAll()
        store.saveRecents([])
    }

    public func clearLogs() {
        events.removeAll()
    }

    public func exportedLogsText() -> String {
        let formatter = ISO8601DateFormatter()
        return events.map { "[\(formatter.string(from: $0.timestamp))] \($0.detail)" }.joined(separator: "\n")
    }
}
