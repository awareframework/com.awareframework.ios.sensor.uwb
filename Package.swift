// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "com.awareframework.ios.sensor.uwb",
    platforms: [.iOS(.v16), .watchOS(.v8)],
    products: [
        .library(
            name: "com.awareframework.ios.sensor.uwb",
            targets: [
                "com.awareframework.ios.sensor.uwb.shared",
                "com.awareframework.ios.sensor.uwb.iOS",
                "com.awareframework.ios.sensor.uwb.watchOS",
            ]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/awareframework/com.awareframework.ios.core.git", from: "1.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.3.0"),
    ],
    targets: [
        // iOS・watchOS 共通データモデル
        .target(
            name: "com.awareframework.ios.sensor.uwb.shared",
            dependencies: [
                .product(name: "com.awareframework.ios.core",
                         package: "com.awareframework.ios.core"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/com.awareframework.ios.sensor.uwb/shared"
        ),
        // iPhone 用センサー
        .target(
            name: "com.awareframework.ios.sensor.uwb.iOS",
            dependencies: [
                .product(name: "com.awareframework.ios.core",
                         package: "com.awareframework.ios.core",
                         condition: .when(platforms: [.iOS])),
                "com.awareframework.ios.sensor.uwb.shared",
            ],
            path: "Sources/com.awareframework.ios.sensor.uwb/ios"
        ),
        // Apple Watch 用センサー
        .target(
            name: "com.awareframework.ios.sensor.uwb.watchOS",
            dependencies: [
                .product(name: "com.awareframework.ios.core",
                         package: "com.awareframework.ios.core",
                         condition: .when(platforms: [.watchOS])),
                "com.awareframework.ios.sensor.uwb.shared",
            ],
            path: "Sources/com.awareframework.ios.sensor.uwb/watchos"
        ),
        .testTarget(
            name: "com.awareframework.ios.sensor.uwbTests",
            dependencies: [
                "com.awareframework.ios.sensor.uwb.shared",
                "com.awareframework.ios.sensor.uwb.iOS",
                "com.awareframework.ios.sensor.uwb.watchOS",
                .product(name: "com.awareframework.ios.core",
                         package: "com.awareframework.ios.core",
                         condition: .when(platforms: [.iOS]))
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
