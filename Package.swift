// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "disk-slim",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "diskslim", targets: ["diskslim"]),
    ],
    targets: [
        // 扫描规则与数据模型，不含界面；菜单栏应用和命令行工具共用
        .target(name: "DiskSlimCore"),
        .executableTarget(name: "diskslim", dependencies: ["DiskSlimCore"]),
        // 和 Node 的协作测试共用小写 tests/ 目录；写明路径，区分大小写的文件系统上也能找到
        .testTarget(name: "DiskSlimCoreTests", dependencies: ["DiskSlimCore"], path: "tests/DiskSlimCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
