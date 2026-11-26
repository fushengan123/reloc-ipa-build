import Foundation
// WrappinPairingFFI C functions are exposed via Reloc-Bridging-Header.h
// (wrappin_pairing.h). No Swift module import: the xcframework has no modulemap
// to avoid colliding with RelocDeviceBridge's modulemap at build time.

/// System-level location simulation session.
///
/// Unlike `AccessoryLocationSession` (iAP2 / MFi-v3 / NMEA injection over an
/// external loopback proxy), this session drives the iPhone's own
/// `com.apple.instruments.server.services.LocationSimulation` service through
/// the WrapPin native bridge: Bonjour-discovered Remote Pairing -> TLS-PSK
/// device tunnel -> RSD -> DVT -> LocationSimulation. No MFi credential and no
/// accessory handshake is involved, so it is unaffected by iAP2 handshake
/// interruptions; it does still require the device loopback (10.7.0.1) route.
public final class SystemLocationSession {
    public typealias EventCallback = @Sendable (ProtocolEvent) -> Void
    public typealias SnapshotCallback = @Sendable (SessionSnapshot) -> Void

    private let queue = DispatchQueue(label: "com.reloc.system-session", qos: .userInitiated)
    private let stateLock = NSLock()
    private var cancelled = false
    private var session: OpaquePointer?
    private var updateTimer: Timer?
    private var lastPushedLatitude = Double.nan
    private var lastPushedLongitude = Double.nan

    public let locationBox: LiveLocationBox
    private let onEvent: EventCallback
    private let onSnapshot: SnapshotCallback

    public init(
        initialLocation: TargetLocation,
        onEvent: @escaping EventCallback,
        onSnapshot: @escaping SnapshotCallback
    ) {
        self.locationBox = LiveLocationBox(initialLocation)
        self.onEvent = onEvent
        self.onSnapshot = onSnapshot
    }

    deinit {
        stop()
    }

    /// Start driving the system LocationSimulation service.
    ///
    /// - Parameters:
    ///   - pairingData: the Remote Pairing record bytes (`device.pairing.plist`).
    ///   - service: the Bonjour-validated Remote Pairing service info (port,
    ///     identifier, auth tag) discovered for the paired device.
    func start(
        pairingData: Data,
        service: RemotePairingServiceInfo,
        initialLocation: TargetLocation
    ) {
        stateLock.lock()
        if session != nil || cancelled {
            stateLock.unlock()
            return
        }
        cancelled = false
        guard let newSession = wp_location_session_create() else {
            stateLock.unlock()
            emitError("系统定位会话初始化失败")
            return
        }
        session = newSession
        stateLock.unlock()

        lastPushedLatitude = initialLocation.latitude
        lastPushedLongitude = initialLocation.longitude

        let context = Unmanaged.passUnretained(self).toOpaque()
        let sessionBits = UInt(bitPattern: newSession)

        queue.async { [weak self] in
            guard let self else { return }
            self.emitSystem("system_session_starting", detail: "{\"mode\":\"system\",\"stage\":\"starting\"}")

            var result = WPLocationResult()
            let recordBytes = pairingData
            let returnCode: Int32 = recordBytes.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                return service.host.withCString { peer in
                    service.identifier.withCString { sid in
                        service.authTag.withCString { tag in
                            guard let ptr = OpaquePointer(bitPattern: sessionBits) else { return -1 }
                            return wp_location_session_run(
                                ptr,
                                base,
                                recordBytes.count,
                                peer,
                                service.port,
                                sid,
                                tag,
                                initialLocation.latitude,
                                initialLocation.longitude,
                                systemLocationStartedCallback,
                                context,
                                &result
                            )
                        }
                    }
                }
            }

            let outcome = SystemLocationOutcome(result: result, returnCode: returnCode)
            wp_location_result_destroy(&result)

            // A user-initiated stop surfaces as stage 15 (WPLocationStageCancelled).
            // Treat it as a normal end, not an error.
            let wasCancelled = outcome.stage == 15 || self.wasCancelledFlag()
            if (outcome.returnCode != 0 || outcome.failed) && !wasCancelled {
                self.emitSystemError(outcome.message)
            }
            self.finishSession()
        }
    }

    /// Push a new coordinate to the running simulation. Safe to call at any time;
    /// it is a no-op when no session is active.
    public func updateLocation(_ location: TargetLocation) {
        stateLock.lock()
        let activeSession = cancelled ? nil : session
        stateLock.unlock()
        guard let activeSession else { return }
        // The FFI update itself is thread-safe (guarded by a Rust mutex).
        _ = wp_location_session_update(
            activeSession,
            location.latitude,
            location.longitude
        )
    }

    /// Start a small timer that mirrors `locationBox` into the FFI so that map
    /// updates and micro-jitter work the same way as in accessory mode.
    public func startLocationMirror() {
        stopLocationMirror()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let loc = self.locationBox.get()
            if loc.latitude != self.lastPushedLatitude || loc.longitude != self.lastPushedLongitude {
                self.lastPushedLatitude = loc.latitude
                self.lastPushedLongitude = loc.longitude
                self.updateLocation(loc)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    public func stop() {
        stateLock.lock()
        let activeSession = session
        stateLock.unlock()
        guard let activeSession else { return }
        cancelled = true
        stopLocationMirror()
        wp_location_session_cancel(activeSession)
    }

    // MARK: - Internals

    private func stopLocationMirror() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func wasCancelledFlag() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    private func finishSession() {
        stateLock.lock()
        let activeSession = session
        session = nil
        stateLock.unlock()
        if let activeSession {
            wp_location_session_destroy(activeSession)
        }
        stopLocationMirror()
        var snapshot = SessionSnapshot()
        snapshot.isRunning = false
        snapshot.mode = .send
        onSnapshot(snapshot)
    }

    private func emitSystem(_ name: String, detail: String) {
        let event = ProtocolEvent(name: name, detail: detail)
        onEvent(event)
    }

    private func emitError(_ message: String) {
        var snapshot = SessionSnapshot()
        snapshot.isRunning = false
        snapshot.mode = .send
        snapshot.lastError = message
        onSnapshot(snapshot)
        emitSystem("system_session_error", detail: "{\"mode\":\"system\",\"error\":\"\(message)\"}")
    }

    private func emitSystemError(_ message: String) {
        var snapshot = SessionSnapshot()
        snapshot.isRunning = false
        snapshot.mode = .send
        snapshot.lastError = message
        onSnapshot(snapshot)
        emitSystem("system_session_failed", detail: "{\"mode\":\"system\",\"error\":\"\(message)\"}")
    }

    fileprivate func handleStarted() {
        var snapshot = SessionSnapshot()
        snapshot.isRunning = true
        snapshot.mode = .send
        snapshot.authenticated = true
        onSnapshot(snapshot)
        emitSystem("system_location_active", detail: "{\"mode\":\"system\",\"stage\":\"active\"}")
        startLocationMirror()
    }
}

/// Swift-side decode of the FFI result struct.
private struct SystemLocationOutcome {
    let returnCode: Int32
    let failed: Bool
    let message: String
    let stage: Int32
    let recoverable: Bool

    init(result: WPLocationResult, returnCode: Int32) {
        self.returnCode = returnCode
        self.stage = result.error_stage
        self.recoverable = result.error_is_recoverable != 0
        if let ptr = result.error_message {
            self.message = String(cString: ptr)
        } else {
            self.message = returnCode == 0 ? "" : "系统定位会话失败（代码 \(returnCode)）"
        }
        self.failed = !message.isEmpty
    }
}

/// C callback trampoline: the opaque context carries an unretained reference
/// to the `SystemLocationSession`, matching the pattern used by WrapPin.
private let systemLocationStartedCallback: WPLocationStartedCallback = { context in
    guard let context else { return }
    let bits = UInt(bitPattern: context)
    DispatchQueue.main.async {
        guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        let session = Unmanaged<SystemLocationSession>.fromOpaque(raw).takeUnretainedValue()
        session.handleStarted()
    }
}
