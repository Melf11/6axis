// swift-tools-version: 6.0
import PackageDescription
import Foundation

// OpenCASCADE location. Override with OCCT_PREFIX=/path/to/occt if not installed via Homebrew.
let occtPrefix = ProcessInfo.processInfo.environment["OCCT_PREFIX"] ?? "/opt/homebrew/opt/opencascade"

let occtLibraries = [
    "TKernel", "TKMath", "TKG2d", "TKG3d", "TKGeomBase", "TKGeomAlgo", "TKBRep",
    "TKTopAlgo", "TKPrim", "TKBO", "TKBool", "TKFillet", "TKOffset", "TKShHealing",
    "TKMesh", "TKXSBase", "TKDE", "TKDESTEP", "TKDESTL",
]

let package = Package(
    name: "Vibe360",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Vibe360", targets: ["Vibe360"]),
        .library(name: "VibeCore", targets: ["VibeCore"]),
    ],
    targets: [
        // Thin C ABI over the OpenCASCADE C++ API.
        .target(
            name: "OCCTBridge",
            path: "Sources/OCCTBridge",
            cxxSettings: [
                .unsafeFlags(["-I\(occtPrefix)/include/opencascade", "-std=c++17", "-Wno-deprecated-declarations"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(occtPrefix)/lib", "-Xlinker", "-rpath", "-Xlinker", "\(occtPrefix)/lib"]),
            ] + occtLibraries.map { .linkedLibrary($0) }
        ),
        // Document model, parametric history, sketch solver, kernel wrapper. No UI.
        .target(
            name: "VibeCore",
            dependencies: ["OCCTBridge"],
            path: "Sources/VibeCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // macOS app: SwiftUI + Metal.
        .executableTarget(
            name: "Vibe360",
            dependencies: ["VibeCore"],
            path: "Sources/Vibe360",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VibeCoreTests",
            dependencies: ["VibeCore"],
            path: "Tests/VibeCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
