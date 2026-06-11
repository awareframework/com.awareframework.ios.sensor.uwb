//
//  AWUWBData.swift
//  com.awareframework.ios.sensor.uwb
//
//  Apple Watch 側が保存する UWB 測距データ。
//  テーブル名: watch_uwb

import Foundation
import com_awareframework_ios_core
import GRDB

public struct AWUWBData: BaseDbModelSQLite {
    public var id: Int64?
    public var timestamp: Int64 = 0
    public var deviceId: String = AwareUtils.getCommonDeviceId()
    public var label: String = ""
    public var timezone: Int = AwareUtils.getTimeZone()
    public var os: String = "watchOS"
    public var jsonVersion: Int = 1

    public static let databaseTableName = "watch_uwb"

    /// 距離（メートル）。未計測時は -1.0
    public var distance: Double = -1.0
    /// 方向ベクトル。未計測時は (0,0,0)
    public var directionX: Double = 0.0
    public var directionY: Double = 0.0
    public var directionZ: Double = 0.0
    /// 水平角（ラジアン、watchOS 9+）。未計測時は -999
    public var horizontalAngle: Double = -999.0

    public init() {}

    public init(_ dict: Dictionary<String, Any>) {
        timestamp       = dict["timestamp"]       as? Int64  ?? 0
        label           = dict["label"]           as? String ?? ""
        deviceId        = dict["deviceId"]        as? String ?? AwareUtils.getCommonDeviceId()
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
            "distance":         distance,
            "directionX":       directionX,
            "directionY":       directionY,
            "directionZ":       directionZ,
            "horizontalAngle":  horizontalAngle,
        ]
    }
}
