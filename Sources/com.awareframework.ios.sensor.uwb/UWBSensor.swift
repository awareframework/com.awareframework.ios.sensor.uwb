//
//  UWBSensor.swift
//  com.awareframework.ios.sensor.uwb
//
//  Created by Yuuki Nishiyama on 2026/06/02.
//
//  Measures distance (and direction) between this iPhone and nearby UWB-capable
//  Apple devices using the NearbyInteraction framework.
//
//  Supported peer types
//  ─────────────────────
//  • iPhone (11 or later, U1/UWB chip) – token exchange via MultipeerConnectivity
//  • Apple Watch (Series 6 / Ultra or later) – token exchange via WatchConnectivity
//
//  Required capabilities in the host app's Info.plist
//  ───────────────────────────────────────────────────
//  NSNearbyInteractionUsageDescription
//  NSLocalNetworkUsageDescription          (MultipeerConnectivity)
//  NSBonjourServices  _aware-uwb._tcp  _aware-uwb._udp
//
//  For Apple Watch pairing the Watch app must also implement the WCSession
//  counterpart and exchange NIDiscoveryToken via WatchConnectivity messages.

#if os(iOS)

import Foundation
import NearbyInteraction
import MultipeerConnectivity
import WatchConnectivity
import com_awareframework_ios_core
import GRDB

// MARK: - Notification names

extension Notification.Name {
    public static let actionAwareUWB               = Notification.Name(UWBSensor.ACTION_AWARE_UWB)
    public static let actionAwareUWBStart          = Notification.Name(UWBSensor.ACTION_AWARE_UWB_START)
    public static let actionAwareUWBStop           = Notification.Name(UWBSensor.ACTION_AWARE_UWB_STOP)
    public static let actionAwareUWBSync           = Notification.Name(UWBSensor.ACTION_AWARE_UWB_SYNC)
    public static let actionAwareUWBSetLabel       = Notification.Name(UWBSensor.ACTION_AWARE_UWB_SET_LABEL)
    public static let actionAwareUWBSyncCompletion = Notification.Name(UWBSensor.ACTION_AWARE_UWB_SYNC_COMPLETION)
}

// MARK: - Observer protocol

public protocol UWBObserver {
    /// Called whenever a new ranging measurement arrives for any peer.
    func onDataChanged(data: UWBData)
    /// Called when a new peer is discovered and a ranging session is starting.
    func onPeerDiscovered(peerIdentifier: String, deviceType: String)
    /// Called when a peer's ranging session ends or the peer disconnects.
    func onPeerLost(peerIdentifier: String)
}

// MARK: - UWBSensor

public class UWBSensor: AwareSensor {

    // MARK: Action strings

    public static let ACTION_AWARE_UWB               = "com.awareframework.ios.sensor.uwb"
    public static let ACTION_AWARE_UWB_START         = "com.awareframework.ios.sensor.uwb.start"
    public static let ACTION_AWARE_UWB_STOP          = "com.awareframework.ios.sensor.uwb.stop"
    public static let ACTION_AWARE_UWB_SYNC          = "com.awareframework.ios.sensor.uwb.sync"
    public static let ACTION_AWARE_UWB_SET_LABEL     = "com.awareframework.ios.sensor.uwb.set_label"
    public static let ACTION_AWARE_UWB_SYNC_COMPLETION = "com.awareframework.ios.sensor.uwb.sync_completion"
    public static let EXTRA_STATUS = "status"
    public static let EXTRA_ERROR  = "error"
    public static let EXTRA_LABEL  = "label"
    public static let TAG          = "com.awareframework.ios.sensor.uwb"

    // MARK: Config

    public var CONFIG = UWBSensor.Config()

    public class Config: SensorConfig {
        public var sensorObserver: UWBObserver?
        /// Enable iPhone ↔ iPhone ranging via MultipeerConnectivity.
        public var enableiPhoneRanging: Bool = true
        /// Enable iPhone ↔ Apple Watch ranging via WatchConnectivity.
        public var enableAppleWatchRanging: Bool = true

        public override init() {
            super.init()
            dbPath      = "aware_uwb"
            dbTableName = "uwb"
        }

        public override func set(config: Dictionary<String, Any>) {
            super.set(config: config)
            if let v = config["enableiPhoneRanging"]     as? Bool { enableiPhoneRanging     = v }
            if let v = config["enableAppleWatchRanging"] as? Bool { enableAppleWatchRanging = v }
        }

        public func apply(closure: (_ config: UWBSensor.Config) -> Void) -> Self {
            closure(self)
            return self
        }
    }

    // MARK: Private state

    /// Serial queue that serialises all access to niSessions / pendingPeerTokens.
    private let sessionQueue = DispatchQueue(label: "com.awareframework.ios.sensor.uwb.sessionQueue")

    /// peerIdentifier → active NISession.
    private var niSessions: [String: NISession] = [:]

    /// peerIdentifier → peer's NIDiscoveryToken received before our session was ready.
    private var pendingPeerTokens: [String: NIDiscoveryToken] = [:]

    // MultipeerConnectivity (iPhone ↔ iPhone)
    private let mcServiceType = "aware-uwb"
    private var mcSession:    MCSession?
    private var mcAdvertiser: MCNearbyServiceAdvertiser?
    private var mcBrowser:    MCNearbyServiceBrowser?
    private lazy var localPeerID = MCPeerID(displayName: AwareUtils.getCommonDeviceId())

    // WatchConnectivity (iPhone ↔ Apple Watch)
    private var wcActivated = false

    // MARK: Init

    public init(_ config: UWBSensor.Config) {
        super.init()
        CONFIG = config
        initializeDbEngine(config: config)
        initializeTable()
    }

    public override convenience init() {
        self.init(UWBSensor.Config())
    }

    // MARK: AwareSensor lifecycle

    public override func start() {
        guard NISession.isSupported else {
            if CONFIG.debug { print(UWBSensor.TAG, "NearbyInteraction not supported on this device") }
            return
        }

        if CONFIG.enableiPhoneRanging  { startMultipeerConnectivity() }
        if CONFIG.enableAppleWatchRanging { startWatchConnectivity()  }

        notificationCenter.post(name: .actionAwareUWBStart, object: self)
        if CONFIG.debug { print(UWBSensor.TAG, "UWB sensor started") }
    }

    public override func stop() {
        stopMultipeerConnectivity()

        sessionQueue.sync {
            niSessions.values.forEach { $0.invalidate() }
            niSessions.removeAll()
            pendingPeerTokens.removeAll()
        }

        notificationCenter.post(name: .actionAwareUWBStop, object: self)
        if CONFIG.debug { print(UWBSensor.TAG, "UWB sensor stopped") }
    }

    public override func sync(force: Bool = false) {
        notificationCenter.post(name: .actionAwareUWBSync, object: self)
        if let engine = dbEngine, let syncConfig = super.syncConfig {
            engine.startSync(syncConfig)
        }
    }

    public override func set(label: String) {
        CONFIG.label = label
        notificationCenter.post(name: .actionAwareUWBSetLabel, object: self,
                                userInfo: [UWBSensor.EXTRA_LABEL: label])
    }

    // MARK: - MultipeerConnectivity (iPhone ↔ iPhone)

    private func startMultipeerConnectivity() {
        mcSession = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        mcSession?.delegate = self

        mcAdvertiser = MCNearbyServiceAdvertiser(peer: localPeerID, discoveryInfo: nil,
                                                  serviceType: mcServiceType)
        mcAdvertiser?.delegate = self
        mcAdvertiser?.startAdvertisingPeer()

        mcBrowser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: mcServiceType)
        mcBrowser?.delegate = self
        mcBrowser?.startBrowsingForPeers()

        if CONFIG.debug { print(UWBSensor.TAG, "MultipeerConnectivity started") }
    }

    private func stopMultipeerConnectivity() {
        mcAdvertiser?.stopAdvertisingPeer()
        mcBrowser?.stopBrowsingForPeers()
        mcSession?.disconnect()
        mcAdvertiser = nil
        mcBrowser    = nil
        mcSession    = nil
    }

    /// Creates an NISession for `peerIdentifier`, gets our discovery token, and
    /// sends it to `mcPeer` so the peer can start its own session.
    private func setupNISession(for peerIdentifier: String, mcPeer: MCPeerID) {
        sessionQueue.async { [weak self] in
            guard let self, NISession.isSupported else { return }

            let niSession = NISession()
            niSession.delegate = self
            self.niSessions[peerIdentifier] = niSession

            guard let myToken = niSession.discoveryToken else { return }

            if let pending = self.pendingPeerTokens.removeValue(forKey: peerIdentifier) {
                // We already have the peer's token – start ranging immediately.
                let config = NINearbyPeerConfiguration(peerToken: pending)
                niSession.run(config)
                if self.CONFIG.debug {
                    print(UWBSensor.TAG, "NISession started (pending token) for iPhone: \(peerIdentifier)")
                }
            }

            // Send our token back to the MC peer regardless.
            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: myToken,
                                                             requiringSecureCoding: true)
                try self.mcSession?.send(data, toPeers: [mcPeer], with: .reliable)
            } catch {
                if self.CONFIG.debug { print(UWBSensor.TAG, "MC token send failed: \(error)") }
            }
        }
    }

    // MARK: - WatchConnectivity (iPhone ↔ Apple Watch)

    private func startWatchConnectivity() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Sends our NIDiscoveryToken to the Apple Watch via WatchConnectivity message.
    private func sendTokenToWatch() {
        guard wcActivated,
              WCSession.default.isWatchAppInstalled else { return }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            let peerKey = "apple_watch"
            let niSession = self.niSessions[peerKey] ?? {
                let s = NISession()
                s.delegate = self
                self.niSessions[peerKey] = s
                return s
            }()

            guard let myToken = niSession.discoveryToken else { return }

            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: myToken,
                                                             requiringSecureCoding: true)
                WCSession.default.sendMessage(["uwbToken": data], replyHandler: nil) { error in
                    if self.CONFIG.debug { print(UWBSensor.TAG, "WC sendMessage failed: \(error)") }
                }
            } catch {
                if CONFIG.debug { print(UWBSensor.TAG, "WC token archive failed: \(error)") }
            }
        }
    }

    // MARK: - NISession helpers

    private func handleReceivedPeerToken(_ peerToken: NIDiscoveryToken,
                                         peerIdentifier: String,
                                         deviceType: String) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if let session = self.niSessions[peerIdentifier] {
                // Session already exists; configure it with the peer's token.
                let config = NINearbyPeerConfiguration(peerToken: peerToken)
                session.run(config)
                if self.CONFIG.debug {
                    print(UWBSensor.TAG, "NISession configured for \(deviceType): \(peerIdentifier)")
                }
            } else {
                // Session not yet created; store the token until setupNISession is called.
                self.pendingPeerTokens[peerIdentifier] = peerToken
            }

            DispatchQueue.main.async {
                self.CONFIG.sensorObserver?.onPeerDiscovered(peerIdentifier: peerIdentifier,
                                                             deviceType: deviceType)
            }
        }
    }

    // MARK: - DB helpers

    private func saveData(_ data: UWBData) {
        dbEngine?.save([data]) { [weak self] error in
            guard let self else { return }
            if let error = error {
                if self.CONFIG.debug { print(UWBSensor.TAG, "DB save failed: \(error)") }
                return
            }
            DispatchQueue.main.async {
                self.notificationCenter.post(name: .actionAwareUWB, object: self)
            }
        }
    }

    private func initializeTable() {
        guard let sqliteEngine = dbEngine as? SQLiteEngine,
              let queue = sqliteEngine.getSQLiteInstance() else { return }
        try? UWBData.createTable(queue: queue)
    }
}

// MARK: - NISessionDelegate

extension UWBSensor: NISessionDelegate {

    public func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        let peerIdentifier: String = sessionQueue.sync {
            niSessions.first(where: { $0.value === session })?.key ?? "unknown"
        }
        let deviceType = deviceType(for: peerIdentifier)

        for object in nearbyObjects {
            var data = UWBData()
            data.timestamp      = Int64(Date().timeIntervalSince1970 * 1000)
            data.label          = CONFIG.label
            data.peerIdentifier = peerIdentifier
            data.peerDeviceType = deviceType

            if let d = object.distance  { data.distance  = Double(d) }
            if let dir = object.direction {
                data.directionX = Double(dir.x)
                data.directionY = Double(dir.y)
                data.directionZ = Double(dir.z)
            }
            if let h = object.horizontalAngle { data.horizontalAngle = Double(h) }

            saveData(data)
            CONFIG.sensorObserver?.onDataChanged(data: data)
        }
    }

    public func session(_ session: NISession,
                        didRemove nearbyObjects: [NINearbyObject],
                        with reason: NINearbyObject.RemovalReason) {
        let peerIdentifier: String = sessionQueue.sync {
            niSessions.first(where: { $0.value === session })?.key ?? "unknown"
        }
        sessionQueue.async { [weak self] in
            self?.niSessions.removeValue(forKey: peerIdentifier)
        }
        CONFIG.sensorObserver?.onPeerLost(peerIdentifier: peerIdentifier)
        if CONFIG.debug { print(UWBSensor.TAG, "Peer removed: \(peerIdentifier) reason: \(reason)") }
    }

    public func session(_ session: NISession, didInvalidateWith error: Error) {
        let peerIdentifier: String = sessionQueue.sync {
            niSessions.first(where: { $0.value === session })?.key ?? "unknown"
        }
        sessionQueue.async { [weak self] in
            self?.niSessions.removeValue(forKey: peerIdentifier)
        }
        if CONFIG.debug { print(UWBSensor.TAG, "Session invalidated for \(peerIdentifier): \(error)") }
    }

    private func deviceType(for peerIdentifier: String) -> String {
        if peerIdentifier == "apple_watch" { return "AppleWatch" }
        if peerIdentifier.hasPrefix("acc-") { return "Accessory"  }
        return "iPhone"
    }
}

// MARK: - MCSessionDelegate

extension UWBSensor: MCSessionDelegate {

    public func session(_ session: MCSession,
                        peer peerID: MCPeerID,
                        didChange state: MCSessionState) {
        switch state {
        case .connected:
            if CONFIG.debug { print(UWBSensor.TAG, "MC peer connected: \(peerID.displayName)") }
            setupNISession(for: peerID.displayName, mcPeer: peerID)
        case .notConnected:
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if let s = self.niSessions.removeValue(forKey: peerID.displayName) { s.invalidate() }
            }
            CONFIG.sensorObserver?.onPeerLost(peerIdentifier: peerID.displayName)
        default:
            break
        }
    }

    public func session(_ session: MCSession,
                        didReceive data: Data,
                        fromPeer peerID: MCPeerID) {
        guard let peerToken = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NIDiscoveryToken.self, from: data) else { return }
        handleReceivedPeerToken(peerToken, peerIdentifier: peerID.displayName, deviceType: "iPhone")
    }

    // Unused MCSessionDelegate requirements
    public func session(_ session: MCSession, didReceive stream: InputStream,
                        withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession,
                        didStartReceivingResourceWithName resourceName: String,
                        fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession,
                        didFinishReceivingResourceWithName resourceName: String,
                        fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension UWBSensor: MCNearbyServiceAdvertiserDelegate {

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                           didReceiveInvitationFromPeer peerID: MCPeerID,
                           withContext context: Data?,
                           invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, mcSession)
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                           didNotStartAdvertisingPeer error: Error) {
        if CONFIG.debug { print(UWBSensor.TAG, "MC advertiser failed: \(error)") }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension UWBSensor: MCNearbyServiceBrowserDelegate {

    public func browser(_ browser: MCNearbyServiceBrowser,
                        foundPeer peerID: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        guard let session = mcSession else { return }
        // Only the lexicographically smaller ID initiates to avoid duplicate connections.
        if localPeerID.displayName < peerID.displayName {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        if CONFIG.debug { print(UWBSensor.TAG, "MC peer lost: \(peerID.displayName)") }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        if CONFIG.debug { print(UWBSensor.TAG, "MC browser failed: \(error)") }
    }
}

// MARK: - WCSessionDelegate

extension UWBSensor: WCSessionDelegate {

    public func session(_ session: WCSession,
                        activationDidCompleteWith activationState: WCSessionActivationState,
                        error: Error?) {
        guard activationState == .activated else { return }
        wcActivated = true
        sendTokenToWatch()
    }

    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        wcActivated = false
        session.activate()
    }

    /// Handles the Watch's discovery token delivered as a real-time message.
    public func session(_ session: WCSession,
                        didReceiveMessage message: [String: Any]) {
        handleWatchToken(from: message)
    }

    /// Handles the Watch's discovery token delivered via application context.
    public func session(_ session: WCSession,
                        didReceiveApplicationContext applicationContext: [String: Any]) {
        handleWatchToken(from: applicationContext)
    }

    private func handleWatchToken(from dict: [String: Any]) {
        guard let tokenData = dict["uwbToken"] as? Data,
              let peerToken = try? NSKeyedUnarchiver.unarchivedObject(
                    ofClass: NIDiscoveryToken.self, from: tokenData) else { return }
        handleReceivedPeerToken(peerToken, peerIdentifier: "apple_watch", deviceType: "AppleWatch")
    }
}

#endif
