// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "Offscript",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [.library(name:"LiveState",targets:["LiveState"]), .executable(name:"LiveStatePlayground",targets:["LiveStatePlayground"])],
  targets: [.target(name:"LiveState"), .executableTarget(name:"LiveStatePlayground",dependencies:["LiveState"]), .testTarget(name:"LiveStateTests",dependencies:["LiveState"])]
)