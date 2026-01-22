// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SAYses",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "SAYsesCore",
            targets: ["SAYsesCore"]
        )
    ],
    dependencies: [
        // Keychain access
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
    ],
    targets: [
        .target(
            name: "SAYsesCore",
            dependencies: ["KeychainAccess"],
            path: "SAYses"
        )
    ]
)
