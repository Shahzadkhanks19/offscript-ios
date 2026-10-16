// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Offscript",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "LiveState", targets: ["LiveState"]),
    .executable(name: "LiveStatePlayground", targets: ["LiveStatePlayground"]),
    .executable(name: "RealtimeVoicePlayground", targets: ["RealtimeVoicePlayground"])
  ],
  targets: [
    .target(name: "LiveState"),
    .executableTarget(name: "LiveStatePlayground", dependencies: ["LiveState"]),
    .executableTarget(name: "RealtimeVoicePlayground", dependencies: ["LiveState"]),
    .testTarget(name: "LiveStateTests", dependencies: ["LiveState"])
  ]
)
