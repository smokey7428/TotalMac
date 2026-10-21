// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TotalMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TotalMac", targets: ["TotalMac"])
    ],
    targets: [
        // Thin C shim over the libarchive that ships with macOS. Declaring the
        // handful of functions we need locally keeps the build self contained
        // (the system SDK no longer ships archive.h).
        .target(
            name: "CArchive",
            path: "Sources/CArchive",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("archive")]
        ),
        .executableTarget(
            name: "TotalMac",
            dependencies: ["CArchive"],
            path: "Sources/TotalMac",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
