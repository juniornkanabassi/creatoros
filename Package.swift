// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProjectTemplates",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ProjectTemplates", targets: ["ProjectTemplates"]),
               .executable(name: "CoreChecks", targets: ["CoreChecks"]),
               .executable(name: "LibraryAdmin", targets: ["LibraryAdmin"])],
    targets: [.target(name: "TemplateCore"),
              .executableTarget(name: "ProjectTemplates", dependencies: ["TemplateCore"], linkerSettings: [.linkedFramework("AVKit")]),
              .executableTarget(name: "CoreChecks", dependencies: ["TemplateCore"]),
              .executableTarget(name: "LibraryAdmin", dependencies: ["TemplateCore"])],
    swiftLanguageModes: [.v5]
)
