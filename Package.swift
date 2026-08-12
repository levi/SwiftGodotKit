// swift-tools-version: 5.9
import PackageDescription
let macLibgodotTarget: Target = .binaryTarget(
    name: "mac_libgodot",
    url: "https://github.com/levi/godot/releases/download/v4.7.1-basis1/libgodot-macos.xcframework.zip",
    checksum: "9a896862e1c54769ebaa1771c36e395ceaedbc31f4a4584278d70226d793cded"
)

let iosLibgodotTarget: Target = .binaryTarget(
    name: "ios_libgodot",
    url: "https://github.com/levi/godot/releases/download/v4.7.1-basis1/libgodot-ios.xcframework.zip",
    checksum: "ff1adc5ff2f91c6f04ab5891e6f8a98c5729e3364c03d3773d117de87dd29b6c"
)

let tvosLibgodotTarget: Target = .binaryTarget(
    name: "tvos_libgodot",
    url: "https://github.com/levi/godot/releases/download/v4.7.1-basis3/libgodot-tvos.xcframework.zip",
    checksum: "51a659f2c6e868148f4f732e3e775317e12c345e0ff32d974a2971756b8e064c"
)

let package = Package(
    name: "SwiftGodotKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SwiftGodotKit",
            targets: ["SwiftGodotKit"]),
        .executable(name: "TrivialSample", targets: ["TrivialSample"]),
    ],
    dependencies: [
    		  // This is tag 0.75.0
        .package(url: "https://github.com/levi/SwiftGodot", revision: "74407acc58eba463518c3c89fb9f1111b966a15b"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "SwiftGodotKit",
            dependencies: [
                "SwiftGodot",
                "libgodot",
                .target(name: "apple_plugin_stubs", condition: .when(platforms: [.iOS, .tvOS])),
                .target(name: "mac_libgodot", condition: .when(platforms: [.macOS])),
                .target(name: "ios_libgodot", condition: .when(platforms: [.iOS])),
                .target(name: "tvos_libgodot", condition: .when(platforms: [.tvOS])),
            ]
        ),

        .executableTarget(
            name: "TrivialSample",
            dependencies: ["SwiftGodotKit"],
            
            // This line does not seem to do anything in Xcode, so you need to manually
            // copy main.pck and make it available from somwehere else
            resources: [
                .copy("main.pck"),
                .copy("main.tscn"),
                .copy("project.godot"),
                .copy(".godot"),
                .copy("godot"),
            ]
        ),

        .target(
            name: "apple_plugin_stubs",
            path: "Sources/apple_plugin_stubs",
            publicHeadersPath: "include"
        ),

        macLibgodotTarget,
        iosLibgodotTarget,
        tvosLibgodotTarget,
        .systemLibrary(
            name: "libgodot"
        ),
    ]
)
