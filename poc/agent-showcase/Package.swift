// swift-tools-version:5.10
import PackageDescription

// Proof of concept for "Pubbles for agents" scripted mode. Separate package so it never
// touches the app build. See README.md.
let package = Package(
    name: "showcase",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "showcase", path: "Sources/showcase")
    ]
)
