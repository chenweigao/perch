// swift-tools-version: 6.0
import PackageDescription

// SwiftMath requires CoreGraphics/CoreText; WorkbenchChecks skips the math
// rendering smoke check on Linux instead of linking it.
#if os(Linux)
let checksMathDependency: [Target.Dependency] = []
#else
let checksMathDependency: [Target.Dependency] = [.product(name: "SwiftMath", package: "SwiftMath")]
#endif

let package = Package(
    name: "AgentWorkbench",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "AgentWorkbench", targets: ["AgentWorkbench"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        .package(url: "https://github.com/Lakr233/libghostty-spm.git",
                 revision: "121c8e286d24e21ea1a379da3eaa3556d3a1b8f5"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.1.1")
    ],
    targets: [
        .target(name: "WorkbenchCore", dependencies: [
            .product(name: "Markdown", package: "swift-markdown"),
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
        ]),
        .executableTarget(name: "AgentWorkbench", dependencies: [
            "WorkbenchCore", .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            .product(name: "SwiftMath", package: "SwiftMath")
        ], resources: [.copy("Resources/Perch-mark.png")]),
        .executableTarget(name: "WorkbenchChecks", dependencies: ["WorkbenchCore"] + checksMathDependency, path: "Tests/WorkbenchCoreTests"),
        .executableTarget(name: "ConnectionChecks", dependencies: ["WorkbenchCore"], path: "Tests/ConnectionChecks")
    ],
    swiftLanguageModes: [.v5]
)
