// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Folio", targets: ["Folio"]),
    ],
    targets: [
        // Platform-light logic: storage, document identity, providers, context, export.
        .target(
            name: "FolioCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The AppKit application.
        .executableTarget(
            name: "Folio",
            dependencies: ["FolioCore"]
        ),
        .testTarget(
            name: "FolioCoreTests",
            dependencies: ["FolioCore"]
        ),
    ]
)
