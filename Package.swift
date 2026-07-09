// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Spacer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Spacer", path: "Sources/Spacer",
            exclude: ["Info.plist"],
            // 裸執行檔沒有 bundle，把 Info.plist 塞進 __info_plist section
            // 才能觸發行事曆的 TCC 授權
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", "Sources/Spacer/Info.plist",
            ])]
        )
    ]
)
