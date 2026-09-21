// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentWorkbench",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentWorkbench", targets: ["AgentWorkbench"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        .package(url: "https://github.com/Lakr233/libghostty-spm.git",
                 revision: "121c8e286d24e21ea1a379da3eaa3556d3a1b8f5")
    ],
    targets: [
        .target(name: "WorkbenchCore", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .executableTarget(name: "AgentWorkbench", dependencies: [
            "WorkbenchCore", .product(name: "GhosttyTerminal", package: "libghostty-spm")
        ]),
        .executableTarget(name: "WorkbenchChecks", dependencies: ["WorkbenchCore"], path: "Tests/WorkbenchCoreTests"),
        .executableTarget(name: "ConnectionChecks", dependencies: ["WorkbenchCore"], path: "Tests/ConnectionChecks")
    ],
    swiftLanguageModes: [.v5]
)
