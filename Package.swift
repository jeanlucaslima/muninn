// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Muninn",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "muninnd", targets: ["muninnd"]),
        .executable(name: "muninn", targets: ["muninn-cli"]),
        .executable(name: "muninn-menubar", targets: ["muninn-menubar"]),
    ],
    targets: [
        // System module for SQLite
        .systemLibrary(
            name: "CSQLite",
            path: "packages/CSQLite"
        ),

        // Libraries
        .target(
            name: "MuninnCore",
            path: "packages/MuninnCore/Sources"
        ),
        .target(
            name: "MuninnStore",
            dependencies: ["MuninnCore", "CSQLite"],
            path: "packages/MuninnStore/Sources"
        ),
        .target(
            name: "MuninnClipboard",
            dependencies: ["MuninnCore"],
            path: "packages/MuninnClipboard/Sources"
        ),
        .target(
            name: "MuninnIPC",
            dependencies: ["MuninnCore"],
            path: "packages/MuninnIPC/Sources"
        ),

        // Executables
        .executableTarget(
            name: "muninnd",
            dependencies: ["MuninnCore", "MuninnStore", "MuninnClipboard", "MuninnIPC"],
            path: "apps/muninnd/Sources"
        ),
        .executableTarget(
            name: "muninn-cli",
            dependencies: ["MuninnCore", "MuninnIPC"],
            path: "apps/muninn-cli/Sources"
        ),

        .executableTarget(
            name: "muninn-menubar",
            dependencies: ["MuninnCore", "MuninnIPC"],
            path: "apps/muninn-menubar/Sources"
        ),

        // Tests
        .testTarget(
            name: "MuninnStoreTests",
            dependencies: ["MuninnStore"],
            path: "packages/MuninnStore/Tests"
        ),
        .testTarget(
            name: "MuninnIPCTests",
            dependencies: ["MuninnIPC"],
            path: "packages/MuninnIPC/Tests"
        ),
        .testTarget(
            name: "MuninnCLITests",
            dependencies: ["MuninnCore", "MuninnIPC"],
            path: "apps/muninn-cli/Tests"
        ),
    ]
)
