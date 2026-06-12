//
//  UWBData.swift
//  com.awareframework.ios.sensor.uwb
//
//  Created by Yuuki Nishiyama on 2026/06/02.
//

import Foundation
import com_awareframework_ios_core
import GRDB

/// UWB ranging measurement for a single peer at a given point in time.
public struct UWBData: BaseDbModelSQLite {
    public var id: Int64?
    public var timestamp: Int64 = 0
    public var deviceId: String = AwareUtils.getCommonDeviceId()
    public var label: String = ""
    public var timezone: Int = AwareUtils.getTimeZone()
    public var os: String = "iOS"
    public var jsonVersion: Int = 1

    public static let databaseTableName = "ios_uwb"

    /// Identifier of the remote peer (UUID string for iPhones, "apple_watch" for Watch).
    public var peerIdentifier: String = ""

    /// Device type of the peer: "iPhone", "AppleWatch", "Accessory", or "Unknown".
    public var peerDeviceType: String = ""

    /// Distance in metres. -1.0 when not available.
    public var distance: Double = -1.0

    /// Direction unit-vector components. (0,0,0) when not available.
    public var directionX: Double = 0.0
    public var directionY: Double = 0.0
    public var directionZ: Double = 0.0

    /// Horizontal angle to the peer in radians (iOS 16+). -999 when not available.
    public var horizontalAngle: Double = -999.0

    public init() {}

    public init(_ dict: Dictionary<String, Any>) {
        timestamp       = dict["timestamp"] as? Int64  ?? 0
        label           = dict["label"]     as? String ?? ""
        deviceId        = dict["deviceId"]  as? String ?? AwareUtils.getCommonDeviceId()
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
