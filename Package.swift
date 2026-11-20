// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VQMetrix",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VQMetrixApp", targets: ["VQMetrixApp"])
    ],
    dependencies: [
        .package(path: "../HaishinKit.swift"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.5")
    ],
    targets: [
        .systemLibrary(name: "CVMAF", pkgConfig: "libvmaf", providers: [.brew(["libvmaf"]) ]),
        .target(name: "VQMetrixCore", dependencies: [.product(name: "HaishinKit", package: "HaishinKit.swift"), "CVMAF", "ZIPFoundation"], resources: [.process("Resources")]),
        .executableTarget(name: "VQMetrixApp", dependencies: ["VQMetrixCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "VQMetrixTests", dependencies: ["VQMetrixCore"])
    ],
    swiftLanguageModes: [.v6]
)
