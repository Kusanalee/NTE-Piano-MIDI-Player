// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NTEPianoMidiPlayer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "NTEPianoMidiPlayer", targets: ["NTEPianoMidiPlayer"]),
        .library(name: "NTEPianoMidiPlayerCore", targets: ["NTEPianoMidiPlayerCore"])
    ],
    targets: [
        .target(
            name: "NTEPianoMidiPlayerCore",
            path: "Sources/NTEPianoMidiPlayerCore",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "NTEPianoMidiPlayer",
            dependencies: ["NTEPianoMidiPlayerCore"],
            path: "Sources/NTEPianoMidiPlayer",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "NTEPianoMidiPlayerTests",
            dependencies: ["NTEPianoMidiPlayerCore"],
            path: "Tests/NTEPianoMidiPlayerTests"
        )
    ]
)
