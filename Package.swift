// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "remtasks",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "remtasks", targets: ["remtasks"]),
        .library(name: "RemTasksCore", targets: ["RemTasksCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "RemTasksCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("EventKit"),
                .linkedFramework("Network"),
            ]
        ),
        .executableTarget(
            name: "remtasks",
            dependencies: [
                "RemTasksCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist so macOS TCC accepts the Reminders usage description
                // when the binary runs on its own (e.g. from launchd).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/remtasks/Info.plist",
                ]),
            ]
        ),
        .executableTarget(name: "remtasks-tests", dependencies: ["RemTasksCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
