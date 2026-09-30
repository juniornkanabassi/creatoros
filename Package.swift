// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProjectTemplates",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ProjectTemplates", targets: ["ProjectTemplates"]),
               .executable(name: "CoreChecks", targets: ["CoreChecks"]),
               .executable(name: "creatoros", targets: ["creatoros"])],
    targets: [.target(name: "TemplateCore"),
              .executableTarget(name: "ProjectTemplates", dependencies: ["TemplateCore"]),
              .executableTarget(name: "CoreChecks", dependencies: ["TemplateCore"]),
              .executableTarget(name: "creatoros", dependencies: ["TemplateCore"]),
              .executableTarget(name: "ContentTool", dependencies: ["TemplateCore"])],
    swiftLanguageModes: [.v5]
)
