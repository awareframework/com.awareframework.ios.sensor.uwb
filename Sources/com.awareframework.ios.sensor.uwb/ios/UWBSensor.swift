//
//  UWBSensor.swift
//  com.awareframework.ios.sensor.uwb  (iOS target)
//
//  iPhone と周辺の UWB 対応 Apple デバイス間の距離・方向を計測する。
//
//  対応ピア
//  ─────────────────────────────────────────
//  • iPhone 11以降  (U1チップ) ── MultipeerConnectivity でトークン交換
//  • Apple Watch Series 6以降  ── WatchConnectivity でトークン交換
//
//  Info.plist に必要なキー
//  ─────────────────────────────────────────
//  NSNearbyInteractionUsageDescription
//  NSLocalNetworkUsageDescription
//  NSBonjourServices: _aware-uwb._tcp  _aware-uwb._udp

#if os(iOS)

import Foundation
import NearbyInteraction
import MultipeerConnectivity
import WatchConnectivity
import com_awareframework_ios_core
import com_awareframework_ios_sensor_uwb_shared
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
    func onDataChanged(data: UWBData)
    func onPeerDiscovered(peerIdentifier: String, deviceType: String)
    func onPeerLost(peerIdentifier: String)
}

// MARK: - UWBSensor

public class UWBSensor: AwareSensor {

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

    public var CONFIG = UWBSensor.Config()

    public class Config: SensorConfig {
        public var sensorObserver: UWBObserver?
        public var enableiPhoneRanging: Bool = true
        public var enableAppleWatchRanging: Bool = true

        public override init() {
            super.init()
            dbPath      = "aware_uwb"
            dbTableName = UWBData.databaseTableName
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

    private let sessionQueue = DispatchQueue(label: "com.awareframework.ios.sensor.uwb.sessionQueue")
    private var niSessions: [String: NISession] = [:]
    private var pendingPeerTokens: [String: NIDiscoveryToken] = [:]

    private let mcServiceType = "aware-uwb"
    private var mcSession:    MCSession?
    private var mcAdvertiser: MCNearbyServiceAdvertiser?
    private var mcBrowser:    MCNearbyServiceBrowser?
    private lazy var localPeerID = MCPeerID(displayName: AwareUtils.getCommonDeviceId())

    private var wcActivated = false
    private var lastReceivedWatchTokenData: Data?

    // MARK: Init

    public init(_ config: UWBSensor.Config) {
        super.init()
        CONFIG = config
        configureSyncConfig()
        initializeDbEngine(config: config)
        initializeTable()
    }

    public override convenience init() {
        self.init(UWBSensor.Config())
    }

    private func configureSyncConfig() {
        super.syncConfig = DbSyncConfig().apply { syncConfig in
            syncConfig.serverType = CONFIG.serverType
            syncConfig.debug = CONFIG.debug
            syncConfig.batchSize = 1000
            syncConfig.dispatchQueue = DispatchQueue(label: "com.awareframework.ios.sensor.uwb.sync.queue")
            syncConfig.completionHandler = { [weak self] status, error in
                guard let self else { return }
                var userInfo: [String: Any] = [UWBSensor.EXTRA_STATUS: status]
                if let error {
                    userInfo[UWBSensor.EXTRA_ERROR] = error
                }
                self.notificationCenter.post(name: .actionAwareUWBSyncCompletion, object: self, userInfo: userInfo)
            }
        }
    }

    // MARK: AwareSensor lifecycle

    public override func start() {
        guard NISession.isSupported else {
            if CONFIG.debug { print(UWBSensor.TAG, "NearbyInteraction not supported") }
            return
        }
        if CONFIG.enableiPhoneRanging     { startMultipeerConnectivity() }
        if CONFIG.enableAppleWatchRanging { startWatchConnectivity()     }

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
        guard let engine = dbEngine else {
            postSyncFailure("UWB database engine is not initialized.")
            return
        }
        guard let syncConfig = super.syncConfig else {
            postSyncFailure("UWB sync configuration is not initialized.")
            return
        }
        engine.startSync(syncConfig)
    }

    private func postSyncFailure(_ message: String) {
        let error = NSError(
            domain: UWBSensor.TAG,
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        notificationCenter.post(
            name: .actionAwareUWBSyncCompletion,
            object: self,
            userInfo: [
                UWBSensor.EXTRA_STATUS: false,
                UWBSensor.EXTRA_ERROR: error,
            ]
        )
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

    private func setupNISession(for peerIdentifier: String, mcPeer: MCPeerID) {
        sessionQueue.async { [weak self] in
            guard let self, NISession.isSupported else { return }
            let niSession = NISession()
            niSession.delegate = self
            self.niSessions[peerIdentifier] = niSession
            guard let myToken = niSession.discoveryToken else { return }
            if let pending = self.pendingPeerTokens.removeValue(forKey: peerIdentifier) {
                niSession.run(NINearbyPeerConfiguration(peerToken: pending))
                if self.CONFIG.debug {
                    print(UWBSensor.TAG, "NISession started (pending token): \(peerIdentifier)")
                }
            }
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
        let session = WCSession.default
        session.delegate = self
        session.activate()
        if session.activationState == .activated {
            wcActivated = true
            sendTokenToWatch()
        }
    }

    private func sendTokenToWatch() {
        guard wcActivated, WCSession.default.isWatchAppInstalled else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let peerKey = "apple_watch"
            let niSession = self.niSessions[peerKey] ?? {
                let s = NISession(); s.delegate = self
                self.niSessions[peerKey] = s; return s
            }()
            if let pending = self.pendingPeerTokens.removeValue(forKey: peerKey) {
                niSession.run(NINearbyPeerConfiguration(peerToken: pending))
                if self.CONFIG.debug {
                    print(UWBSensor.TAG, "NISession started with pending Apple Watch token")
                }
            }
            guard let myToken = niSession.discoveryToken else { return }
            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: myToken,
                                                             requiringSecureCoding: true)
                let message = ["uwbToken": data]
                if WCSession.default.isReachable {
                    WCSession.default.sendMessage(message, replyHandler: nil) { error in
                        if self.CONFIG.debug { print(UWBSensor.TAG, "WC send failed: \(error)") }
                    }
                } else {
                    try WCSession.default.updateApplicationContext(message)
                }
            } catch {
                if self.CONFIG.debug { print(UWBSensor.TAG, "WC token archive failed: \(error)") }
            }
        }
    }

    // MARK: - Shared NISession helpers

    private func handleReceivedPeerToken(_ peerToken: NIDiscoveryToken,
                                         peerIdentifier: String,
                                         deviceType: String) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let session = self.niSessions[peerIdentifier] {
                session.run(NINearbyPeerConfiguration(peerToken: peerToken))
                if self.CONFIG.debug {
                    print(UWBSensor.TAG, "NISession configured for \(deviceType): \(peerIdentifier)")
                }
            } else {
                self.pendingPeerTokens[peerIdentifier] = peerToken
                if peerIdentifier == "apple_watch" {
                    self.sendTokenToWatch()
                }
            }
            DispatchQueue.main.async {
                self.CONFIG.sensorObserver?.onPeerDiscovered(peerIdentifier: peerIdentifier,
                                                             deviceType: deviceType)
            }
        }
    }

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
        let deviceType: String = {
            if peerIdentifier == "apple_watch" { return "AppleWatch" }
            if peerIdentifier.hasPrefix("acc-") { return "Accessory" }
            return "iPhone"
        }()

        for object in nearbyObjects {
            var data = UWBData()
            data.timestamp      = Int64(Date().timeIntervalSince1970 * 1000)
            data.label          = CONFIG.label
            data.peerIdentifier = peerIdentifier
            data.peerDeviceType = deviceType
            if let d   = object.distance  { data.distance  = Double(d) }
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
        sessionQueue.async { self.niSessions.removeValue(forKey: peerIdentifier) }
        CONFIG.sensorObserver?.onPeerLost(peerIdentifier: peerIdentifier)
    }

    public func session(_ session: NISession, didInvalidateWith error: Error) {
        let peerIdentifier: String = sessionQueue.sync {
            niSessions.first(where: { $0.value === session })?.key ?? "unknown"
        }
        sessionQueue.async { self.niSessions.removeValue(forKey: peerIdentifier) }
        if CONFIG.debug { print(UWBSensor.TAG, "Session invalidated: \(peerIdentifier) \(error)") }
    }
}

// MARK: - MCSessionDelegate

extension UWBSensor: MCSessionDelegate {

    public func session(_ session: MCSession, peer peerID: MCPeerID,
                        didChange state: MCSessionState) {
        switch state {
        case .connected:
            setupNISession(for: peerID.displayName, mcPeer: peerID)
        case .notConnected:
            sessionQueue.async {
                if let s = self.niSessions.removeValue(forKey: peerID.displayName) { s.invalidate() }
            }
            CONFIG.sensorObserver?.onPeerLost(peerIdentifier: peerID.displayName)
        default: break
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self,
                                                                   from: data) else { return }
        handleReceivedPeerToken(token, peerIdentifier: peerID.displayName, deviceType: "iPhone")
    }

    public func session(_ session: MCSession, didReceive stream: InputStream,
                        withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                        fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
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

    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        guard let session = mcSession else { return }
        if localPeerID.displayName < peerID.displayName {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    public func browser(_ browser: MCNearbyServiceBrowser,
                        didNotStartBrowsingForPeers error: Error) {
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

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleWatchConnectivityMessage(message)
    }

    public func session(_ session: WCSession,
                        didReceiveApplicationContext applicationContext: [String: Any]) {
        handleWatchConnectivityMessage(applicationContext)
    }

    public func handleWatchConnectivityMessage(_ dict: [String: Any]) {
        guard let tokenData = dict["uwbToken"] as? Data,
              let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self,
                                                                   from: tokenData) else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let peerIdentifier = "apple_watch"
            let isNewToken = tokenData != self.lastReceivedWatchTokenData
            if isNewToken { self.lastReceivedWatchTokenData = tokenData }

            if let session = self.niSessions[peerIdentifier] {
                session.run(NINearbyPeerConfiguration(peerToken: token))
                if isNewToken {
                    // Watch が NISession を再起動した（新しいトークン）ため iPhone のトークンを送り返す。
                    // Watch の新 NISession は iPhone のトークンを受け取るまで run() できない。
                    self.sendTokenToWatch()
                }
            } else {
                self.pendingPeerTokens[peerIdentifier] = token
                self.sendTokenToWatch()
            }
            DispatchQueue.main.async {
                self.CONFIG.sensorObserver?.onPeerDiscovered(peerIdentifier: peerIdentifier,
                                                             deviceType: "AppleWatch")
            }
        }
    }
}

#endif
