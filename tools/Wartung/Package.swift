// swift-tools-version: 6.0
// "6axis Wartung": menu bar app for the owner – bug reports, pull requests and releases.
// A thin interface over scripts/bugfix.py and scripts/release.py; not part of 6axis itself.
import PackageDescription

let package = Package(
    name: "Wartung",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Wartung", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
