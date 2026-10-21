// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "ModelPicker", platforms: [.macOS(.v14)],
  targets: [.executableTarget(name: "ModelPicker", path: "Sources/ModelPicker")])
