// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OppoLiteConnect",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "OppoLiteConnect",
            targets: ["OppoLiteConnect"]
        )
    ],
    targets: [
        .executableTarget(
            name: "OppoLiteConnect",
            path: "Sources/OppoLiteConnect",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
