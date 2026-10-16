// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NookClip",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NookClip", targets: ["NookClip"])],
    dependencies: [
        // Sparkle 2 自动更新（动态 framework，build-app.sh 负责拷入 Contents/Frameworks/ 并补 rpath）
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(
            name: "NookClipCoreBridgeFFI",
            path: "Sources/NookClipCoreBridgeFFI"
        ),
        .executableTarget(
            name: "NookClip",
            dependencies: [
                "NookClipCoreBridgeFFI",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/NookClip",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L../../crates/nookclip-ffi/lib",
                    "-lnookclip_ffi"
                ])
            ]
        ),
        .testTarget(
            name: "NookClipTests",
            dependencies: [
                "NookClip",
                "NookClipCoreBridgeFFI"
            ],
            path: "Tests/NookClipTests",
            linkerSettings: [
                .unsafeFlags([
                    "-L../../crates/nookclip-ffi/lib",
                    "-lnookclip_ffi"
                ])
            ]
        )
    ]
)
