// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "disk-slim",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "diskslim", targets: ["diskslim"]),
    ],
    targets: [
        // 扫描规则与数据模型，不含界面；桌面应用和命令行工具共用
        .target(name: "DiskSlimCore"),
        // macOS 不区分大小写：目标名、源码目录名、可执行文件名都不能只差大小写（docs/LESSONS.md L-03）
        .executableTarget(name: "diskslim", dependencies: ["DiskSlimCore"], path: "Sources/DiskSlimCLI"),
        // 桌面应用（不在菜单栏和程序坞显示，入口是驿窗挂件）；用 scripts/bundle.sh 打包成 dist/DiskSlim.app
        .executableTarget(name: "DiskSlimApp", dependencies: ["DiskSlimCore"], path: "Sources/DiskSlimApp"),
        // 和 Node 的协作测试共用小写 tests/ 目录；写明路径，区分大小写的文件系统上也能找到
        .testTarget(name: "DiskSlimCoreTests", dependencies: ["DiskSlimCore"], path: "tests/DiskSlimCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
