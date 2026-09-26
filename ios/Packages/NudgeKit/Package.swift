// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NudgeKit",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "NudgeKit", targets: [
            "DesignSystem", "Models", "Networking", "Auth", "Friends", "Availability", "Nudges",
            "Calls", "Transcription", "PhotoIndex", "PhotoShare", "Messages", "Memory", "Settings",
            "BackgroundWork", "Nearby",
        ]),
        .library(name: "NudgeExtensionKit", targets: ["DesignSystem", "Models"]),
    ],
    dependencies: [
        .package(url: "https://github.com/aws/amazon-chime-sdk-ios-spm", exact: "0.27.4"),
        .package(url: "https://github.com/marmelroy/PhoneNumberKit", from: "4.0.0"),
    ],
    targets: [
        .target(name: "Models"),
        .target(name: "DesignSystem", dependencies: ["Models"]),
        .target(name: "Networking", dependencies: ["Models"]),
        .target(name: "Auth", dependencies: ["Networking", "Models"]),
        .target(name: "Friends", dependencies: [
            "Networking", "Models", .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
        ]),
        .target(name: "Availability", dependencies: ["Networking", "Models"]),
        .target(name: "Nudges", dependencies: ["Networking", "Models"]),
        .target(name: "PhotoShare", dependencies: ["Models"]),
        .target(name: "Transcription", dependencies: ["Networking", "Models"]),
        .target(name: "Calls", dependencies: [
            "Networking", "Models", "PhotoShare", "Transcription",
            .product(name: "AmazonChimeSDK", package: "amazon-chime-sdk-ios-spm"),
        ]),
        .target(name: "PhotoIndex", dependencies: ["Networking", "Models"]),
        .target(name: "Messages", dependencies: ["Networking", "Models"]),
        .target(name: "Memory", dependencies: ["Networking", "Models"]),
        .target(name: "Settings", dependencies: ["Networking", "Models"]),
        .target(name: "BackgroundWork", dependencies: ["Availability", "PhotoIndex", "Networking"]),
        .target(name: "Nearby", dependencies: ["Networking", "Models"]),
        .testTarget(name: "NudgeKitTests", dependencies: [
            "Models", "Networking", "Friends", "Availability", "Nudges", "PhotoShare", "Transcription",
            "Calls", "PhotoIndex", "DesignSystem", "Nearby",
        ]),
    ]
)
