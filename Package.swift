// swift-tools-version: 6.2
import PackageDescription

// The app compiles these same files. Local regressions need no SDK download.
let package = Package(
    name: "S3BrowserAudit",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [.library(name: "AuditCore", targets: ["AuditCore"])],
    targets: [
        .target(name: "AuditCore", path: "Sources/Core"),
        .testTarget(name: "AuditCoreTests", dependencies: ["AuditCore"], path: "Tests/AuditCoreTests")
    ]
)
