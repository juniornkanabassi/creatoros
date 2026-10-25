// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProjectTemplates",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ProjectTemplates", targets: ["ProjectTemplates"]),
               .executable(name: "CoreChecks", targets: ["CoreChecks"]),
               .executable(name: "creatoros", targets: ["creatoros"])],
    dependencies: [
        // Self-updating, the same Sparkle release as Talk & Read and Video Prompter.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [.target(name: "TemplateCore"),
              .executableTarget(name: "ProjectTemplates", dependencies: ["TemplateCore", .product(name: "Sparkle", package: "Sparkle")],
                                // build.sh embeds Sparkle.framework in Contents/Frameworks; a bare SwiftPM binary finds it beside itself.
                                linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                                                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]),
              .executableTarget(name: "CoreChecks", dependencies: ["TemplateCore"]),
              .executableTarget(name: "creatoros", dependencies: ["TemplateCore"]),
              .executableTarget(name: "ContentTool", dependencies: ["TemplateCore"])],
    swiftLanguageModes: [.v5]
)
