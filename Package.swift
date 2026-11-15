// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LionMessages",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LionMessages", targets: ["LionMessages"]),
        .library(name: "MessagesData", targets: ["MessagesData"]),
    ],
    targets: [
        // Shared models + the service protocol. The contract between data and UI.
        .target(name: "MessagesModel"),
        // chat.db reader, attributedBody decoder, contacts, file watcher, AppleScript sender.
        .target(
            name: "MessagesData",
            dependencies: ["MessagesModel"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The Lion-styled SwiftUI/AppKit app.
        .executableTarget(
            name: "LionMessages",
            dependencies: ["MessagesModel", "MessagesData"]
        ),
        .testTarget(name: "MessagesDataTests", dependencies: ["MessagesData"]),
    ],
    swiftLanguageVersions: [.v5]
)
