// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DesktopPet",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DesktopPet", targets: ["DesktopPet"])
    ],
    targets: [
        .target(
            name: "DesktopPetCore",
            path: "Sources/DesktopPetCore"
        ),
        .executableTarget(
            name: "DesktopPet",
            dependencies: ["DesktopPetCore"],
            path: "Sources/DesktopPet",
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "DesktopPetTests",
            dependencies: ["DesktopPetCore"],
            path: "Tests/DesktopPetTests"
        )
    ]
)
