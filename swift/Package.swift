// swift-tools-version: 6.0

import PackageDescription
import Foundation

// Absolute path of the lui checkout's Apple package. Override with
// JOURNAL_LUI_PACKAGE_PATH when the checkout lives elsewhere.
let luiPackagePath =
    ProcessInfo.processInfo.environment["JOURNAL_LUI_PACKAGE_PATH"]
    ?? ("../../lui/platform/apple" as NSString).standardizingPath

// Colon-separated native objects/archives to link into the app binary:
// the OCaml complete object plus the compiled journal_lui_bridge.o. The build
// script (tool/build_journal_apple.sh) supplies them.
let nativeLinkInputs = ProcessInfo.processInfo.environment["JOURNAL_NATIVE_LINK_INPUTS"]?
    .split(separator: ":")
    .map(String.init) ?? []
let nativeLinkerSettings: [LinkerSetting] = nativeLinkInputs.isEmpty ? [] : [
    .unsafeFlags(nativeLinkInputs, .when(platforms: [.iOS, .macOS])),
    .linkedLibrary("sqlite3", .when(platforms: [.iOS, .macOS])),
]

let package = Package(
    name: "JournalApp",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    dependencies: [
        .package(path: luiPackagePath),
        .package(
            url: "https://github.com/aws-amplify/amplify-swift.git",
            exact: "2.61.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "JournalApp",
            dependencies: [
                .product(name: "LUIAppleBackendStatic", package: "apple"),
                .product(name: "Amplify", package: "amplify-swift"),
                .product(name: "AWSCognitoAuthPlugin", package: "amplify-swift"),
            ],
            path: ".",
            exclude: ["Package.swift"],
            linkerSettings: nativeLinkerSettings
        ),
    ]
)
