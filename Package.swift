// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Playndgain",
    defaultLocalization: "en",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "Playndgain", targets: ["Playndgain"]),
    ],
    targets: [
        .target(
            name: "Playndgain",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PlayndgainTests",
            dependencies: ["Playndgain"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
