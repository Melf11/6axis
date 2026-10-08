// swift-tools-version: 6.0
import PackageDescription
import Foundation

// OpenCASCADE location. Override with OCCT_PREFIX=/path/to/occt if not installed via Homebrew.
let occtPrefix = ProcessInfo.processInfo.environment["OCCT_PREFIX"] ?? "/opt/homebrew/opt/opencascade"

let occtLibraries = [
    "TKernel", "TKMath", "TKG2d", "TKG3d", "TKGeomBase", "TKGeomAlgo", "TKBRep",
    "TKTopAlgo", "TKPrim", "TKBO", "TKBool", "TKFillet", "TKOffset", "TKShHealing",
    "TKMesh", "TKHLR", "TKXSBase", "TKDE", "TKDESTEP", "TKDESTL",
]

let package = Package(
    name: "6axis",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SixAxis", targets: ["SixAxis"]),
        .library(name: "SixAxisCore", targets: ["SixAxisCore"]),
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
            name: "SixAxisCore",
            dependencies: ["OCCTBridge"],
            path: "Sources/SixAxisCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // macOS app: SwiftUI + Metal.
        .executableTarget(
            name: "SixAxis",
            dependencies: ["SixAxisCore"],
            path: "Sources/SixAxis",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SixAxisCoreTests",
            dependencies: ["SixAxisCore"],
            path: "Tests/SixAxisCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
