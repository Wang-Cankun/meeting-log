// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetingLog",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "MeetingLog", targets: ["MeetingLog"])],
    targets: [
        .executableTarget(name: "MeetingLog"),
    ]
)
