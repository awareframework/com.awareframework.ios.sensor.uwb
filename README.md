# AWARE: UWB (Ultra-Wideband)

[![Swift Package Manager compatible](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen.svg)](https://github.com/apple/swift-package-manager)

This sensor module measures the distance and direction between an iPhone and nearby UWB-capable Apple devices using the NearbyInteraction framework. It supports two peer discovery transports:

- **iPhone ↔ iPhone** via MultipeerConnectivity
- **iPhone ↔ Apple Watch** via WatchConnectivity

Ranging data (distance, direction vector, horizontal angle) is recorded for each discovered peer.

> UWB ranging is available on iPhone 11 and later (U1 chip) and Apple Watch Series 6 and later.

## Requirements
iOS 15 or later (iPhone target)  
watchOS 7 or later (Apple Watch target)

## Installation

1. Open Package Manager Windows
    * Open `Xcode` -> Select `Menu Bar` -> `File` -> `App Package Dependencies...`

2. Find the package using the manager
    * Select `Search Package URL` and type `https://github.com/awareframework/com.awareframework.ios.sensor.uwb.git`

3. Import the package into your target.

4. Add the following keys to your `Info.plist`:
    * `NSNearbyInteractionUsageDescription`
    * `NSLocalNetworkUsageDescription`
    * `NSBonjourServices`: `_aware-uwb._tcp`, `_aware-uwb._udp`

## Public functions

### UWBSensor

+ `init(_ config: UWBSensor.Config)`: Initializes the sensor with the given configuration.
+ `start()`: Starts MultipeerConnectivity and/or WatchConnectivity peer discovery and NearbyInteraction sessions.
+ `stop()`: Stops all peer connections and invalidates all NI sessions.
+ `sync(force:)`: Syncs stored data to the configured host.
+ `set(label:)`: Sets a custom label applied to all subsequent data points.

### UWBSensor.Config

Class to hold the configuration of the sensor.

#### Fields

+ `sensorObserver: UWBObserver?`: Callback for live data updates.
+ `enableiPhoneRanging: Bool`: Enable peer discovery and ranging with other iPhones via MultipeerConnectivity. (default = `true`)
+ `enableAppleWatchRanging: Bool`: Enable ranging with a paired Apple Watch via WatchConnectivity. (default = `true`)
+ `enabled: Bool`: Sensor is enabled or not. (default = `false`)
+ `debug: Bool`: Enable/disable logging. (default = `false`)
+ `label: String`: Label for the data. (default = "")
+ `deviceId: String`: Id of the device associated with the events. (default = "")
+ `dbEncryptionKey`: Encryption key for the database. (default = `nil`)
+ `dbType: Engine`: Which db engine to use for saving data. (default = `Engine.DatabaseType.NONE`)
+ `dbPath: String`: Path of the database. (default = "aware_uwb")
+ `dbHost: String`: Host for syncing the database. (default = `nil`)

## Broadcasts

### Fired Broadcasts

+ `UWBSensor.ACTION_AWARE_UWB`: fired when a new UWB ranging measurement is recorded.

### Received Broadcasts

+ `UWBSensor.ACTION_AWARE_UWB_START`: received broadcast to start the sensor.
+ `UWBSensor.ACTION_AWARE_UWB_STOP`: received broadcast to stop the sensor.
+ `UWBSensor.ACTION_AWARE_UWB_SYNC`: received broadcast to send sync attempt to the host.
+ `UWBSensor.ACTION_AWARE_UWB_SET_LABEL`: received broadcast to set the data label. Label is expected in the `UWBSensor.EXTRA_LABEL` field of the notification userInfo.

## Data Representations

### UWBData

Contains a single ranging measurement between the local device and a peer.

| Field           | Type   | Description                                                              |
| --------------- | ------ | ------------------------------------------------------------------------ |
| peerIdentifier  | String | Peer device identifier (UUID string for iPhone, "apple_watch" for Watch) |
| peerDeviceType  | String | Peer type: "iPhone", "AppleWatch", "Accessory", or "Unknown"             |
| distance        | Double | Distance to the peer in meters (-1.0 if not yet measured)                |
| directionX      | Double | X component of the direction unit vector (0 if unavailable)              |
| directionY      | Double | Y component of the direction unit vector (0 if unavailable)              |
| directionZ      | Double | Z component of the direction unit vector (0 if unavailable)              |
| horizontalAngle | Double | Horizontal angle to the peer in radians (-999 if unavailable)            |
| label           | String | Customizable label. Useful for data calibration or traceability          |
| deviceId        | String | AWARE device UUID                                                        |
| timestamp       | Int64  | Unixtime milliseconds since 1970                                         |
| timezone        | Int    | Timezone of the device                                                   |
| os              | String | Operating system of the device (iOS)                                     |
| jsonVersion     | Int    | JSON schema version                                                      |

## Example usage

```swift
import com_awareframework_ios_sensor_uwb
```

```swift
let sensor = UWBSensor(UWBSensor.Config().apply { config in
    config.sensorObserver = Observer()
    config.enableiPhoneRanging = true
    config.enableAppleWatchRanging = true
    config.debug = true
})

sensor.start()

// Later...
sensor.stop()
```

```swift
class Observer: UWBObserver {
    func onDataChanged(data: UWBData) {
        print("Peer:", data.peerIdentifier, "Distance:", data.distance, "m")
    }

    func onPeerDiscovered(peerIdentifier: String, deviceType: String) {
        print("Discovered:", peerIdentifier, "(\(deviceType))")
    }

    func onPeerLost(peerIdentifier: String) {
        print("Lost peer:", peerIdentifier)
    }
}
```

## Author
Yuuki Nishiyama (The University of Tokyo), nishiyama@csis.u-tokyo.ac.jp

## Related Links
* [Apple | NearbyInteraction](https://developer.apple.com/documentation/nearbyinteraction)
* [Apple | MultipeerConnectivity](https://developer.apple.com/documentation/multipeerconnectivity)
* [Apple | WatchConnectivity](https://developer.apple.com/documentation/watchconnectivity)

## License
Copyright (c) 2018 AWARE Mobile Context Instrumentation Middleware/Framework (http://www.awareframework.com)

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0 Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.