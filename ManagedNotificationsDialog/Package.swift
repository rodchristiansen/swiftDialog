// swift-tools-version:6.0
import PackageDescription

// Managed Notifications Dialog: the Prefs / Run / Logs window for swiftDialog.
// It stands apart from dialog.xcodeproj and runs the installed `dialog` command
// as the signed-in user, so it needs no privileged helper.
let package = Package(
    name: "ManagedNotificationsDialog",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ManagedNotificationsDialogApp", targets: ["ManagedNotificationsDialogApp"])
    ],
    targets: [
        .executableTarget(
            name: "ManagedNotificationsDialogApp",
            path: "Sources/ManagedNotificationsDialogApp"
        ),
        .testTarget(
            name: "ManagedNotificationsDialogTests",
            dependencies: ["ManagedNotificationsDialogApp"],
            path: "Tests/ManagedNotificationsDialogTests"
        )
    ]
)
