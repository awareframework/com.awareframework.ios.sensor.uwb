//
//  AWUWBSensor.swift
//  com.awareframework.ios.sensor.uwb  (watchOS target)
//
//  Apple Watch (Series 6 / Ultra 以降) から iPhone への UWB 測距センサー。
//
//  動作の流れ
//  ──────────────────────────────────────────────────
//  1. start() → WCSession をアクティベート
//  2. activate 完了 → NISession を作成してトークンを iPhone へ送信
//  3. iPhone からトークン受信 → NISession を設定して測距開始
//  4. 測距データを watch_uwb テーブルへ保存
//
//  他の WCSession 管理クラス（AWWCSessionManager等）と併用する場合
//  ──────────────────────────────────────────────────
//  AWUWBSensor を standalone = false で初期化し、
//  外部の WCSession デリゲートから handleMessage(_:) を呼ぶ。

#if os(watchOS)

import Foundation
import NearbyInteraction
import WatchConnectivity
import com_awareframework_ios_core
import com_awareframework_ios_sensor_uwb_shared
import GRDB

// MARK: - Observer protocol

public protocol AWUWBObserver {
    func onDataChanged(data: AWUWBData)
    func onSessionStarted()
    func onSessionStopped()
}

// MARK: - AWUWBSensor

public class AWUWBSensor: AwareSensor {

    public static let TAG = "AWARE::Watch:UWB"

    public var CONFIG = AWUWBSensor.Config()

    public class Config: SensorConfig {
        public var sensorObserver: AWUWBObserver?
        /// true: このセンサーが WCSession を管理する（スタンドアロン動作）
        /// false: 外部から handleMessage(_:) を呼び出す（AWWCSessionManager 併用時）
        public var standaloneWCSession: Bool = true

        public override init() {
            super.init()
            dbPath      = "watch_uwb"
            dbTableName = AWUWBData.databaseTableName
        }

        public func apply(closure: (_ config: AWUWBSensor.Config) -> Void) -> Self {
            closure(self)
            return self
        }
    }

    // MARK: Private state

    private let sessionQueue = DispatchQueue(label: "com.awareframework.ios.sensor.uwb.watch.queue")
    private var niSession: NISession?
    private var lastReceivedIPhoneTokenData: Data?

    // MARK: Init

    public init(_ config: AWUWBSensor.Config) {
        super.init()
        CONFIG = config
        initializeDbEngine(config: config)
        initializeTable()
    }

    public override convenience init() {
        self.init(AWUWBSensor.Config())
    }

    // MARK: AwareSensor lifecycle

    public override func start() {
        guard NISession.isSupported else {
            if CONFIG.debug { print(AWUWBSensor.TAG, "UWB not supported on this device") }
            return
        }

        if CONFIG.standaloneWCSession {
            activateWCSession()
        } else {
            // WCSession は外部で管理されているため、NISession だけ初期化する
            initializeNISession()
        }

        if CONFIG.debug { print(AWUWBSensor.TAG, "AWUWBSensor started") }
    }

    public override func stop() {
        sessionQueue.sync {
            niSession?.invalidate()
            niSession = nil
            lastReceivedIPhoneTokenData = nil
        }
        CONFIG.sensorObserver?.onSessionStopped()
        if CONFIG.debug { print(AWUWBSensor.TAG, "AWUWBSensor stopped") }
    }

    public override func sync(force: Bool = false) {
        if let engine = dbEngine, let syncConfig = super.syncConfig {
            engine.startSync(syncConfig)
        }
    }

    public override func set(label: String) {
        CONFIG.label = label
    }

    // MARK: - 外部 WCSession デリゲートとの統合 API

    /// AWWCSessionManager などの外部 WCSession デリゲートから受信したメッセージを転送する。
    /// standaloneWCSession = false の場合に使用する。
    public func handleMessage(_ message: [String: Any]) {
        if let tokenData = message["uwbToken"] as? Data {
            handleiPhoneToken(tokenData)
        }
    }

    // MARK: - Internal

    private func activateWCSession() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func initializeNISession() {
        sessionQueue.async { [weak self] in
            guard let self, NISession.isSupported else { return }
            if self.niSession == nil {
                let session = NISession()
                session.delegate = self
                self.niSession = session
            }
            self.sendTokenToiPhone()
            self.CONFIG.sensorObserver?.onSessionStarted()
        }
    }

    /// 自分の NIDiscoveryToken を iPhone へ送信する。
    private func sendTokenToiPhone() {
        guard let token = niSession?.discoveryToken else { return }
        do {
            let tokenData = try NSKeyedArchiver.archivedData(withRootObject: token,
                                                              requiringSecureCoding: true)
            let message = ["uwbToken": tokenData]
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(message, replyHandler: nil) { [weak self] error in
                    if self?.CONFIG.debug == true {
                        print(AWUWBSensor.TAG, "Token send failed: \(error)")
                    }
                }
            } else {
                try WCSession.default.updateApplicationContext(message)
            }
            if CONFIG.debug { print(AWUWBSensor.TAG, "Token sent to iPhone") }
        } catch {
            if CONFIG.debug { print(AWUWBSensor.TAG, "Token archive failed: \(error)") }
        }
    }

    /// iPhone のトークンを受け取り、NISession を設定して測距を開始する。
    private func handleiPhoneToken(_ tokenData: Data) {
        guard let iPhoneToken = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NIDiscoveryToken.self, from: tokenData) else { return }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            if self.niSession == nil {
                let session = NISession()
                session.delegate = self
                self.niSession = session
            }

            // iPhone が NISession を再起動したとき（トークンが変わったとき）だけ Watch トークンを送り返す。
            // 毎回送ると iPhone 側の応答と無限ループになるため Data 比較で新規トークンのみ処理する。
            if tokenData != self.lastReceivedIPhoneTokenData {
                self.lastReceivedIPhoneTokenData = tokenData
                self.sendTokenToiPhone()
            }

            self.niSession?.run(NINearbyPeerConfiguration(peerToken: iPhoneToken))
            if self.CONFIG.debug { print(AWUWBSensor.TAG, "NISession configured with iPhone token") }
        }
    }

    private func initializeTable() {
        guard let sqliteEngine = dbEngine as? SQLiteEngine,
              let queue = sqliteEngine.getSQLiteInstance() else { return }
        try? AWUWBData.createTable(queue: queue)
    }
}

// MARK: - NISessionDelegate

extension AWUWBSensor: NISessionDelegate {

    public func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        for object in nearbyObjects {
            var data = AWUWBData()
            data.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            data.label     = CONFIG.label

            if let d   = object.distance  { data.distance  = Double(d) }
            if let dir = object.direction {
                data.directionX = Double(dir.x)
                data.directionY = Double(dir.y)
                data.directionZ = Double(dir.z)
            }
            if #available(watchOS 9.0, *) {
                if let h = object.horizontalAngle { data.horizontalAngle = Double(h) }
            }

            dbEngine?.save([data]) { [weak self] error in
                if let error = error, self?.CONFIG.debug == true {
                    print(AWUWBSensor.TAG, "DB save failed: \(error)")
                }
            }
            CONFIG.sensorObserver?.onDataChanged(data: data)
        }
    }

    public func session(_ session: NISession,
                        didRemove nearbyObjects: [NINearbyObject],
                        with reason: NINearbyObject.RemovalReason) {
        if CONFIG.debug { print(AWUWBSensor.TAG, "Peer removed: \(reason)") }
    }

    public func session(_ session: NISession, didInvalidateWith error: Error) {
        if CONFIG.debug { print(AWUWBSensor.TAG, "Session invalidated: \(error)") }
        sessionQueue.async { [weak self] in self?.niSession = nil }
    }
}

// MARK: - WCSessionDelegate（standaloneWCSession = true の場合のみ使用）

extension AWUWBSensor: WCSessionDelegate {

    public func session(_ session: WCSession,
                        activationDidCompleteWith activationState: WCSessionActivationState,
                        error: Error?) {
        if activationState == .activated {
            initializeNISession()
        }
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleMessage(message)
    }

    public func session(_ session: WCSession,
                        didReceiveApplicationContext applicationContext: [String: Any]) {
        handleMessage(applicationContext)
    }
}

#endif
