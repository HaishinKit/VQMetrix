// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VQMetrix",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VQMetrix", targets: ["VQMetrix"])
    ],
    dependencies: [
        .package(path: "../HaishinKit.swift"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .systemLibrary(name: "CVMAF", pkgConfig: "libvmaf", providers: [.brew(["libvmaf"]) ]),
        .executableTarget(name: "VQMetrix", dependencies: [.product(name: "HaishinKit", package: "HaishinKit.swift"), "CVMAF", "ZIPFoundation", .product(name: "Sparkle", package: "Sparkle")], resources: [.process("Resources")]),
        .testTarget(name: "VQMetrixTests", dependencies: ["VQMetrix"])
    ],
    swiftLanguageModes: [.v6]
)
