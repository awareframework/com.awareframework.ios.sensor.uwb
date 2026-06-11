//
//  UWBSensorTests.swift
//  com.awareframework.ios.sensor.uwb
//

import XCTest
import com_awareframework_ios_sensor_uwb_shared
#if os(iOS)
import com_awareframework_ios_sensor_uwb_iOS
#endif
import com_awareframework_ios_core

class UWBSensorTests: XCTestCase {

    // MARK: - UWBData (iPhone side)

    func testUWBDataDefaults() {
        let data = UWBData()
        XCTAssertEqual(data.distance, -1.0)
        XCTAssertEqual(data.horizontalAngle, -999.0)
        XCTAssertEqual(data.directionX, 0.0)
        XCTAssertEqual(data.peerDeviceType, "")
        XCTAssertEqual(data.os, "iOS")
        XCTAssertEqual(UWBData.databaseTableName, "uwb")
    }

    func testUWBDataDictionary() {
        var data = UWBData()
        data.timestamp       = 1000
        data.peerIdentifier  = "peer-uuid"
        data.peerDeviceType  = "iPhone"
        data.distance        = 1.5
        data.directionX      = 0.1
        data.directionY      = 0.2
        data.directionZ      = 0.9
        data.horizontalAngle = 0.3

        let dict = data.toDictionary()
        XCTAssertEqual(dict["timestamp"]       as? Int64,  1000)
        XCTAssertEqual(dict["peerIdentifier"]  as? String, "peer-uuid")
        XCTAssertEqual(dict["peerDeviceType"]  as? String, "iPhone")
        XCTAssertEqual(dict["distance"]        as? Double, 1.5)
        XCTAssertEqual(dict["horizontalAngle"] as? Double, 0.3)
    }

    func testUWBDataFromDictionary() {
        let dict: [String: Any] = [
            "timestamp":       Int64(2000),
            "peerIdentifier":  "apple_watch",
            "peerDeviceType":  "AppleWatch",
            "distance":        Double(0.8),
            "directionX":      Double(0.0),
            "directionY":      Double(1.0),
            "directionZ":      Double(0.0),
            "horizontalAngle": Double(-0.2),
        ]
        let data = UWBData(dict)
        XCTAssertEqual(data.timestamp,       2000)
        XCTAssertEqual(data.peerIdentifier,  "apple_watch")
        XCTAssertEqual(data.peerDeviceType,  "AppleWatch")
        XCTAssertEqual(data.distance,        0.8)
        XCTAssertEqual(data.horizontalAngle, -0.2)
    }

    // MARK: - AWUWBData (Watch side)

    func testAWUWBDataDefaults() {
        let data = AWUWBData()
        XCTAssertEqual(data.distance, -1.0)
        XCTAssertEqual(data.horizontalAngle, -999.0)
        XCTAssertEqual(data.os, "watchOS")
        XCTAssertEqual(AWUWBData.databaseTableName, "watch_uwb")
    }

    func testAWUWBDataDictionary() {
        var data = AWUWBData()
        data.timestamp       = 3000
        data.distance        = 0.5
        data.directionX      = 0.0
        data.directionY      = 0.0
        data.directionZ      = 1.0
        data.horizontalAngle = 0.1

        let dict = data.toDictionary()
        XCTAssertEqual(dict["timestamp"] as? Int64,  3000)
        XCTAssertEqual(dict["distance"]  as? Double, 0.5)
        XCTAssertEqual(dict["directionZ"] as? Double, 1.0)
        XCTAssertEqual(dict["horizontalAngle"] as? Double, 0.1)
    }

    func testAWUWBDataFromDictionary() {
        let dict: [String: Any] = [
            "timestamp": Int64(4000),
            "distance":  Double(1.2),
            "directionX": Double(0.1),
            "directionY": Double(0.2),
            "directionZ": Double(0.9),
            "horizontalAngle": Double(0.5),
        ]
        let data = AWUWBData(dict)
        XCTAssertEqual(data.timestamp, 4000)
        XCTAssertEqual(data.distance,  1.2)
        XCTAssertEqual(data.horizontalAngle, 0.5)
    }

    // MARK: - UWBSensor config (iOS only)

    #if os(iOS)
    func testDefaultConfig() {
        let sensor = UWBSensor()
        XCTAssertTrue(sensor.CONFIG.enableiPhoneRanging)
        XCTAssertTrue(sensor.CONFIG.enableAppleWatchRanging)
        XCTAssertEqual(sensor.CONFIG.dbPath, "aware_uwb")
        XCTAssertEqual(sensor.CONFIG.dbTableName, "uwb")
    }

    func testConfigApply() {
        let sensor = UWBSensor(UWBSensor.Config().apply { config in
            config.enableiPhoneRanging     = false
            config.enableAppleWatchRanging = false
            config.debug                   = true
        })
        XCTAssertFalse(sensor.CONFIG.enableiPhoneRanging)
        XCTAssertFalse(sensor.CONFIG.enableAppleWatchRanging)
        XCTAssertTrue(sensor.CONFIG.debug)
    }

    func testSetLabel() {
        let sensor  = UWBSensor(UWBSensor.Config().apply { $0.debug = true })
        let expect  = expectation(description: "set label")
        let newLabel = "test"
        let obs = NotificationCenter.default.addObserver(
            forName: .actionAwareUWBSetLabel, object: nil, queue: .main) { notification in
            if let label = notification.userInfo?[UWBSensor.EXTRA_LABEL] as? String,
               label == newLabel { expect.fulfill() }
        }
        sensor.set(label: newLabel)
        wait(for: [expect], timeout: 5)
        NotificationCenter.default.removeObserver(obs)
    }

    func testSyncNotification() {
        let sensor = UWBSensor(UWBSensor.Config().apply { $0.debug = true })
        let expect = expectation(description: "sync")
        let obs = NotificationCenter.default.addObserver(
            forName: .actionAwareUWBSync, object: nil, queue: .main) { _ in expect.fulfill() }
        sensor.sync()
        wait(for: [expect], timeout: 5)
        NotificationCenter.default.removeObserver(obs)
    }

    func testStartStop() {
        #if targetEnvironment(simulator)
        print("UWB start/stop tests require a real device with U1/UWB chip.")
        #else
        let sensor = UWBSensor(UWBSensor.Config().apply { $0.debug = true })

        let startExpect = expectation(description: "start")
        let startObs = NotificationCenter.default.addObserver(
            forName: .actionAwareUWBStart, object: nil, queue: .main) { _ in startExpect.fulfill() }
        sensor.start()
        wait(for: [startExpect], timeout: 5)
        NotificationCenter.default.removeObserver(startObs)

        let stopExpect = expectation(description: "stop")
        let stopObs = NotificationCenter.default.addObserver(
            forName: .actionAwareUWBStop, object: nil, queue: .main) { _ in stopExpect.fulfill() }
        sensor.stop()
        wait(for: [stopExpect], timeout: 5)
        NotificationCenter.default.removeObserver(stopObs)
        #endif
    }
    #endif
}
