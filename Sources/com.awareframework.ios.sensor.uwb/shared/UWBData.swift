//
//  UWBData.swift
//  com.awareframework.ios.sensor.uwb
//
//  iPhone 側が保存する UWB 測距データ（全ピア分）。
//  テーブル名: uwb

import Foundation
import com_awareframework_ios_core
import GRDB

public struct UWBData: BaseDbModelSQLite {
    public var id: Int64?
    public var timestamp: Int64 = 0
    public var deviceId: String = AwareUtils.getCommonDeviceId()
    public var label: String = ""
    public var timezone: Int = AwareUtils.getTimeZone()
    public var os: String = "iOS"
    public var jsonVersion: Int = 1

    public static let databaseTableName = "ios_uwb"

    /// ピアのデバイス識別子（iPhone=UUID文字列、Apple Watch="apple_watch"）
    public var peerIdentifier: String = ""
    /// ピアの種別: "iPhone" / "AppleWatch" / "Accessory" / "Unknown"
    public var peerDeviceType: String = ""
    /// 距離（メートル）。未計測時は -1.0
    public var distance: Double = -1.0
    /// 方向ベクトル。未計測時は (0,0,0)
    public var directionX: Double = 0.0
    public var directionY: Double = 0.0
    public var directionZ: Double = 0.0
    /// 水平角（ラジアン）。未計測時は -999
    public var horizontalAngle: Double = -999.0

    public init() {}

    public init(_ dict: Dictionary<String, Any>) {
        timestamp       = dict["timestamp"]       as? Int64  ?? 0
        label           = dict["label"]           as? String ?? ""
        deviceId        = dict["deviceId"]        as? String ?? AwareUtils.getCommonDeviceId()
        peerIdentifier  = dict["peerIdentifier"]  as? String ?? ""
        peerDeviceType  = dict["peerDeviceType"]  as? String ?? ""
        distance        = dict["distance"]        as? Double ?? -1.0
        directionX      = dict["directionX"]      as? Double ?? 0.0
        directionY      = dict["directionY"]      as? Double ?? 0.0
        directionZ      = dict["directionZ"]      as? Double ?? 0.0
        horizontalAngle = dict["horizontalAngle"] as? Double ?? -999.0
    }

    public static func createTable(queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.create(table: databaseTableName, ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("deviceId",        .text).notNull()
                t.column("timestamp",       .integer).notNull()
                t.column("label",           .text).notNull()
                t.column("timezone",        .integer).notNull()
                t.column("os",              .text).notNull()
                t.column("jsonVersion",     .integer).notNull()
                t.column("peerIdentifier",  .text).notNull()
                t.column("peerDeviceType",  .text).notNull()
                t.column("distance",        .double).notNull()
                t.column("directionX",      .double).notNull()
                t.column("directionY",      .double).notNull()
                t.column("directionZ",      .double).notNull()
                t.column("horizontalAngle", .double).notNull()
            }
        }
    }

    public func toDictionary() -> Dictionary<String, Any> {
        return [
            "id":               id ?? -1,
            "timestamp":        timestamp,
            "deviceId":         deviceId,
            "label":            label,
            "peerIdentifier":   peerIdentifier,
            "peerDeviceType":   peerDeviceType,
            "distance":         distance,
            "directionX":       directionX,
            "directionY":       directionY,
            "directionZ":       directionZ,
            "horizontalAngle":  horizontalAngle,
        ]
    }
}
